# frozen_string_literal: true

require "base64"

module Api
  class MeController < ApplicationController
    before_action :authenticate_system_user!

    TD_SUPERGROUP_CHAT_ABS_PREFIX = 1_000_000_000_000
    TG_PRIVATEPOST_URL_PATTERN = %r{\Atg://privatepost\?(?:[^#]*&)?channel=(\d+)&post=(\d+)\b}.freeze
    T_ME_C_URL_PATTERN = %r{\Ahttps?://t\.me/c/(\d+)/(\d+)(?:\?.*)?\z}.freeze
    T_ME_PUBLIC_URL_PATTERN = %r{\Ahttps?://t\.me/[^/]+/(\d+)(?:\?.*)?\z}.freeze

    def chats
      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      rows = TelegramChat.where(td_chat_id: permitted_ids).order(:td_chat_id, :telegram_account_id)
      grouped = rows.group_by(&:td_chat_id)

      render json: grouped.values.map { |entries| serialize_chat(entries.first, entries.size) }
    end

    def chat
      chat_id = permitted_chat_id
      return head :forbidden if chat_id.nil?

      rows = TelegramChat.where(td_chat_id: chat_id).order(:telegram_account_id)
      force_refresh = ActiveModel::Type::Boolean.new.cast(params[:refresh])
      if force_refresh || rows.empty?
        refresh_chat(chat_id, force: force_refresh)
        rows = TelegramChat.where(td_chat_id: chat_id).order(:telegram_account_id)
      end
      return head :not_found if rows.empty?

      render json: serialize_chat(rows.first, rows.size)
    end

    def chat_members
      chat_id = permitted_chat_id
      return head :forbidden if chat_id.nil?
      query = params[:q].to_s.strip

      page = params[:page].to_i
      page = 1 if page < 1
      per_page = (params[:per_page] || params[:limit] || 20).to_i.clamp(1, 200)
      offset = (page - 1) * per_page

      force_refresh = ActiveModel::Type::Boolean.new.cast(params[:refresh])
      cached_members_exist = TelegramChatUsername.where(group_id: chat_id).where("uid > 0").exists?
      refresh_chat_members(chat_id, force: force_refresh) if force_refresh || !cached_members_exist
      scope = TelegramChatUsername.where(group_id: chat_id).where("uid > 0")
      if query.present?
        uid = Integer(query, exception: false)
        conditions = [ "name &@~ :query OR username &@~ :query" ]
        bindings = { query: query }
        if uid
          conditions << "uid = :uid"
          bindings[:uid] = uid
        end
        scope = scope.where(conditions.join(" OR "), bindings)
      end
      total = scope.count
      members = scope.order(last_seen: :desc, uid: :asc).offset(offset).limit(per_page)

      render json: {
        page:,
        per_page:,
        total:,
        items: members.map { |member| serialize_member(member) }
      }
    end

    def search_messages
      query = params.require(:q).to_s.strip
      chat_id = params[:chat_id].to_i if params[:chat_id].present?
      user_ids = normalize_integer_list(params[:user_ids])
      include_deleted = ActiveModel::Type::Boolean.new.cast(params[:include_deleted])
      resolve_links = ActiveModel::Type::Boolean.new.cast(params[:resolve_links])
      start_at = parse_time_param(:start_at)
      end_at = parse_time_param(:end_at)
      order_direction = message_search_order_direction
      page = params[:page].to_i
      page = 1 if page < 1
      per_page = (params[:per_page] || params[:limit] || 50).to_i.clamp(1, 200)
      offset = (page - 1) * per_page

      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      permitted_ids &= [ chat_id ] if chat_id.present?
      return render json: [] if permitted_ids.empty?

      scope = TelegramMessage.where(td_chat_id: permitted_ids)
      scope = scope.where(deleted_at: nil) unless include_deleted
      scope = scope.where(td_sender_id: user_ids) if user_ids.any?
      scope = scope.where("message_at >= ?", start_at) if start_at
      scope = scope.where("message_at <= ?", end_at) if end_at
      if query.present?
        mode = params[:mode].to_s
        if mode == "regex"
          scope = scope.where("text &~ ?", query)
        else
          scope = scope.where("text &@~ ?", query)
        end
      end

      total = scope.count
      highlight_sql = if query.present?
                        ActiveRecord::Base.send(
                          :sanitize_sql_array,
                          [ "pgroonga_highlight_html(text, ARRAY[?]::text[]) AS highlight", query ]
                        )
      else
                        "NULL AS highlight"
      end
      messages = scope
                 .includes(:telegram_account)
                 .select("telegram_messages.*", highlight_sql)
                 .order(message_at: order_direction, id: order_direction)
                 .offset(offset)
                 .limit(per_page)

      poll_map = poll_map_for(messages)
      account_poll_state_map = account_poll_state_map_for(messages)
      member_map = TelegramChatUsername.where(
        group_id: messages.map(&:td_chat_id).uniq,
        uid: messages.map(&:td_sender_id).compact.uniq
      ).index_by { |row| [ row.group_id, row.uid ] }
      message_link_sessions = {}

      render json: {
        page:,
        per_page:,
        total:,
        items: messages.map do |message|
          serialize_message(
            message,
            member_map,
            poll_map:,
            account_poll_state_map:,
            resolve_links:,
            message_link_sessions:
          ).merge(highlight: message.try(:highlight))
        end
      }
    end

    private

    def parse_time_param(name)
      value = params[name].to_s
      return nil if value.blank?

      Time.zone.parse(value)
    rescue ArgumentError
      nil
    end

    def message_search_order_direction
      params[:order].to_s.downcase == "asc" ? :asc : :desc
    end

    def serialize_chat(chat, source_count)
      {
        td_chat_id: chat.td_chat_id,
        title: chat.title,
        chat_type: chat.chat_type,
        avatar_small_content_type: chat.avatar_small_content_type,
        avatar_small_base64: base64_blob(chat.avatar_small_data),
        source_session_id: chat.telegram_account.uuid,
        source_count: source_count
      }
    end

    def serialize_message(message, member_map, poll_map:, account_poll_state_map:, resolve_links:, message_link_sessions:)
      member = member_map[[ message.td_chat_id, message.td_sender_id ]]
      poll_key = [ message.telegram_account_id, message.td_chat_id, message.message_id ]
      resolved_link = resolve_links ? resolve_message_link_data(message, message_link_sessions:) : {}
      channel_id = resolved_link[:channel_id] || telegram_privatepost_channel_id(message.td_chat_id)
      post_id = resolved_link[:post_id] || message.message_id
      privatepost_url = build_privatepost_url(channel_id:, post_id:) || resolved_link[:url]

      {
        td_chat_id: message.td_chat_id,
        td_message_id: message.try(:td_message_id),
        message_id: post_id,
        tg_privatepost_channel_id: channel_id,
        tg_privatepost_url: privatepost_url,
        telegram_message_link: resolved_link[:url],
        text: message.text,
        sender_id: message.td_sender_id,
        sender_name: member&.name.presence || message.sender_name,
        sender_username: member&.username,
        sender_avatar_small_content_type: member&.avatar_small_content_type,
        sender_avatar_small_base64: base64_blob(member&.avatar_small_data),
        message_at: message.message_at,
        poll: serialize_poll(poll_map[poll_key], account_poll_state_map[poll_key])
      }
    end

    def serialize_poll(poll, account_state)
      return nil if poll.nil?

      {
        question: poll.question,
        is_anonymous: poll.is_anonymous,
        allows_multiple_answers: poll.allows_multiple_answers,
        total_voter_count: poll.total_voter_count,
        is_closed: poll.is_closed,
        options: serialize_poll_options(poll),
        account_state: {
          has_voted: account_state&.has_voted || false,
          chosen_option_indexes: account_state&.chosen_option_indexes || []
        }
      }
    end

    def serialize_poll_options(poll)
      option_rows = poll.telegram_poll_options.sort_by(&:option_index)
      return option_rows.map { |option| serialize_poll_option_row(option) } if option_rows.any?

      raw_options = poll.raw_payload.is_a?(Hash) ? poll.raw_payload["options"] : nil
      return [] unless raw_options.is_a?(Array)

      raw_options.each_with_index.filter_map do |option, index|
        serialize_raw_poll_option(option, index)
      end
    end

    def serialize_poll_option_row(option)
      {
        option_index: option.option_index,
        text: option.text,
        voter_count: option.voter_count,
        is_chosen: option.is_chosen
      }
    end

    def serialize_raw_poll_option(option, index)
      return nil unless option.is_a?(Hash)

      normalized_option = option.deep_stringify_keys
      text = extract_formatted_text(normalized_option["text"])
      return nil if text.blank?

      {
        option_index: index,
        text: text,
        voter_count: normalized_option["voter_count"].to_i,
        is_chosen: ActiveModel::Type::Boolean.new.cast(normalized_option["is_chosen"]) || false
      }
    end

    def extract_formatted_text(value)
      case value
      when String
        value
      when Hash
        value.deep_stringify_keys["text"]
      end
    end

    def serialize_member(member)
      {
        uid: member.uid,
        group_id: member.group_id,
        name: member.name,
        username: member.username,
        last_seen: member.last_seen,
        avatar_small_content_type: member.avatar_small_content_type,
        avatar_small_base64: base64_blob(member.avatar_small_data)
      }
    end

    def base64_blob(blob)
      return nil if blob.blank?

      Base64.strict_encode64(blob)
    end

    def normalize_integer_list(raw_value)
      Array(raw_value)
        .flat_map { |value| value.to_s.split(",") }
        .map(&:strip)
        .reject(&:empty?)
        .filter_map { |value| Integer(value, exception: false) }
        .reject(&:zero?)
        .uniq
    end

    def poll_map_for(messages)
      message_rows = messages.to_a
      exact_poll_map = exact_message_tuple_scope(TelegramPoll.all, message_rows)
                       .includes(:telegram_poll_options)
                       .index_by { |poll| message_poll_key(poll) }
      missing_messages = message_rows.reject { |message| exact_poll_map.key?(message_poll_key(message)) }
      return exact_poll_map if missing_messages.empty?

      fallback_poll_map = chat_message_tuple_scope(TelegramPoll.all, missing_messages)
                          .includes(:telegram_poll_options)
                          .order(updated_at: :desc)
                          .group_by { |poll| [ poll.td_chat_id, poll.message_id ] }
                          .transform_values(&:first)
      missing_messages.each do |message|
        fallback_poll = fallback_poll_map[[ message.td_chat_id, message.message_id ]]
        exact_poll_map[message_poll_key(message)] = fallback_poll if fallback_poll.present?
      end
      exact_poll_map
    end

    def account_poll_state_map_for(messages)
      exact_message_tuple_scope(TelegramAccountPollState.all, messages)
        .index_by do |account_state|
        message_poll_key(account_state)
      end
    end

    def message_poll_key(record)
      [ record.telegram_account_id, record.td_chat_id, record.message_id ]
    end

    def exact_message_tuple_scope(scope, messages)
      tuples = messages.map { |message| [ message.telegram_account_id, message.td_chat_id, message.message_id ] }.uniq
      return scope.none if tuples.empty?

      placeholders = tuples.map { "(?, ?, ?)" }.join(", ")
      predicate = ActiveRecord::Base.send(
        :sanitize_sql_array,
        [ "(telegram_account_id, td_chat_id, message_id) IN (#{placeholders})", *tuples.flatten ]
      )

      scope.where(predicate)
    end

    def chat_message_tuple_scope(scope, messages)
      tuples = messages.map { |message| [ message.td_chat_id, message.message_id ] }.uniq
      return scope.none if tuples.empty?

      placeholders = tuples.map { "(?, ?)" }.join(", ")
      predicate = ActiveRecord::Base.send(
        :sanitize_sql_array,
        [ "(td_chat_id, message_id) IN (#{placeholders})", *tuples.flatten ]
      )

      scope.where(predicate)
    end

    def telegram_privatepost_channel_id(td_chat_id)
      chat_id_abs = td_chat_id.to_i.abs
      return nil if chat_id_abs < TD_SUPERGROUP_CHAT_ABS_PREFIX

      channel_id = chat_id_abs - TD_SUPERGROUP_CHAT_ABS_PREFIX
      return nil if channel_id <= 0

      channel_id
    end

    def build_privatepost_url(channel_id:, post_id:)
      return nil if channel_id.nil? || post_id.nil?

      "tg://privatepost?channel=#{channel_id}&post=#{post_id}"
    end

    def resolve_message_link_data(message, message_link_sessions:)
      td_message_id = message.try(:td_message_id).to_i
      return {} if td_message_id <= 0

      session = message_link_session_for(message, message_link_sessions:)
      return {} if session.nil?

      link = session.resolve_message_link(chat_id: message.td_chat_id, td_message_id:)
      parse_message_link(link, fallback_channel_id: telegram_privatepost_channel_id(message.td_chat_id))
    rescue StandardError => e
      Rails.logger.warn("Failed resolving link for message #{message.id}: #{e.message}")
      {}
    end

    def message_link_session_for(message, message_link_sessions:)
      account = message.telegram_account
      return nil if account.nil? || !account.enabled?

      message_link_sessions[account.id] ||= begin
        ::Telegram::Runtime.fetch(account.uuid) || ::Telegram::Runtime.start(account)
      rescue StandardError => e
        Rails.logger.warn("Failed starting session for account #{account.uuid}: #{e.message}")
        nil
      end
    end

    def parse_message_link(url, fallback_channel_id:)
      return {} if url.blank?

      case url
      when TG_PRIVATEPOST_URL_PATTERN
        {
          url:,
          channel_id: Regexp.last_match(1).to_i,
          post_id: Regexp.last_match(2).to_i
        }
      when T_ME_C_URL_PATTERN
        {
          url:,
          channel_id: Regexp.last_match(1).to_i,
          post_id: Regexp.last_match(2).to_i
        }
      when T_ME_PUBLIC_URL_PATTERN
        {
          url:,
          channel_id: fallback_channel_id,
          post_id: Regexp.last_match(1).to_i
        }
      else
        { url:, channel_id: fallback_channel_id }
      end
    end

    def refresh_chat_members(chat_id, force: false)
      accounts = chat_accounts(chat_id)
      return if accounts.empty?

      enqueued = accounts.filter_map do |account|
        session = ::Telegram::Runtime.fetch(account.uuid)
        next if !force && session&.operation_in_progress?

        sync = Telegram::GroupMemberSyncJob.perform_later(
          account_uuid: account.uuid,
          chat_ids: [ chat_id.to_i ],
          refresh_avatars: true,
          reason: "api_me_chat_members",
          retry_attempt: 0
        )
        { account_uuid: account.uuid, job_id: sync.job_id }
      rescue StandardError => e
        Rails.logger.warn("Failed enqueueing member refresh for chat #{chat_id} account #{account.uuid}: #{e.message}")
        nil
      end

      Rails.logger.info("Enqueued member refresh for chat #{chat_id}: #{enqueued.inspect}") if enqueued.any?
    rescue StandardError => e
      Rails.logger.warn("Failed refreshing members for chat #{chat_id}: #{e.message}")
    end

    def refresh_chat(chat_id, force: false)
      accounts = chat_accounts(chat_id)
      return if accounts.empty?

      accounts.each do |account|
        session = ::Telegram::Runtime.fetch(account.uuid)
        if !force && session&.operation_in_progress?
          Rails.logger.info("Skip refresh for chat #{chat_id}: session #{session.id} is busy")
          next
        end

        refresh = Telegram::ChatRefreshJob.perform_later(
          account_uuid: account.uuid,
          chat_id: chat_id.to_i,
          refresh_avatar: true,
          reason: "api_me_chat"
        )
        Rails.logger.info(
          "Enqueued chat refresh for chat #{chat_id} account #{account.uuid}: job_id=#{refresh.job_id}"
        )
        return
      rescue StandardError => e
        Rails.logger.warn("Failed enqueueing chat refresh for chat #{chat_id} account #{account.uuid}: #{e.message}")
      end
    rescue StandardError => e
      Rails.logger.warn("Failed refreshing chat #{chat_id}: #{e.message}")
    end

    def chat_accounts(chat_id)
      account_ids = recent_message_account_ids(chat_id) + recent_chat_account_ids(chat_id) + watched_chat_account_ids(chat_id)
      account_ids = account_ids.map(&:to_i).uniq
      return [] if account_ids.empty?

      accounts_by_id = TelegramAccount.where(id: account_ids, enabled: true).index_by(&:id)

      account_ids.filter_map { |account_id| accounts_by_id[account_id] }
    end

    def watched_chat_account_ids(chat_id)
      TelegramAccountWatchTarget.joins(:telegram_account)
                               .where(td_chat_id: chat_id, telegram_accounts: { enabled: true })
                               .pluck(:telegram_account_id)
    end

    def recent_message_account_ids(chat_id)
      TelegramMessage.joins(:telegram_account)
                     .where(td_chat_id: chat_id, telegram_accounts: { enabled: true })
                     .group("telegram_messages.telegram_account_id")
                     .order(Arel.sql("MAX(telegram_messages.message_at) DESC"))
                     .pluck("telegram_messages.telegram_account_id")
    end

    def recent_chat_account_ids(chat_id)
      chat = TelegramChat.includes(:telegram_account)
                         .where(td_chat_id: chat_id)
                         .where(telegram_accounts: { enabled: true })
                         .references(:telegram_account)
                         .order(updated_at: :desc)
      chat.pluck(:telegram_account_id)
    end

    def permitted_chat_id
      chat_id = params.require(:chat_id).to_i
      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      return nil unless permitted_ids.include?(chat_id)

      chat_id
    end
  end
end
