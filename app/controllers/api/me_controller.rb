# frozen_string_literal: true

require "base64"

module Api
  class MeController < ApplicationController
    before_action :authenticate_system_user!

    TDLIB_MESSAGE_ID_SHIFT = 20
    TD_SUPERGROUP_CHAT_ABS_PREFIX = 1_000_000_000_000

    def chats
      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      rows = TelegramChat.where(td_chat_id: permitted_ids).order(:td_chat_id, :telegram_account_id)
      grouped = rows.group_by(&:td_chat_id)

      render json: grouped.values.map { |entries| serialize_chat(entries.first, entries.size) }
    end

    def chat
      chat_id = permitted_chat_id
      return head :forbidden if chat_id.nil?

      refresh_chat(chat_id)
      rows = TelegramChat.where(td_chat_id: chat_id).order(:telegram_account_id)
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

      refresh_chat_members(chat_id)
      scope = TelegramChatUsername.where(group_id: chat_id).where("uid > 0")
      if query.present?
        uid = Integer(query, exception: false)
        conditions = ["name &@~ :query OR username &@~ :query"]
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
      page = params[:page].to_i
      page = 1 if page < 1
      per_page = (params[:per_page] || params[:limit] || 50).to_i.clamp(1, 200)
      offset = (page - 1) * per_page

      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      permitted_ids &= [chat_id] if chat_id.present?
      return render json: [] if permitted_ids.empty?

      scope = TelegramMessage.where(td_chat_id: permitted_ids)
      scope = scope.where(td_sender_id: user_ids) if user_ids.any?
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
                          ["pgroonga_highlight_html(text, ARRAY[?]::text[]) AS highlight", query]
                        )
                      else
                        "NULL AS highlight"
                      end
      messages = scope
                 .select("telegram_messages.*", highlight_sql)
                 .order(message_at: :desc)
                 .offset(offset)
                 .limit(per_page)

      member_map = TelegramChatUsername.where(
        group_id: messages.map(&:td_chat_id).uniq,
        uid: messages.map(&:td_sender_id).compact.uniq
      ).index_by { |row| [row.group_id, row.uid] }

      render json: {
        page:,
        per_page:,
        total:,
        items: messages.map { |m| serialize_message(m, member_map).merge(highlight: m.try(:highlight)) }
      }
    end

    private

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

    def serialize_message(message, member_map)
      member = member_map[[message.td_chat_id, message.td_sender_id]]
      post_id = telegram_post_id(message.td_message_id)
      channel_id = telegram_privatepost_channel_id(message.td_chat_id)
      privatepost_url = build_privatepost_url(channel_id:, post_id:)

      {
        td_chat_id: message.td_chat_id,
        td_message_id: message.td_message_id,
        message_id: post_id,
        tg_privatepost_channel_id: channel_id,
        tg_privatepost_url: privatepost_url,
        text: message.text,
        sender_id: message.td_sender_id,
        sender_name: member&.name.presence || message.sender_name,
        sender_username: member&.username,
        sender_avatar_small_content_type: member&.avatar_small_content_type,
        sender_avatar_small_base64: base64_blob(member&.avatar_small_data),
        message_at: message.message_at
      }
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

    def telegram_post_id(td_message_id)
      message_id = td_message_id.to_i
      return nil if message_id <= 0

      message_id >> TDLIB_MESSAGE_ID_SHIFT
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

    def refresh_chat_members(chat_id)
      sessions = chat_sessions(chat_id)
      return if sessions.empty?

      attempts = []
      sessions.each do |session|
        next unless session_ready_for_refresh?(session, chat_id)

        begin
          session.refresh_chat(chat_id:, refresh_avatar: true)
          sync = session.sync_group_members_for_chats(chat_ids: [chat_id], refresh_avatars: true)
          attempts << { session_id: session.id, sync: }
          return if sync[:failed].to_i.zero?
        rescue StandardError => e
          attempts << { session_id: session.id, error: e.message }
        end
      end

      Rails.logger.warn("Member sync attempts exhausted for chat #{chat_id}: #{attempts.inspect}")
    rescue StandardError => e
      Rails.logger.warn("Failed refreshing members for chat #{chat_id}: #{e.message}")
    end

    def refresh_chat(chat_id)
      sessions = chat_sessions(chat_id)
      return if sessions.empty?

      sessions.each do |session|
        next unless session_ready_for_refresh?(session, chat_id)

        session.refresh_chat(chat_id:, refresh_avatar: true)
        return
      rescue StandardError => e
        Rails.logger.warn("Failed refreshing chat #{chat_id} with session #{session.id}: #{e.message}")
      end
    rescue StandardError => e
      Rails.logger.warn("Failed refreshing chat #{chat_id}: #{e.message}")
    end

    def session_ready_for_refresh?(session, chat_id)
      state = session.wait_for_initial_state(timeout: 3)
      if state == :initializing
        session.wait_until_ready!(timeout: 20)
        state = session.snapshot[:state]
      end
      return true if state == :ready

      Rails.logger.info("Skip refresh for chat #{chat_id}: session state is #{state}")
      false
    rescue StandardError => e
      Rails.logger.warn("Failed checking session state for chat #{chat_id}: #{e.message}")
      false
    end

    def chat_session(chat_id)
      chat_sessions(chat_id).first
    end

    def chat_sessions(chat_id)
      account_ids = recent_message_account_ids(chat_id) + recent_chat_account_ids(chat_id)
      account_ids = account_ids.map(&:to_i).uniq
      return [] if account_ids.empty?

      accounts_by_id = TelegramAccount.where(id: account_ids, enabled: true).index_by(&:id)

      account_ids.filter_map do |account_id|
        account = accounts_by_id[account_id]
        next if account.nil?

        ::Telegram::Runtime.fetch(account.uuid) || ::Telegram::Runtime.start(account)
      rescue StandardError => e
        Rails.logger.warn("Failed starting session for account #{account_id}: #{e.message}")
        nil
      end
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
