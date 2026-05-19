# frozen_string_literal: true

module Api
  class MeController < ApplicationController
    before_action :authenticate_system_user!
    skip_before_action :authenticate_system_user!, only: %i[chat_avatar chat_member_avatar]

    TD_SUPERGROUP_CHAT_ABS_PREFIX = 1_000_000_000_000
    TG_PRIVATEPOST_URL_PATTERN = %r{\Atg://privatepost\?(?:[^#]*&)?channel=(\d+)&post=(\d+)\b}.freeze
    T_ME_C_URL_PATTERN = %r{\Ahttps?://t\.me/c/(\d+)/(\d+)(?:\?.*)?\z}.freeze
    T_ME_PUBLIC_URL_PATTERN = %r{\Ahttps?://t\.me/[^/]+/(\d+)(?:\?.*)?\z}.freeze

    def chats
      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      rows = TelegramChat.where(td_chat_id: permitted_ids).order(:td_chat_id, :telegram_account_id)
      grouped = rows.group_by(&:td_chat_id)

      render json: grouped.values.map { |entries| serialize_chat(entries.first, entries.size, avatar_source: avatar_source_from(entries)) }
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

      render json: serialize_chat(rows.first, rows.size, avatar_source: avatar_source_from(rows))
    end

    def chat_avatar
      chat = avatar_source_from(TelegramChat.where(td_chat_id: params.require(:chat_id).to_i))
      return head :not_found if chat.nil? || chat.avatar_small_data.blank?

      send_avatar(chat)
    end

    def chat_member_avatar
      member = TelegramChatUsername.find_by(group_id: params.require(:chat_id).to_i, uid: params.require(:uid).to_i)
      return head :not_found if member.nil? || member.avatar_small_data.blank?

      send_avatar(member)
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
      return render json: { error: "q is required" }, status: :bad_request unless params.key?(:q)

      query = params[:q].to_s.strip
      chat_id = params[:chat_id].to_i if params[:chat_id].present?
      user_ids = normalize_integer_list(params[:user_ids])
      include_deleted = ActiveModel::Type::Boolean.new.cast(params[:include_deleted])
      resolve_links = ActiveModel::Type::Boolean.new.cast(params[:resolve_links])
      poll_option_search = query.present? && ActiveModel::Type::Boolean.new.cast(params[:is_poll_option])
      start_at = parse_message_time_param(:start_at, boundary: :start)
      return if performed?

      end_at = parse_message_time_param(:end_at, boundary: :end)
      return if performed?

      if start_at.present? && end_at.present? && start_at > end_at
        return render json: { error: "start_at must be earlier than or equal to end_at" }, status: :bad_request
      end

      message_order = normalize_message_order
      return if performed?

      page = params[:page].to_i
      page = 1 if page < 1
      per_page = (params[:per_page] || params[:limit] || 50).to_i.clamp(1, 200)
      offset = (page - 1) * per_page

      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      permitted_ids &= [ chat_id ] if chat_id.present?
      return render json: [] if permitted_ids.empty?

      scope = TelegramMessage.where(telegram_messages: { td_chat_id: permitted_ids })
      scope = scope.where(telegram_messages: { deleted_at: nil }) unless include_deleted
      scope = scope.where(telegram_messages: { td_sender_id: user_ids }) if user_ids.any?
      scope = apply_message_time_range(scope, start_at:, end_at:)
      scope = apply_message_query(scope, query:, mode: params[:mode].to_s, poll_option_search:) if query.present?

      total = scope.count
      highlight_sql = if query.present?
                        ActiveRecord::Base.send(
                          :sanitize_sql_array,
                          [
                            "pgroonga_highlight_html(#{message_highlight_source_sql(poll_option_search:)}, ARRAY[?]::text[]) AS highlight",
                            query
                          ]
                        )
      else
                        "NULL AS highlight"
      end
      messages = scope
                 .joins(search_message_poll_join_sql(query:, mode: params[:mode].to_s, poll_option_search:))
                 .includes(:telegram_account)
                 .select("telegram_messages.*", highlight_sql, "matched_telegram_polls.id AS matched_poll_id", "matched_telegram_polls.matched_option_text AS matched_poll_option_text")
                 .reorder(*message_order_nodes(message_order))
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
          ).merge(
            highlight: message.try(:highlight),
            is_poll_option: poll_option_search,
            matched_poll_option_text: message.try(:matched_poll_option_text)
          )
        end
      }
    end

    private

    def serialize_chat(chat, source_count, avatar_source: chat)
      {
        td_chat_id: chat.td_chat_id,
        title: chat.title,
        chat_type: chat.chat_type,
        avatar_small_content_type: avatar_source&.avatar_small_content_type,
        avatar_small_url: chat_avatar_small_url(avatar_source),
        avatar_small_cache_key: avatar_cache_key(avatar_source),
        source_session_id: chat.telegram_account.uuid,
        source_count: source_count
      }
    end

    def serialize_message(message, member_map, poll_map:, account_poll_state_map:, resolve_links:, message_link_sessions:)
      member = member_map[[ message.td_chat_id, message.td_sender_id ]]
      poll = poll_map[matched_poll_id(message)]
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
        text: message.text.presence || poll&.question,
        sender_id: message.td_sender_id,
        sender_name: member&.name.presence || message.sender_name,
        sender_username: member&.username,
        sender_avatar_small_content_type: member&.avatar_small_content_type,
        sender_avatar_small_url: member_avatar_small_url(member),
        sender_avatar_small_cache_key: avatar_cache_key(member),
        message_at: message.message_at,
        poll: serialize_poll(poll, account_poll_state_map[poll_key])
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
      row_options = option_rows.map { |option| serialize_poll_option_row(option) }
      raw_options = serialize_raw_poll_options(poll)

      return raw_options if raw_options.size > row_options.size
      return row_options if row_options.any?

      raw_options
    end

    def serialize_raw_poll_options(poll)
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
        is_chosen: option.is_chosen,
        is_correct: option.is_correct
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
        is_chosen: boolean_or_default(normalized_option["is_chosen"], default: false),
        is_correct: normalized_option.key?("is_correct") ? boolean_or_nil(normalized_option["is_correct"]) : nil
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
        avatar_small_url: member_avatar_small_url(member),
        avatar_small_cache_key: avatar_cache_key(member)
      }
    end

    def chat_avatar_small_url(chat)
      return nil if chat.nil? || chat.avatar_small_data.blank?

      "#{request.base_url}/api/me/chats/#{chat.td_chat_id}/avatar?v=#{avatar_cache_key(chat)}"
    end

    def member_avatar_small_url(member)
      return nil if member.nil? || member.avatar_small_data.blank?

      "#{request.base_url}/api/me/chats/#{member.group_id}/members/#{member.uid}/avatar?v=#{avatar_cache_key(member)}"
    end

    def avatar_cache_key(record)
      return nil if record.nil? || record.avatar_small_data.blank?

      [ record.avatar_small_file_id, record.avatar_small_fetched_at&.to_i, record.avatar_small_data.bytesize ].compact.join("-")
    end

    def avatar_source_from(records)
      records.select { |record| record.avatar_small_data.present? }.max_by { |record| record.avatar_small_fetched_at || Time.at(0) }
    end

    def send_avatar(record)
      expires_in 1.year, public: true
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data record.avatar_small_data,
                type: avatar_content_type(record),
                disposition: "inline",
                filename: "avatar"
    end

    def avatar_content_type(record)
      content_type = record.avatar_small_content_type.to_s
      return content_type if content_type.start_with?("image/")

      "application/octet-stream"
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

    def parse_message_time_param(name, boundary:)
      raw_value = message_time_param_value(name)
      return nil if raw_value.blank?

      parse_message_time_value(raw_value, boundary:)
    rescue ArgumentError
      render json: { error: "Invalid #{name}" }, status: :bad_request
      nil
    end

    def message_time_param_value(name)
      aliases = case name.to_sym
                when :start_at
                  %i[start_time start_date from date_from]
                when :end_at
                  %i[end_time end_date to date_to]
                else
                  []
      end

      ([ name ] + aliases).each do |param_name|
        value = params[param_name]
        return value if value.present?
      end

      nil
    end

    def parse_message_time_value(raw_value, boundary:)
      value = raw_value.to_s.strip
      if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        date = Date.iso8601(value)
        time = boundary == :end ? date.end_of_day : date.beginning_of_day
        return time.in_time_zone.utc
      end

      Time.zone.iso8601(value).utc
    end

    def apply_message_time_range(scope, start_at:, end_at:)
      message_at = TelegramMessage.arel_table[:message_at]
      return scope.where(telegram_messages: { message_at: start_at..end_at }) if start_at.present? && end_at.present?
      return scope.where(message_at.gteq(start_at)) if start_at.present?
      return scope.where(message_at.lteq(end_at)) if end_at.present?

      scope
    end

    def apply_message_query(scope, query:, mode:, poll_option_search:)
      operator = message_search_operator(mode)
      predicate = ActiveRecord::Base.send(
        :sanitize_sql_array,
        poll_option_search ? poll_option_search_predicate(operator, query) : message_search_predicate(operator, query)
      )

      scope.where(predicate)
    end

    def message_search_operator(mode)
      mode == "regex" ? "&~" : "&@~"
    end

    def message_search_predicate(operator, query)
      [
        <<~SQL.squish,
          (
            telegram_messages.text #{operator} ?
            OR (
              COALESCE(telegram_messages.text, '') = ''
              AND EXISTS (
                SELECT 1
                FROM telegram_polls
                WHERE telegram_polls.td_chat_id = telegram_messages.td_chat_id
                  AND telegram_polls.message_id = telegram_messages.message_id
                  AND telegram_polls.question #{operator} ?
              )
            )
          )
        SQL
        query,
        query
      ]
    end

    def poll_option_search_predicate(operator, query)
      [
        <<~SQL.squish,
          EXISTS (
            SELECT 1
            FROM telegram_polls
            LEFT JOIN telegram_poll_options ON telegram_poll_options.telegram_poll_id = telegram_polls.id
            LEFT JOIN LATERAL jsonb_array_elements(#{raw_poll_options_sql}) AS raw_option(value) ON TRUE
            WHERE telegram_polls.td_chat_id = telegram_messages.td_chat_id
              AND telegram_polls.message_id = telegram_messages.message_id
              AND (
                telegram_poll_options.text #{operator} ?
                OR #{raw_poll_option_text_sql} #{operator} ?
              )
          )
        SQL
        query,
        query
      ]
    end

    def message_highlight_source_sql(poll_option_search:)
      return "matched_telegram_polls.matched_option_text" if poll_option_search

      "COALESCE(telegram_messages.text, matched_telegram_polls.question)"
    end

    def normalize_message_order
      raw_value = params[:order].presence || params[:direction].presence || params[:sort_order].presence || params[:sort].presence
      order = raw_value.to_s.strip.downcase
      return "desc" if order.blank?
      return "asc" if %w[asc ascend ascending oldest oldest_first 1].include?(order)
      return "desc" if %w[desc descend descending newest newest_first latest -1].include?(order)

      render json: { error: "Invalid order" }, status: :bad_request
      nil
    end

    def message_order_nodes(order)
      table = TelegramMessage.arel_table
      direction = order.to_sym
      [
        table[:message_at].public_send(direction),
        table[:td_chat_id].public_send(direction),
        table[:message_id].public_send(direction),
        table[:id].public_send(direction)
      ]
    end

    def boolean_or_default(value, default:)
      boolean = strict_boolean_value(value)
      boolean.nil? ? default : boolean
    end

    def boolean_or_nil(value)
      strict_boolean_value(value)
    end

    def strict_boolean_value(value)
      case value
      when true, false
        value
      when 1, "1", "true", "TRUE", "t", "T"
        true
      when 0, "0", "false", "FALSE", "f", "F"
        false
      end
    end

    def poll_map_for(messages)
      poll_ids = messages.filter_map { |message| matched_poll_id(message) }.uniq
      return {} if poll_ids.empty?

      TelegramPoll.where(id: poll_ids).includes(:telegram_poll_options).index_by(&:id)
    end

    def matched_poll_id(message)
      message.try(:matched_poll_id).to_i.presence
    end

    def search_message_poll_join_sql(query:, mode:, poll_option_search:)
      return poll_option_search_join_sql(query:, mode:) if poll_option_search

      <<~SQL.squish
        LEFT JOIN LATERAL (
          SELECT telegram_polls.id, telegram_polls.question, NULL::text AS matched_option_text
          FROM telegram_polls
          WHERE telegram_polls.td_chat_id = telegram_messages.td_chat_id
            AND telegram_polls.message_id = telegram_messages.message_id
          ORDER BY (telegram_polls.telegram_account_id = telegram_messages.telegram_account_id) DESC,
                   telegram_polls.updated_at DESC,
                   telegram_polls.id DESC
          LIMIT 1
        ) matched_telegram_polls ON TRUE
      SQL
    end

    def poll_option_search_join_sql(query:, mode:)
      operator = message_search_operator(mode)
      ActiveRecord::Base.send(
        :sanitize_sql_array,
        [
          <<~SQL.squish,
            LEFT JOIN LATERAL (
              SELECT telegram_polls.id,
                     telegram_polls.question,
                     COALESCE(matched_option.text, matched_raw_option.text) AS matched_option_text
              FROM telegram_polls
              LEFT JOIN LATERAL (
                SELECT telegram_poll_options.text
                FROM telegram_poll_options
                WHERE telegram_poll_options.telegram_poll_id = telegram_polls.id
                  AND telegram_poll_options.text #{operator} ?
                ORDER BY telegram_poll_options.option_index ASC
                LIMIT 1
              ) matched_option ON TRUE
              LEFT JOIN LATERAL (
                SELECT #{raw_poll_option_text_sql} AS text
                FROM jsonb_array_elements(#{raw_poll_options_sql}) AS raw_option(value)
                WHERE #{raw_poll_option_text_sql} #{operator} ?
                LIMIT 1
              ) matched_raw_option ON TRUE
              WHERE telegram_polls.td_chat_id = telegram_messages.td_chat_id
                AND telegram_polls.message_id = telegram_messages.message_id
                AND (matched_option.text IS NOT NULL OR matched_raw_option.text IS NOT NULL)
              ORDER BY (telegram_polls.telegram_account_id = telegram_messages.telegram_account_id) DESC,
                       telegram_polls.updated_at DESC,
                       telegram_polls.id DESC
              LIMIT 1
            ) matched_telegram_polls ON TRUE
          SQL
          query,
          query
        ]
      )
    end

    def raw_poll_options_sql
      "CASE WHEN jsonb_typeof(telegram_polls.raw_payload -> 'options') = 'array' THEN telegram_polls.raw_payload -> 'options' ELSE '[]'::jsonb END"
    end

    def raw_poll_option_text_sql
      "CASE WHEN jsonb_typeof(raw_option.value -> 'text') = 'object' THEN raw_option.value #>> '{text,text}' ELSE raw_option.value ->> 'text' END"
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
