# frozen_string_literal: true

module Telegram
  class TdSession
    class InvalidStateError < StandardError; end

    attr_reader :id

    def initialize(account:)
      raise "TD gem is not configured" unless defined?(TD)

      @account_id = account.id
      @id = account.uuid
      @mutex = Mutex.new
      @state = :initializing
      @me = nil
      @last_error = nil
      @disposed = false
      @sender_name_cache = {}

      @client = TD::Client.new(**client_config(account))
      subscribe_updates
      @client.connect
    end

    def submit_phone(phone_number:)
      raise_if_disposed!
      ensure_state!(:wait_phone_number)
      @client.set_authentication_phone_number(phone_number:, settings: nil).wait
      persist_account(phone_number:)
      snapshot
    rescue StandardError => e
      capture_error(e)
      raise
    end

    def wait_for_initial_state(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        current = @mutex.synchronize { @state }
        return current unless current == :initializing
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(0.05)
      end

      @mutex.synchronize { @state }
    end

    def submit_code(code:)
      raise_if_disposed!
      ensure_state!(:wait_code)
      @client.check_authentication_code(code:).wait
      snapshot
    rescue StandardError => e
      capture_error(e)
      raise
    end

    def submit_password(password:)
      raise_if_disposed!
      ensure_state!(:wait_password)
      @client.check_authentication_password(password:).wait
      snapshot
    rescue StandardError => e
      capture_error(e)
      raise
    end

    def snapshot
      @mutex.synchronize do
        {
          session_id: id,
          state: @state,
          me: serialize_user(@me),
          error: @last_error
        }
      end
    end

    def sync_chats_now(limit: nil, force_full: false)
      raise_if_disposed!

      max_limit = (limit || ENV.fetch("TELEGRAM_CHAT_SYNC_LIMIT", "500")).to_i
      max_limit = 1 if max_limit < 1
      sync_chats(limit: max_limit, force_full: force_full)
    end

    def wait_until_ready!(timeout: 60)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        state = @mutex.synchronize { @state }
        return if state == :ready
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise InvalidStateError, "Session state is #{state}"
        end

        sleep(0.1)
      end
    end

    def sync_messages_for_chats(chat_ids:, limit_per_chat: nil, wait_seconds: nil)
      raise_if_disposed!
      wait_until_ready!

      ids = Array(chat_ids).map(&:to_i).uniq
      return { chats: 0, upserted: 0, failed: 0, errors: [] } if ids.empty?

      per_chat_limit = limit_per_chat.present? ? limit_per_chat.to_i : nil
      per_chat_limit = nil if per_chat_limit&.<= 0
      batch_limit = ENV.fetch("TELEGRAM_MESSAGE_SYNC_BATCH_LIMIT", "100").to_i.clamp(1, 500)
      delay = wait_seconds.nil? ? ENV.fetch("TELEGRAM_MESSAGE_SYNC_WAIT_SECONDS", "0.2").to_f : wait_seconds.to_f
      delay = 0.0 if delay.negative?
      result = { chats: ids.size, upserted: 0, failed: 0, errors: [], details: [] }

      ids.each do |chat_id|
        chat_known_to_account = TelegramChat.exists?(telegram_account_id: @account_id, td_chat_id: chat_id)
        chat_title = nil
        last_message_id = nil
        precheck_error = nil
        first_response_info = nil

        begin
          chat = @client.get_chat(chat_id:).wait
          payload = extract_chat_payload(chat)
          chat_title = payload&.dig(:title)
          last_message_id = extract_chat_last_message_id(chat)
          @client.open_chat(chat_id:).wait
          sleep(delay) if delay.positive?
        rescue StandardError => e
          precheck_error = e.message
        end

        from_message_id = 0
        chat_upserted = 0
        chat_fetched = 0
        chat_parsed = 0
        batches = 0
        mode = "history"
        seen_message_ids = {}
        stalled_pages = 0

        loop do
          response = fetch_history_messages_page(
            chat_id:,
            from_message_id:,
            offset: 0,
            limit: batch_limit
          )
          batches += 1
          fetched_count = extract_history_count(response)
          first_response_info ||= describe_response(response)

          if batches == 1 && fetched_count.zero?
            response = fetch_search_messages_page(
              chat_id:,
              from_message_id: 0,
              offset: 0,
              limit: batch_limit
            )
            fetched_count = extract_history_count(response)
            mode = "search" if fetched_count.positive?
          end

          chat_fetched += fetched_count

          messages = extract_history_messages(response)
          messages = messages.sort_by { |message| -message[:td_message_id].to_i }
          chat_parsed += messages.size
          break if messages.empty?

          messages = messages.reject do |message|
            message_id = message[:td_message_id].to_i
            duplicate = seen_message_ids.key?(message_id)
            seen_message_ids[message_id] = true
            duplicate
          end
          break if messages.empty?

          if per_chat_limit
            remaining = per_chat_limit - chat_upserted
            break if remaining <= 0

            messages = messages.first(remaining)
          end

          upsert_usernames_from(messages)
          upserted = upsert_messages_bulk(messages)
          result[:upserted] += upserted
          chat_upserted += upserted

          oldest_message_id = messages.map { |message| message[:td_message_id].to_i }.min.to_i
          break if oldest_message_id <= 0

          if oldest_message_id == from_message_id
            stalled_pages += 1
            break if stalled_pages >= 2
          else
            stalled_pages = 0
          end

          from_message_id = oldest_message_id
          sleep(delay) if delay.positive?
        end
        result[:details] << {
          chat_id:,
          chat_known_to_account:,
          chat_title:,
          last_message_id:,
          precheck_error:,
          mode:,
          batches:,
          fetched: chat_fetched,
          parsed: chat_parsed,
          upserted: chat_upserted,
          first_response: first_response_info
        }
      rescue StandardError => e
        result[:failed] += 1
        result[:errors] << "chat #{chat_id}: #{e.message}"
        result[:details] << {
          chat_id:,
          chat_known_to_account:,
          chat_title:,
          last_message_id:,
          precheck_error:,
          mode:,
          batches:,
          fetched: chat_fetched,
          parsed: chat_parsed,
          upserted: chat_upserted,
          first_response: first_response_info,
          error: e.message
        }
      end

      result
    end

    def dispose
      should_dispose = @mutex.synchronize do
        next false if @disposed

        @disposed = true
        true
      end

      if should_dispose
        @client.dispose
        persist_account(state: "closed", last_state_at: Time.current)
      end
    end

    private

    def subscribe_updates
      @client.on(TD::Types::Update::AuthorizationState) do |update|
        state = map_auth_state(update.authorization_state)
        next if state.nil?

        @mutex.synchronize { @state = state }
        persist_account(
          state: state.to_s,
          last_state_at: Time.current,
          connected_at: (state == :ready ? Time.current : nil),
          last_error: nil
        )
        fetch_me if state == :ready
      end

      @client.on(TD::Types::Update::NewChat) do |update|
        upsert_chat_record(update.chat)
      rescue StandardError => e
        Rails.logger.warn("Failed handling Update::NewChat for account #{@id}: #{e.message}")
      end

      @client.on(TD::Types::Update::NewMessage) do |update|
        handle_new_message(update.message)
      rescue StandardError => e
        Rails.logger.warn("Failed handling Update::NewMessage for account #{@id}: #{e.message}")
      end

      @client.on(TD::Types::Unsupported) do |update|
        handle_unsupported_update(update)
      rescue StandardError => e
        Rails.logger.warn("Failed handling Unsupported update for account #{@id}: #{e.message}")
      end
    end

    def map_auth_state(auth_state)
      case auth_state
      when TD::Types::AuthorizationState::WaitPhoneNumber then :wait_phone_number
      when TD::Types::AuthorizationState::WaitCode then :wait_code
      when TD::Types::AuthorizationState::WaitPassword then :wait_password
      when TD::Types::AuthorizationState::Ready then :ready
      when TD::Types::AuthorizationState::Closed then :closed
      else
        nil
      end
    end

    def fetch_me
      @client.get_me.then { |user| @mutex.synchronize { @me = user } }
        .rescue { |err| @mutex.synchronize { @last_error = err.to_s } }
        .wait
      persist_me
    rescue StandardError => e
      @mutex.synchronize { @last_error = e.message }
      capture_error(e)
    end

    def ensure_state!(expected_state)
      current = @mutex.synchronize { @state }
      return if current == expected_state

      raise InvalidStateError, "Current state is #{current}, expected #{expected_state}"
    end

    def raise_if_disposed!
      disposed = @mutex.synchronize { @disposed }
      raise InvalidStateError, "Session is disposed" if disposed
    end

    def serialize_user(user)
      payload = extract_user_payload(user)
      return nil if payload.nil?

      {
        id: payload[:id],
        first_name: payload[:first_name],
        last_name: payload[:last_name],
        username: payload[:username],
        phone_number: payload[:phone_number]
      }
    end

    def client_config(account)
      config = {
        use_test_dc: account.use_test_dc,
        database_directory: account.database_directory,
        files_directory: account.files_directory
      }

      encryption_key = ENV["TDLIB_DATABASE_ENCRYPTION_KEY"].presence
      config[:database_encryption_key] = encryption_key if encryption_key
      config
    end

    def persist_me
      payload = serialize_user(@me)
      return unless payload

      persist_account(
        td_user_id: payload[:id],
        first_name: payload[:first_name],
        last_name: payload[:last_name],
        username: payload[:username],
        phone_number: payload[:phone_number],
        me_payload: payload,
        last_error: nil
      )
      persist_profile(@me, payload)
    end

    def capture_error(error)
      @mutex.synchronize { @last_error = error.message }
      persist_account(last_error: error.message)
    end

    def persist_account(attrs)
      TelegramAccount.where(id: @account_id).update_all(attrs.merge(updated_at: Time.current))
    end

    def sync_chats_async
      Thread.new do
        sync_chats(limit: ENV.fetch("TELEGRAM_CHAT_SYNC_LIMIT", "500").to_i)
      rescue StandardError => e
        capture_error(e)
      end
    end

    def sync_chats(limit:, force_full: false)
      current_count = TelegramChat.where(telegram_account_id: @account_id).count
      known = TelegramAccount.where(id: @account_id).pick(:known_chat_count)
      if !force_full && known.present? && known == current_count
        return {
          requested_limit: limit,
          skipped: true,
          reason: "known_chat_count_matches",
          total_chat_ids: current_count,
          upserted: 0,
          failed: 0,
          errors: []
        }
      end

      result = {
        requested_limit: limit,
        loaded: false,
        from_get_chats: 0,
        from_search_chats: 0,
        from_search_chats_on_server: 0,
        from_updates_cache: 0,
        total_chat_ids: 0,
        upserted: 0,
        failed: 0,
        errors: []
      }

      main_ids = load_and_get_chat_ids(chat_list: nil, limit:, label: "main", result:)
      archive_ids = load_and_get_chat_ids(chat_list: TD::Types::ChatList::Archive.new, limit:, label: "archive", result:)
      result[:loaded] = true
      chat_ids = main_ids | archive_ids
      result[:from_get_chats] = chat_ids.size

      if chat_ids.empty?
        begin
          offline = @client.search_chats(query: "", limit: [limit, 100].min).wait
          offline_ids = extract_chat_ids(offline)
          result[:from_search_chats] = offline_ids.size
          chat_ids |= offline_ids
        rescue StandardError => e
          result[:errors] << "search_chats: #{e.message}"
        end

        begin
          server = @client.search_chats_on_server(query: "", limit: [limit, 100].min).wait
          server_ids = extract_chat_ids(server)
          result[:from_search_chats_on_server] = server_ids.size
          chat_ids |= server_ids
        rescue StandardError => e
          result[:errors] << "search_chats_on_server: #{e.message}"
        end
      end

      result[:total_chat_ids] = chat_ids.size
      if chat_ids.empty?
        result[:from_updates_cache] = TelegramChat.where(telegram_account_id: @account_id).count
        return result
      end

      attrs_buffer = []
      chat_ids.each do |chat_id|
        chat = @client.get_chat(chat_id: chat_id).wait
        attrs = extract_chat_attrs(chat)
        next if attrs.nil?

        attrs_buffer << attrs
      rescue StandardError => e
        Rails.logger.warn("Failed syncing chat #{chat_id} for account #{@id}: #{e.message}")
        result[:failed] += 1
        result[:errors] << "chat #{chat_id}: #{e.message}"
      end

      result[:upserted] = upsert_chat_records_bulk(attrs_buffer, synced_at: Time.current)
      persist_account(known_chat_count: result[:total_chat_ids])
      result
    rescue StandardError => e
      capture_error(e)
      result ||= { requested_limit: limit, loaded: false, total_chat_ids: 0, upserted: 0, failed: 0, errors: [] }
      result[:errors] << "sync_chats: #{e.message}"
      result
    end

    def chat_sync_needed?
      false
    end

    def load_and_get_chat_ids(chat_list:, limit:, label:, result:)
      ids = []
      5.times do
        begin
          @client.load_chats(chat_list:, limit:).wait
        rescue StandardError => e
          # 404 here usually means all chats already loaded; keep going.
          result[:errors] << "load_chats(#{label}): #{e.message}"
        end

        chats = @client.get_chats(chat_list:, limit:).wait
        ids = extract_chat_ids(chats)
        break if ids.any?

        sleep(0.25)
      end
      ids
    rescue StandardError => e
      result[:errors] << "get_chats(#{label}): #{e.message}"
      []
    end

    def upsert_chat_record(chat, synced_at: Time.current)
      attrs = extract_chat_attrs(chat)
      return false if attrs.nil?

      upsert_chat_records_bulk([attrs], synced_at:) > 0
    end

    def upsert_chat_records_bulk(attrs_list, synced_at:)
      return 0 if attrs_list.empty?

      now = Time.current
      rows = attrs_list.map do |attrs|
        attrs.merge(
          telegram_account_id: @account_id,
          synced_at:,
          created_at: now,
          updated_at: now
        )
      end

      TelegramChat.upsert_all(
        rows,
        unique_by: :index_telegram_chats_on_telegram_account_id_and_td_chat_id
      )
      rows.size
    end

    def handle_unsupported_update(update)
      return unless update.respond_to?(:original_type) && update.respond_to?(:raw)

      raw = update.raw.is_a?(Hash) ? update.raw : {}
      case update.original_type
      when "updateNewChat"
        chat_raw = raw["chat"]
        upsert_chat_record(chat_raw) if chat_raw.is_a?(Hash)
      when "updateNewMessage"
        message_raw = raw["message"]
        handle_new_message(message_raw) if message_raw.is_a?(Hash)
      when "updateChatTitle"
        td_chat_id = raw["chat_id"]
        title = raw["title"]
        return if td_chat_id.blank? || title.blank?

        TelegramChat.where(telegram_account_id: @account_id, td_chat_id: td_chat_id.to_i)
          .update_all(title:, synced_at: Time.current, updated_at: Time.current)
      when "updateChatPhoto"
        td_chat_id = raw["chat_id"]
        photo = raw["photo"].is_a?(Hash) ? raw["photo"] : {}
        small = photo["small"].is_a?(Hash) ? photo["small"] : {}
        big = photo["big"].is_a?(Hash) ? photo["big"] : {}
        return if td_chat_id.blank?

        TelegramChat.where(telegram_account_id: @account_id, td_chat_id: td_chat_id.to_i).update_all(
          avatar_small_file_id: small["id"],
          avatar_big_file_id: big["id"],
          avatar_small_remote_id: small.dig("remote", "id"),
          avatar_big_remote_id: big.dig("remote", "id"),
          avatar_small_local_path: small.dig("local", "path"),
          avatar_big_local_path: big.dig("local", "path"),
          synced_at: Time.current,
          updated_at: Time.current
        )
      end
    end

    def handle_new_message(message)
      payload = extract_message_attrs(message)
      return if payload.nil?
      return unless watched_chat_ids.include?(payload[:td_chat_id])

      upsert_messages_bulk([payload])
    end

    def watched_chat_ids
      raw = TelegramAccountProfile.where(telegram_account_id: @account_id).pick(:watched_chat_ids)
      Array(raw).map(&:to_i).uniq
    end

    def extract_history_messages(response)
      return [] if response.nil?
      messages =
        if response.respond_to?(:messages)
          response.messages
        elsif defined?(TD::Types::Unsupported) && response.is_a?(TD::Types::Unsupported) && response.original_type == "messages"
          raw_messages = response.raw.is_a?(Hash) ? response.raw["messages"] : nil
          raw_messages.is_a?(Array) ? raw_messages : nil
        end
      return [] unless messages.respond_to?(:map)

      messages.map { |message| extract_message_attrs(message) }.compact
    end

  def extract_history_count(response)
      return 0 if response.nil?

      if response.respond_to?(:messages)
        messages = response.messages
        return messages.size if messages.respond_to?(:size)
      elsif defined?(TD::Types::Unsupported) && response.is_a?(TD::Types::Unsupported) && response.original_type == "messages"
        raw_messages = response.raw.is_a?(Hash) ? response.raw["messages"] : nil
        return raw_messages.size if raw_messages.is_a?(Array)
      end

      0
    end

    def describe_response(response)
      return nil if response.nil?

      if response.respond_to?(:class)
        info = { class: response.class.to_s }
        info[:original_type] = response.original_type if response.respond_to?(:original_type)
        if response.respond_to?(:messages)
          msgs = response.messages
          info[:message_count] = msgs.respond_to?(:size) ? msgs.size : nil
        elsif defined?(TD::Types::Unsupported) && response.is_a?(TD::Types::Unsupported)
          raw_msgs = response.raw.is_a?(Hash) ? response.raw["messages"] : nil
          info[:message_count] = raw_msgs.is_a?(Array) ? raw_msgs.size : nil
        end
        return info
      end

      nil
    rescue StandardError
      nil
    end

    def fetch_history_messages_page(chat_id:, from_message_id:, offset:, limit:)
      @client.get_chat_history(
        chat_id:,
        from_message_id:,
        offset:,
        limit:,
        only_local: false
      ).value!
    end

    def fetch_search_messages_page(chat_id:, from_message_id:, offset:, limit:)
      @client.search_chat_messages(
        chat_id:,
        query: "",
        sender_id: nil,
        from_message_id:,
        offset:,
        limit:,
        filter: nil,
        message_thread_id: 0,
        saved_messages_topic_id: 0
      ).value!
    end

    def extract_chat_last_message_id(chat)
      if chat.is_a?(Hash)
        return chat.dig("last_message", "id") || chat.dig(:last_message, :id)
      end

      if chat.respond_to?(:last_message)
        return chat.last_message&.id
      end

      if defined?(TD::Types::Unsupported) && chat.is_a?(TD::Types::Unsupported) && chat.original_type == "chat"
        raw = chat.raw.is_a?(Hash) ? chat.raw : {}
        return raw.dig("last_message", "id")
      end

      nil
    rescue StandardError
      nil
    end


    def upsert_messages_bulk(messages)
      return 0 if messages.empty?

      TelegramMessage.upsert_all(
        messages.map { |attrs| attrs.merge(telegram_account_id: @account_id) },
        unique_by: :index_telegram_messages_on_account_chat_message
      )
      messages.size
    end

    def extract_message_attrs(message)
      raw = message_to_hash(message)
      return nil unless raw.is_a?(Hash)

      td_message_id = raw["id"]
      td_chat_id = raw["chat_id"]
      date = raw["date"]
      return nil if td_message_id.blank? || td_chat_id.blank? || date.blank?

      sender = raw["sender_id"].is_a?(Hash) ? raw["sender_id"] : {}
      {
        td_chat_id: td_chat_id.to_i,
        td_message_id: td_message_id.to_i,
        td_sender_id: sender["user_id"] || sender["chat_id"],
        sender_name: resolve_sender_name(sender),
        message_at: Time.at(date.to_i),
        text: extract_message_text(raw)
      }
    end

    def resolve_sender_name(sender)
      type = sender["@type"].to_s
      case type
      when "messageSenderUser"
        user_id = sender["user_id"].to_i
        return nil if user_id <= 0

        cached_sender_name("u:#{user_id}") { fetch_user_name(user_id) }
      when "messageSenderChat"
        chat_id = sender["chat_id"].to_i
        return nil if chat_id.zero?

        cached_sender_name("c:#{chat_id}") { fetch_chat_name(chat_id) }
      else
        nil
      end
    rescue StandardError
      nil
    end

    def upsert_usernames_from(messages)
      rows = messages.filter_map do |m|
        uid = m[:td_sender_id].to_i
        gid = m[:td_chat_id].to_i
        name = m[:sender_name].to_s.strip
        next if uid.zero? || gid.zero?
        next if name.empty?

        {
          uid: uid,
          group_id: gid,
          name: name,
          last_seen: m[:message_at] || Time.current
        }
      end
      return if rows.empty?

      # keep the latest last_seen per (uid, group_id)
      dedup = rows.group_by { |r| [r[:uid], r[:group_id]] }.map do |_k, v|
        v.max_by { |row| row[:last_seen] }
      end

      Username.upsert_all(
        dedup,
        unique_by: :index_usernames_on_uid_and_group_id,
        update_only: %i[name last_seen]
      )
    end

    def cached_sender_name(key)
      cached = @mutex.synchronize { @sender_name_cache[key] }
      return cached if cached.present?

      value = yield
      @mutex.synchronize { @sender_name_cache[key] = value } if value.present?
      value
    end

    def fetch_user_name(user_id)
      user = @client.get_user(user_id:).wait
      payload = extract_user_payload(user)
      return nil if payload.nil?

      full_name = [payload[:first_name], payload[:last_name]].compact.join(" ").strip
      return full_name if full_name.present?

      payload[:username].presence
    rescue StandardError
      nil
    end

    def fetch_chat_name(chat_id)
      title = TelegramChat.where(telegram_account_id: @account_id, td_chat_id: chat_id).pick(:title)
      return title if title.present?

      chat = @client.get_chat(chat_id:).wait
      extract_chat_payload(chat)&.dig(:title)
    rescue StandardError
      nil
    end

    def message_to_hash(message)
      if message.is_a?(Hash)
        return message.deep_stringify_keys
      end

      if defined?(TD::Types::Unsupported) && message.is_a?(TD::Types::Unsupported)
        raw = message.raw
        return raw.deep_stringify_keys if raw.is_a?(Hash)
        return nil
      end

      if message.respond_to?(:to_h)
        raw = message.to_h
        return raw.deep_stringify_keys if raw.is_a?(Hash)
      end

      nil
    rescue StandardError
      nil
    end

    def extract_message_text(raw)
      content = raw["content"].is_a?(Hash) ? raw["content"] : {}
      type = content["@type"]

      case type
      when "messageText"
        content.dig("text", "text")
      when "messagePhoto", "messageVideo", "messageDocument", "messageAnimation", "messageVoiceNote"
        content.dig("caption", "text")
      else
        content.dig("text", "text") || content.dig("caption", "text")
      end
    end

    def extract_chat_ids(chats_result)
      return [] if chats_result.nil?
      return chats_result.chat_ids if chats_result.respond_to?(:chat_ids)

      if defined?(TD::Types::Unsupported) && chats_result.is_a?(TD::Types::Unsupported) && chats_result.original_type == "chats"
        raw_ids = chats_result.raw["chat_ids"]
        return raw_ids.is_a?(Array) ? raw_ids.map(&:to_i) : []
      end

      []
    end

    def extract_chat_attrs(chat)
      payload = extract_chat_payload(chat)
      return nil if payload.nil? || payload[:td_chat_id].nil? || payload[:title].blank?

      payload
    end

    def extract_chat_payload(chat)
      if chat.is_a?(Hash)
        photo = chat["photo"].is_a?(Hash) ? chat["photo"] : {}
        small = photo["small"].is_a?(Hash) ? photo["small"] : {}
        big = photo["big"].is_a?(Hash) ? photo["big"] : {}
        return {
          td_chat_id: chat["id"],
          title: chat["title"],
          chat_type: normalize_chat_type(chat["type"]),
          avatar_small_file_id: small["id"],
          avatar_big_file_id: big["id"],
          avatar_small_remote_id: small.dig("remote", "id"),
          avatar_big_remote_id: big.dig("remote", "id"),
          avatar_small_local_path: small.dig("local", "path"),
          avatar_big_local_path: big.dig("local", "path"),
          raw_payload: chat
        }
      end

      if chat.respond_to?(:id) && chat.respond_to?(:title)
        return {
          td_chat_id: chat.id,
          title: chat.title,
          chat_type: normalize_chat_type(chat.respond_to?(:type) ? chat.type : nil),
          avatar_small_file_id: chat.photo&.small&.id,
          avatar_big_file_id: chat.photo&.big&.id,
          avatar_small_remote_id: chat.photo&.small&.remote&.id,
          avatar_big_remote_id: chat.photo&.big&.remote&.id,
          avatar_small_local_path: chat.photo&.small&.local&.path,
          avatar_big_local_path: chat.photo&.big&.local&.path,
          raw_payload: chat_to_raw_payload(chat)
        }
      end

      if defined?(TD::Types::Unsupported) && chat.is_a?(TD::Types::Unsupported) && chat.original_type == "chat"
        raw = chat.raw || {}
        photo = raw["photo"].is_a?(Hash) ? raw["photo"] : {}
        small = photo["small"].is_a?(Hash) ? photo["small"] : {}
        big = photo["big"].is_a?(Hash) ? photo["big"] : {}
        return {
          td_chat_id: raw["id"],
          title: raw["title"],
          chat_type: normalize_chat_type(raw["type"]),
          avatar_small_file_id: small["id"],
          avatar_big_file_id: big["id"],
          avatar_small_remote_id: small.dig("remote", "id"),
          avatar_big_remote_id: big.dig("remote", "id"),
          avatar_small_local_path: small.dig("local", "path"),
          avatar_big_local_path: big.dig("local", "path"),
          raw_payload: raw
        }
      end

      nil
    end

    def normalize_chat_type(type)
      return nil if type.nil?
      return type.original_type if defined?(TD::Types::Unsupported) && type.is_a?(TD::Types::Unsupported)
      return type.to_h["@type"] if type.respond_to?(:to_h)

      type.to_s
    rescue StandardError
      nil
    end

    def chat_to_raw_payload(chat)
      return chat.to_h if chat.respond_to?(:to_h)

      {}
    rescue StandardError
      {}
    end

    def extract_user_payload(user)
      return nil if user.nil?

      if user.respond_to?(:id) && user.respond_to?(:first_name)
        return {
          id: user.id,
          first_name: user.first_name,
          last_name: user.last_name,
          username: user.respond_to?(:usernames) ? user.usernames&.editable_username : nil,
          phone_number: user.phone_number
        }
      end

      if defined?(TD::Types::Unsupported) && user.is_a?(TD::Types::Unsupported) && user.original_type == "user"
        raw = user.raw || {}
        usernames = raw["usernames"].is_a?(Hash) ? raw["usernames"] : {}
        return {
          id: raw["id"],
          first_name: raw["first_name"],
          last_name: raw["last_name"],
          username: usernames["editable_username"],
          phone_number: raw["phone_number"]
        }
      end

      nil
    end

    def persist_profile(user, basic_payload)
      profile = TelegramAccountProfile.find_or_initialize_by(telegram_account_id: @account_id)
      profile.assign_attributes(
        td_user_id: basic_payload[:id],
        first_name: basic_payload[:first_name],
        last_name: basic_payload[:last_name],
        username: basic_payload[:username],
        phone_number: basic_payload[:phone_number]
      )

      enrich_profile_from_user_object(profile, user)
      profile.raw_payload = user_to_raw_payload(user)
      profile.save!
    end

    def enrich_profile_from_user_object(profile, user)
      return unless user.respond_to?(:language_code)

      profile.language_code = user.language_code
      profile.is_verified = user.is_verified if user.respond_to?(:is_verified)
      profile.is_premium = user.is_premium if user.respond_to?(:is_premium)
      profile.is_support = user.is_support if user.respond_to?(:is_support)
      profile.is_scam = user.is_scam if user.respond_to?(:is_scam)
      profile.is_fake = user.is_fake if user.respond_to?(:is_fake)
    end

    def user_to_raw_payload(user)
      return {} if user.nil?

      if defined?(TD::Types::Unsupported) && user.is_a?(TD::Types::Unsupported)
        return user.raw.is_a?(Hash) ? user.raw : {}
      end

      return user.to_h if user.respond_to?(:to_h)

      {}
    rescue StandardError
      {}
    end
  end
end
