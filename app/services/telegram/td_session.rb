# frozen_string_literal: true

require "rack/mime"

module Telegram
  class TdSession
    class InvalidStateError < StandardError; end
    WATCHED_CHAT_IDS_CACHE_TTL_SECONDS = [ENV.fetch("TELEGRAM_WATCHED_CHAT_IDS_CACHE_TTL_SECONDS", "5").to_f, 0.5].max

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
      @watched_chat_ids_cache = {}
      @watched_chat_ids_cache_loaded_at = 0.0
      @boot_recovery_sync_enqueued = false
      @watched_chat_sync_running = false

      @client = TD::Client.new(**client_config(account))
      subscribe_updates
      @client.connect
    end

    def invalidate_watched_chat_ids_cache!
      @mutex.synchronize do
        @watched_chat_ids_cache = {}
        @watched_chat_ids_cache_loaded_at = 0.0
      end
    end

    def boot_recovery_sync_async!
      should_enqueue = @mutex.synchronize do
        next false if @boot_recovery_sync_enqueued

        @boot_recovery_sync_enqueued = true
      end
      return unless should_enqueue

      sync_messages_for_watched_chats_async(reason: "boot")
    end

    def sync_messages_for_watched_chats_async(reason: "manual")
      should_start = @mutex.synchronize do
        next false if @watched_chat_sync_running

        @watched_chat_sync_running = true
      end
      return unless should_start

      Thread.new do
        begin
          state = wait_for_initial_state(timeout: 5)
          wait_until_ready!(timeout: 30) if state == :initializing

          current_state = snapshot[:state]
          unless current_state == :ready
            Rails.logger.info("Skip watched chat sync(#{reason}) for account #{@id}: state=#{current_state}")
            next
          end

          chat_ids = watched_chat_ids
          if chat_ids.empty?
            Rails.logger.info("Skip watched chat sync(#{reason}) for account #{@id}: no watched chats")
            next
          end

          sync = sync_messages_for_chats(chat_ids:)
          Rails.logger.info("Watched chat sync(#{reason}) for account #{@id}: #{sync.inspect}")
        rescue StandardError => e
          Rails.logger.warn("Failed watched chat sync(#{reason}) for account #{@id}: #{e.message}")
        ensure
          @mutex.synchronize { @watched_chat_sync_running = false }
        end
      end
    end

    def submit_phone(phone_number:)
      raise_if_disposed!
      ensure_state!(:wait_phone_number)
      @client.set_authentication_phone_number(phone_number:, settings: nil).value!
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
      @client.check_authentication_code(code:).value!
      snapshot
    rescue StandardError => e
      capture_error(e)
      raise
    end

    def submit_password(password:)
      raise_if_disposed!
      ensure_state!(:wait_password)
      @client.check_authentication_password(password:).value!
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
      state = nil
      loop do
        state = @mutex.synchronize { @state }
        return if state == :ready
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(0.1)
      end

      # Some tdjson/schema combinations can deliver authorization state as Unsupported.
      # If API calls already work, treat session as ready and self-heal cached state.
      if probe_ready_state!
        apply_auth_state(:ready)
        return
      end

      raise InvalidStateError, "Session state is #{state}"
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
        existing_max_message_id = TelegramMessage.where(
          telegram_account_id: @account_id,
          td_chat_id: chat_id
        ).maximum(:td_message_id).to_i
        chat_title = nil
        last_message_id = nil
        precheck_error = nil
        first_response_info = nil

        begin
          chat = @client.get_chat(chat_id:).value!
          payload = extract_chat_payload(chat)
          chat_title = payload&.dig(:title)
          last_message_id = extract_chat_last_message_id(chat)
          @client.open_chat(chat_id:).value!
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

          message_bundles = extract_history_messages(response)
          message_bundles = message_bundles.sort_by { |bundle| -bundle[:message][:td_message_id].to_i }
          chat_parsed += message_bundles.size
          break if message_bundles.empty?

          message_bundles = message_bundles.reject do |bundle|
            message_id = bundle[:message][:td_message_id].to_i
            duplicate = seen_message_ids.key?(message_id)
            seen_message_ids[message_id] = true
            duplicate
          end

          reached_existing_boundary = existing_max_message_id.positive? &&
            message_bundles.any? { |bundle| bundle[:message][:td_message_id].to_i <= existing_max_message_id }
          message_bundles = message_bundles.select do |bundle|
            existing_max_message_id <= 0 || bundle[:message][:td_message_id].to_i > existing_max_message_id
          end
          break if message_bundles.empty?

          if per_chat_limit
            remaining = per_chat_limit - chat_upserted
            break if remaining <= 0

            message_bundles = message_bundles.first(remaining)
          end

          upsert_usernames_from(message_bundles)
          upserted = upsert_messages_bulk(message_bundles.map { |bundle| bundle[:message] })
          result[:upserted] += upserted
          chat_upserted += upserted

          oldest_message_id = message_bundles.map { |bundle| bundle[:message][:td_message_id].to_i }.min.to_i
          break if oldest_message_id <= 0
          break if reached_existing_boundary

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
          existing_max_message_id: existing_max_message_id.positive? ? existing_max_message_id : nil,
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

    def refresh_chat(chat_id:, refresh_avatar: true)
      raise_if_disposed!
      wait_until_ready!

      existing_chat = TelegramChat.find_by(telegram_account_id: @account_id, td_chat_id: chat_id.to_i)
      chat = @client.get_chat(chat_id: chat_id).value!
      upsert_chat_record(chat, include_avatar_blob: refresh_avatar, existing_record: existing_chat)
    end

    def sync_group_members_for_chats(chat_ids:, refresh_avatars: true)
      raise_if_disposed!
      wait_until_ready!

      ids = Array(chat_ids).map(&:to_i).uniq
      return { chats: 0, upserted: 0, failed: 0, errors: [], details: [] } if ids.empty?

      result = { chats: ids.size, upserted: 0, failed: 0, errors: [], details: [] }

      ids.each do |chat_id|
        detail = sync_group_members_for_chat(chat_id, refresh_avatars:)
        result[:upserted] += detail[:upserted]
        result[:details] << detail
      rescue StandardError => e
        result[:failed] += 1
        result[:errors] << "chat #{chat_id}: #{e.message}"
        result[:details] << { chat_id:, error: e.message, upserted: 0 }
      end

      result
    end

    private

    def subscribe_updates
      @client.on(TD::Types::Update::AuthorizationState) do |update|
        state = map_auth_state(update.authorization_state)
        apply_auth_state(state)
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

    def map_auth_state_from_raw(auth_state_raw)
      return nil unless auth_state_raw.is_a?(Hash)

      type = auth_state_raw["@type"].to_s
      case type
      when "authorizationStateWaitPhoneNumber" then :wait_phone_number
      when "authorizationStateWaitCode" then :wait_code
      when "authorizationStateWaitPassword" then :wait_password
      when "authorizationStateReady" then :ready
      when "authorizationStateClosed" then :closed
      else
        nil
      end
    end

    def apply_auth_state(state)
      return if state.nil?

      @mutex.synchronize { @state = state }
      persist_account(
        state: state.to_s,
        last_state_at: Time.current,
        connected_at: (state == :ready ? Time.current : nil),
        last_error: nil
      )
      fetch_me if state == :ready
    end

    def probe_ready_state!
      @client.get_me.value!
      true
    rescue StandardError
      false
    end

    def fetch_me
      @client.get_me.then { |user| @mutex.synchronize { @me = user } }
        .rescue { |err| @mutex.synchronize { @last_error = err.to_s } }
        .value!
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
          offline = @client.search_chats(query: "", limit: [limit, 100].min).value!
          offline_ids = extract_chat_ids(offline)
          result[:from_search_chats] = offline_ids.size
          chat_ids |= offline_ids
        rescue StandardError => e
          result[:errors] << "search_chats: #{e.message}"
        end

        begin
          server = @client.search_chats_on_server(query: "", limit: [limit, 100].min).value!
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
        chat = @client.get_chat(chat_id: chat_id).value!
        existing_chat = TelegramChat.find_by(telegram_account_id: @account_id, td_chat_id: chat_id.to_i)
        attrs = extract_chat_attrs(chat, existing_record: existing_chat)
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
          @client.load_chats(chat_list:, limit:).value!
        rescue StandardError => e
          # 404 here usually means all chats already loaded; keep going.
          result[:errors] << "load_chats(#{label}): #{e.message}"
        end

        chats = @client.get_chats(chat_list:, limit:).value!
        ids = extract_chat_ids(chats)
        break if ids.any?

        sleep(0.25)
      end
      ids
    rescue StandardError => e
      result[:errors] << "get_chats(#{label}): #{e.message}"
      []
    end

    def upsert_chat_record(chat, synced_at: Time.current, include_avatar_blob: false, existing_record: nil)
      attrs = extract_chat_attrs(chat, include_avatar_blob:, existing_record:)
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
      when "updateAuthorizationState"
        state = map_auth_state_from_raw(raw["authorization_state"])
        apply_auth_state(state)
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
        return if td_chat_id.blank?

        existing_chat = TelegramChat.find_by(telegram_account_id: @account_id, td_chat_id: td_chat_id.to_i)
        attrs = extract_chat_photo_attrs(raw["photo"], existing_record: existing_chat)
        TelegramChat.where(telegram_account_id: @account_id, td_chat_id: td_chat_id.to_i)
          .update_all(attrs.merge(synced_at: Time.current, updated_at: Time.current))
      end
    end

    def handle_new_message(message)
      bundle = extract_message_bundle(message)
      return if bundle.nil?

      payload = bundle[:message]
      return unless watched_chat_id?(payload[:td_chat_id])

      upsert_usernames_from([bundle])
      upsert_messages_bulk([payload])
    end

    def watched_chat_ids
      watched_chat_ids_lookup.keys
    end

    def watched_chat_id?(chat_id)
      watched_chat_ids_lookup.key?(chat_id.to_i)
    end

    def watched_chat_ids_lookup
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = @mutex.synchronize do
        if @watched_chat_ids_cache_loaded_at.positive? &&
           (now - @watched_chat_ids_cache_loaded_at) < WATCHED_CHAT_IDS_CACHE_TTL_SECONDS
          @watched_chat_ids_cache
        end
      end
      return cached unless cached.nil?

      ids = TelegramAccountWatchTarget.where(telegram_account_id: @account_id).pluck(:td_chat_id).map(&:to_i).uniq
      lookup = ids.each_with_object({}) { |id, memo| memo[id] = true }

      @mutex.synchronize do
        @watched_chat_ids_cache = lookup
        @watched_chat_ids_cache_loaded_at = now
      end
      lookup
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

      messages.map { |message| extract_message_bundle(message) }.compact
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

    def extract_message_bundle(message)
      raw = message_to_hash(message)
      return nil unless raw.is_a?(Hash)

      td_message_id = raw["id"]
      td_chat_id = raw["chat_id"]
      date = raw["date"]
      return nil if td_message_id.blank? || td_chat_id.blank? || date.blank?

      sender = raw["sender_id"].is_a?(Hash) ? raw["sender_id"] : {}
      sender_is_user = sender["@type"].to_s == "messageSenderUser"
      message_attrs = {
        td_chat_id: td_chat_id.to_i,
        td_message_id: td_message_id.to_i,
        td_sender_id: sender["user_id"] || sender["chat_id"],
        sender_name: resolve_sender_name(sender),
        message_at: Time.at(date.to_i),
        text: extract_message_text(raw)
      }

      {
        message: message_attrs,
        username: build_username_attrs(message_attrs, sender_is_user:)
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

    def upsert_usernames_from(message_bundles)
      rows = message_bundles.filter_map { |bundle| bundle[:username] }
      return if rows.empty?

      # keep the latest last_seen per (uid, group_id)
      dedup = rows.group_by { |r| [r[:uid], r[:group_id]] }.map do |_k, v|
        v.max_by { |row| row[:last_seen] }
      end

      TelegramChatUsername.upsert_all(
        dedup,
        unique_by: :index_telegram_chat_usernames_on_uid_and_group_id,
        update_only: %i[name last_seen]
      )
    end

    def build_username_attrs(message_attrs, sender_is_user:)
      return nil unless sender_is_user

      uid = message_attrs[:td_sender_id].to_i
      gid = message_attrs[:td_chat_id].to_i
      name = message_attrs[:sender_name].to_s.strip
      return nil if uid.zero? || gid.zero? || name.empty?

      {
        uid: uid,
        group_id: gid,
        username: nil,
        avatar_small_file_id: nil,
        avatar_small_data: nil,
        avatar_small_content_type: nil,
        avatar_small_fetched_at: nil,
        name: name,
        last_seen: message_attrs[:message_at] || Time.current
      }
    end

    def cached_sender_name(key)
      cached = @mutex.synchronize { @sender_name_cache[key] }
      return cached if cached.present?

      value = yield
      @mutex.synchronize { @sender_name_cache[key] = value } if value.present?
      value
    end

    def fetch_user_name(user_id)
      user = @client.get_user(user_id:).value!
      payload = extract_user_payload(user)
      return nil if payload.nil?

      build_display_name(payload)
    rescue StandardError
      nil
    end

    def fetch_chat_name(chat_id)
      title = TelegramChat.where(telegram_account_id: @account_id, td_chat_id: chat_id).pick(:title)
      return title if title.present?

      chat = @client.get_chat(chat_id:).value!
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

    def sync_group_members_for_chat(chat_id, refresh_avatars: true)
      existing_chat = TelegramChat.find_by(telegram_account_id: @account_id, td_chat_id: chat_id.to_i)
      chat = fetch_chat_for_group_sync(chat_id)
      payload = build_group_sync_chat_payload(chat, existing_chat:, chat_id:, refresh_avatars:)
      source_chat = chat || chat_source_from_record(existing_chat, chat_id) || build_minimal_chat_source(chat_id, payload&.dig(:chat_type))
      source_chat = resolve_td_value(source_chat)
      raise "Chat #{chat_id} not found" if payload.nil? || source_chat.nil?

      existing_members = TelegramChatUsername.where(group_id: chat_id).index_by(&:uid)
      member_resolution_error = nil
      users =
        begin
          users_for_group_chat(source_chat)
        rescue StandardError => e
          member_resolution_error = "#{e.class}: #{e.message}"
          Rails.logger.warn(
            "Failed resolving group members for chat #{chat_id} on account #{@id}: #{member_resolution_error}; "\
            "source=#{describe_group_source_chat(source_chat)}; #{td_stack_versions}"
          )
          []
        end

      Rails.logger.warn("No group members resolved for chat #{chat_id} on account #{@id}") if users.empty?
      rows = users.filter_map do |user|
        user_payload = extract_user_payload(user)
        uid = user_payload&.dig(:id).to_i
        build_username_row(
          user_payload:,
          user:,
          group_id: chat_id,
          existing_member: uid.positive? ? existing_members[uid] : nil,
          refresh_avatar: refresh_avatars
        )
      end

      if rows.empty?
        fallback_rows = fallback_group_member_rows_from_messages(chat_id:, existing_members:)
        if fallback_rows.present?
          rows = fallback_rows
          Rails.logger.warn(
            "Using message-based member fallback for chat #{chat_id} on account #{@id}: #{rows.size} rows"
          )
        end
      end

      if users.present? && rows.empty?
        sample_class = users.first.class.to_s
        sample_raw =
          if defined?(TD::Types::Unsupported) && users.first.is_a?(TD::Types::Unsupported)
            users.first.raw
          elsif users.first.respond_to?(:to_h)
            users.first.to_h
          else
            users.first
          end
        Rails.logger.warn(
          "Group member rows empty for chat #{chat_id} account #{@id}. "\
          "users_found=#{users.size} sample_class=#{sample_class} sample=#{sample_raw.inspect}"
        )
      end

      upsert_group_member_rows(rows)
      upsert_chat_record(chat, include_avatar_blob: refresh_avatars, existing_record: existing_chat) if chat

      {
        chat_id:,
        title: payload[:title],
        chat_type: payload[:chat_type],
        users_found: users.size,
        upserted: rows.size,
        member_resolution_error:
      }
    end

    def fetch_chat_for_group_sync(chat_id)
      @client.get_chat(chat_id:).value!
    rescue StandardError => e
      Rails.logger.warn("get_chat failed for group sync chat #{chat_id} on account #{@id}: #{e.message}")
      nil
    end

    def build_group_sync_chat_payload(chat, existing_chat:, chat_id:, refresh_avatars:)
      if chat
        payload = extract_chat_payload(chat, include_avatar_blob: refresh_avatars, existing_record: existing_chat)
        return payload if payload.present?
      end

      if existing_chat
        return {
          td_chat_id: existing_chat.td_chat_id,
          title: existing_chat.title,
          chat_type: existing_chat.chat_type,
          raw_payload: existing_chat.raw_payload
        }
      end

      fallback_chat = TelegramChat.where(td_chat_id: chat_id.to_i).order(updated_at: :desc).first
      if fallback_chat
        return {
          td_chat_id: fallback_chat.td_chat_id,
          title: fallback_chat.title,
          chat_type: fallback_chat.chat_type,
          raw_payload: fallback_chat.raw_payload
        }
      end

      inferred_type = infer_chat_type_from_chat_id(chat_id)
      return nil if inferred_type.blank?

      {
        td_chat_id: chat_id.to_i,
        title: "Chat #{chat_id}",
        chat_type: inferred_type,
        raw_payload: build_minimal_chat_source(chat_id, inferred_type)
      }
    end

    def chat_source_from_record(existing_chat, chat_id)
      return build_minimal_chat_source(chat_id) if existing_chat.nil?

      raw = existing_chat.raw_payload.is_a?(Hash) ? existing_chat.raw_payload.deep_dup : {}
      raw["id"] ||= existing_chat.td_chat_id || chat_id.to_i
      if raw["type"].blank? && existing_chat.chat_type.present?
        raw["type"] = { "@type" => existing_chat.chat_type }
      end
      raw
    rescue StandardError
      build_minimal_chat_source(chat_id)
    end

    def infer_chat_type_from_chat_id(chat_id)
      return "chatTypeSupergroup" if supergroup_id_from_chat_id(chat_id).present?
      return "chatTypeBasicGroup" if basic_group_id_from_chat_id(chat_id).present?

      nil
    end

    def build_minimal_chat_source(chat_id, chat_type = nil)
      cid = chat_id.to_i
      type_name = chat_type.presence || infer_chat_type_from_chat_id(cid)
      return nil if type_name.blank?

      type = { "@type" => type_name }
      if type_name == "chatTypeSupergroup"
        supergroup_id = supergroup_id_from_chat_id(cid)
        type["supergroup_id"] = supergroup_id if supergroup_id.present?
      elsif type_name == "chatTypeBasicGroup"
        basic_group_id = basic_group_id_from_chat_id(cid)
        type["basic_group_id"] = basic_group_id if basic_group_id.present?
      end

      { "id" => cid, "type" => type }
    rescue StandardError
      nil
    end

    def users_for_group_chat(chat)
      chat = resolve_td_value(chat)
      kind, group_id = extract_group_target(chat)
      raise "Chat #{chat_id_from(chat)} is not a group" if kind.nil? || group_id.to_i <= 0

      case kind
      when :supergroup then supergroup_members(group_id.to_i)
      when :basic_group then basic_group_members(group_id.to_i)
      else
        raise "Chat #{chat_id_from(chat)} has unsupported group type #{kind.inspect}"
      end
    end

    def extract_group_target(chat)
      chat_id = chat_id_from(chat).to_i

      if chat.respond_to?(:type)
        chat_type = chat.type
        return [:supergroup, chat_type.supergroup_id] if defined?(TD::Types::ChatType::Supergroup) && chat_type.is_a?(TD::Types::ChatType::Supergroup)
        return [:basic_group, chat_type.basic_group_id] if defined?(TD::Types::ChatType::BasicGroup) && chat_type.is_a?(TD::Types::ChatType::BasicGroup)
      end

      raw =
        if chat.is_a?(Hash)
          chat
        elsif defined?(TD::Types::Unsupported) && chat.is_a?(TD::Types::Unsupported)
          chat.raw.is_a?(Hash) ? chat.raw : {}
        elsif chat.respond_to?(:to_h)
          parsed = chat.to_h
          parsed.is_a?(Hash) ? parsed : {}
        else
          {}
        end

      type = raw["type"] || raw[:type]
      if type.is_a?(Hash)
        type_name = (type["@type"] || type[:@type] || type["type"] || type[:type]).to_s
        case type_name
        when "chatTypeSupergroup"
          group_id = type["supergroup_id"] || type[:supergroup_id]
          group_id ||= supergroup_id_from_chat_id(chat_id)
          return [:supergroup, group_id]
        when "chatTypeBasicGroup"
          group_id = type["basic_group_id"] || type[:basic_group_id]
          group_id ||= basic_group_id_from_chat_id(chat_id)
          return [:basic_group, group_id]
        end
      elsif type.respond_to?(:to_h)
        parsed = type.to_h
        type_name = parsed["@type"].to_s
        case type_name
        when "chatTypeSupergroup"
          group_id = parsed["supergroup_id"] || supergroup_id_from_chat_id(chat_id)
          return [:supergroup, group_id]
        when "chatTypeBasicGroup"
          group_id = parsed["basic_group_id"] || basic_group_id_from_chat_id(chat_id)
          return [:basic_group, group_id]
        end
      elsif type.is_a?(String)
        case type
        when "chatTypeSupergroup"
          group_id = supergroup_id_from_chat_id(chat_id)
          return [:supergroup, group_id]
        when "chatTypeBasicGroup"
          group_id = basic_group_id_from_chat_id(chat_id)
          return [:basic_group, group_id]
        end
      end

      [nil, nil]
    rescue StandardError
      [nil, nil]
    end

    def chat_id_from(chat)
      return chat["id"] || chat[:id] if chat.is_a?(Hash)
      return chat.id if chat.respond_to?(:id)
      return chat.raw["id"] if defined?(TD::Types::Unsupported) && chat.is_a?(TD::Types::Unsupported) && chat.raw.is_a?(Hash)

      nil
    rescue StandardError
      nil
    end

    def supergroup_id_from_chat_id(chat_id)
      cid = chat_id.to_i
      return nil if cid >= 0
      return nil if cid > -1_000_000_000_000

      (-1_000_000_000_000 - cid).to_i
    rescue StandardError
      nil
    end

    def basic_group_id_from_chat_id(chat_id)
      cid = chat_id.to_i
      return nil if cid >= 0
      return nil if cid <= -1_000_000_000_000

      -cid
    rescue StandardError
      nil
    end

    def fallback_group_member_rows_from_messages(chat_id:, existing_members:)
      latest = {}
      TelegramMessage.where(telegram_account_id: @account_id, td_chat_id: chat_id.to_i)
                     .where("td_sender_id > 0")
                     .order(message_at: :desc)
                     .limit(2_000)
                     .pluck(:td_sender_id, :sender_name, :message_at)
                     .each do |uid, sender_name, message_at|
        uid_i = uid.to_i
        next if uid_i <= 0 || latest.key?(uid_i)

        existing = existing_members[uid_i]
        name = sender_name.to_s.strip
        name = existing&.name.to_s.strip if name.blank?
        if name.blank?
          name = cached_sender_name("u:#{uid_i}") { fetch_user_name(uid_i) }.to_s.strip
        end
        name = "User #{uid_i}" if name.blank?

        latest[uid_i] = {
          uid: uid_i,
          group_id: chat_id.to_i,
          name: name,
          username: existing&.username,
          last_seen: message_at || Time.current,
          avatar_small_file_id: existing&.avatar_small_file_id,
          avatar_small_data: existing&.avatar_small_data,
          avatar_small_content_type: existing&.avatar_small_content_type,
          avatar_small_fetched_at: existing&.avatar_small_fetched_at
        }
      end

      latest.values
    end

    def supergroup_members(supergroup_id)
      offset = 0
      limit = 200
      members = []

      loop do
        response = @client.get_supergroup_members(
          supergroup_id:,
          filter: TD::Types::SupergroupMembersFilter::Recent.new,
          offset:,
          limit:
        ).value!
        chunk =
          if response.respond_to?(:members)
            Array(response.members)
          elsif defined?(TD::Types::Unsupported) && response.is_a?(TD::Types::Unsupported)
            raw_members = response.raw.is_a?(Hash) ? response.raw["members"] : nil
            Array(raw_members)
          else
            []
          end
        break if chunk.empty?

        members.concat(chunk)
        offset += chunk.size
        break if chunk.size < limit
      end

      user_ids = members.filter_map { |member| extract_member_user_id(member) }.uniq

      user_ids.filter_map { |user_id| fetch_user_with_avatar(user_id) }
    end

    def basic_group_members(basic_group_id)
      full_info = @client.get_basic_group_full_info(basic_group_id:).value!
      members =
        if full_info.respond_to?(:members)
          Array(full_info.members)
        elsif defined?(TD::Types::Unsupported) && full_info.is_a?(TD::Types::Unsupported)
          raw_members = full_info.raw.is_a?(Hash) ? full_info.raw["members"] : nil
          Array(raw_members)
        else
          []
        end
      user_ids = members.filter_map { |member| extract_member_user_id(member) }.uniq

      user_ids.filter_map { |user_id| fetch_user_with_avatar(user_id) }
    end

    def fetch_user_with_avatar(user_id)
      @client.get_user(user_id:).value!
    rescue StandardError
      nil
    end

    def extract_member_user_id(member)
      member_id =
        if member.is_a?(Hash)
          member["member_id"] || member[:member_id] || member["memberId"] || member[:memberId]
        elsif defined?(TD::Types::Unsupported) && member.is_a?(TD::Types::Unsupported)
          raw = member.raw.is_a?(Hash) ? member.raw : {}
          raw["member_id"] || raw[:member_id] || raw["memberId"] || raw[:memberId]
        elsif member.respond_to?(:member_id)
          member.member_id
        end

      extract_user_id_from_sender(member_id)
    rescue StandardError
      nil
    end

    def extract_user_id_from_sender(sender)
      return nil if sender.nil?

      if sender.is_a?(Hash)
        type = sender["@type"] || sender[:@type] || sender["type"] || sender[:type]
        return sender["user_id"] || sender[:user_id] if type.to_s == "messageSenderUser"
        return sender["userId"] || sender[:userId] if sender.key?("userId") || sender.key?(:userId)
        return sender["user_id"] || sender[:user_id]
      end

      if defined?(TD::Types::Unsupported) && sender.is_a?(TD::Types::Unsupported)
        raw = sender.raw.is_a?(Hash) ? sender.raw : {}
        return extract_user_id_from_sender(raw)
      end

      if sender.respond_to?(:user_id)
        return sender.user_id
      end

      class_name = sender.class.name.to_s
      return sender.id if class_name.end_with?("MessageSender::User") && sender.respond_to?(:id)

      nil
    rescue StandardError
      nil
    end

    def build_username_row(user_payload:, user:, group_id:, existing_member: nil, refresh_avatar: true)
      return nil if user_payload.nil?

      name = build_display_name(user_payload)
      return nil if name.blank?

      {
        uid: user_payload[:id].to_i,
        group_id: group_id.to_i,
        name:,
        username: user_payload[:username],
        last_seen: Time.current
      }.merge(extract_user_avatar_attrs(user, existing_member:, refresh_avatar:))
    end

    def upsert_group_member_rows(rows)
      return 0 if rows.empty?

      TelegramChatUsername.upsert_all(
        rows,
        unique_by: :index_telegram_chat_usernames_on_uid_and_group_id,
        update_only: %i[name username last_seen avatar_small_file_id avatar_small_data avatar_small_content_type avatar_small_fetched_at]
      )
      rows.size
    end

    def extract_chat_attrs(chat, include_avatar_blob: false, existing_record: nil)
      payload = extract_chat_payload(chat, include_avatar_blob:, existing_record:)
      return nil if payload.nil? || payload[:td_chat_id].nil? || payload[:title].blank?

      payload
    end

    def extract_chat_payload(chat, include_avatar_blob: false, existing_record: nil)
      if chat.is_a?(Hash)
        return {
          td_chat_id: chat["id"],
          title: chat["title"],
          chat_type: normalize_chat_type(chat["type"]),
          raw_payload: chat
        }.merge(extract_chat_photo_attrs(chat["photo"], include_blob: include_avatar_blob, existing_record:))
      end

      if chat.respond_to?(:id) && chat.respond_to?(:title)
        return {
          td_chat_id: chat.id,
          title: chat.title,
          chat_type: normalize_chat_type(chat.respond_to?(:type) ? chat.type : nil),
          raw_payload: chat_to_raw_payload(chat)
        }.merge(extract_chat_photo_attrs(chat.respond_to?(:photo) ? chat.photo : nil, include_blob: include_avatar_blob, existing_record:))
      end

      if defined?(TD::Types::Unsupported) && chat.is_a?(TD::Types::Unsupported) && chat.original_type == "chat"
        raw = chat.raw || {}
        return {
          td_chat_id: raw["id"],
          title: raw["title"],
          chat_type: normalize_chat_type(raw["type"]),
          raw_payload: raw
        }.merge(extract_chat_photo_attrs(raw["photo"], include_blob: include_avatar_blob, existing_record:))
      end

      nil
    end

    def extract_chat_photo_attrs(photo, include_blob: false, existing_record: nil)
      small = extract_photo_file(photo, :small)
      big = extract_photo_file(photo, :big)
      small_file_id = file_id_from(small)
      big_file_id = file_id_from(big)

      attrs = {
        avatar_small_file_id: small_file_id,
        avatar_big_file_id: big_file_id
      }

      if include_blob
        attrs.merge!(prefix_avatar_blob_attrs("avatar_small", small, existing_record:, existing_file_id: small_file_id))
      elsif existing_record&.avatar_small_file_id == small_file_id && existing_record.avatar_small_data.present?
        attrs.merge!(
          avatar_small_data: existing_record.avatar_small_data,
          avatar_small_content_type: existing_record.avatar_small_content_type,
          avatar_small_fetched_at: existing_record.avatar_small_fetched_at
        )
      else
        attrs.merge!(avatar_small_data: nil, avatar_small_content_type: nil, avatar_small_fetched_at: nil)
      end

      attrs
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

      if user.is_a?(Hash)
        usernames = user["usernames"].is_a?(Hash) ? user["usernames"] : {}
        username = usernames["editable_username"]
        username ||= Array(usernames["active_usernames"]).first
        return {
          id: user["id"] || user[:id],
          first_name: user["first_name"] || user[:first_name],
          last_name: user["last_name"] || user[:last_name],
          username:,
          phone_number: user["phone_number"] || user[:phone_number],
          profile_photo_id: user.dig("profile_photo", "id") || user.dig(:profile_photo, :id)
        }
      end

      if user.respond_to?(:id) && user.respond_to?(:first_name)
        return {
          id: user.id,
          first_name: user.first_name,
          last_name: user.last_name,
          username: user.respond_to?(:usernames) ? user.usernames&.editable_username : nil,
          phone_number: user.phone_number,
          profile_photo_id: user.profile_photo&.id
        }
      end

      if defined?(TD::Types::Unsupported) && user.is_a?(TD::Types::Unsupported) && user.original_type == "user"
        raw = user.raw || {}
        usernames = raw["usernames"].is_a?(Hash) ? raw["usernames"] : {}
        username = usernames["editable_username"]
        username ||= Array(usernames["active_usernames"]).first
        return {
          id: raw["id"],
          first_name: raw["first_name"],
          last_name: raw["last_name"],
          username:,
          phone_number: raw["phone_number"],
          profile_photo_id: raw.dig("profile_photo", "id")
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

    def extract_user_avatar_attrs(user, existing_member: nil, refresh_avatar: true)
      photo =
        if user.respond_to?(:profile_photo)
          user.profile_photo
        elsif defined?(TD::Types::Unsupported) && user.is_a?(TD::Types::Unsupported) && user.original_type == "user"
          raw = user.raw.is_a?(Hash) ? user.raw : {}
          raw["profile_photo"]
        end

      small = extract_photo_file(photo, :small)
      small_file_id = file_id_from(small)
      attrs = { avatar_small_file_id: small_file_id }

      if refresh_avatar
        attrs.merge!(prefix_avatar_blob_attrs("avatar_small", small, existing_record: existing_member, existing_file_id: small_file_id))
      elsif existing_member&.avatar_small_file_id == small_file_id && existing_member.avatar_small_data.present?
        attrs.merge!(
          avatar_small_data: existing_member.avatar_small_data,
          avatar_small_content_type: existing_member.avatar_small_content_type,
          avatar_small_fetched_at: existing_member.avatar_small_fetched_at
        )
      else
        attrs.merge!(avatar_small_data: nil, avatar_small_content_type: nil, avatar_small_fetched_at: nil)
      end

      attrs
    end

    def prefix_avatar_blob_attrs(prefix, file, existing_record: nil, existing_file_id: nil)
      if existing_record&.respond_to?("#{prefix}_data") &&
         existing_record.public_send("#{prefix}_data").present? &&
         existing_record.public_send("#{prefix}_file_id") == existing_file_id
        return {
          "#{prefix}_data": existing_record.public_send("#{prefix}_data"),
          "#{prefix}_content_type": existing_record.public_send("#{prefix}_content_type"),
          "#{prefix}_fetched_at": existing_record.public_send("#{prefix}_fetched_at")
        }
      end

      blob = read_downloaded_file_blob(file)
      return {
        "#{prefix}_data": nil,
        "#{prefix}_content_type": nil,
        "#{prefix}_fetched_at": nil
      } if blob.nil?

      {
        "#{prefix}_data": blob[:data],
        "#{prefix}_content_type": blob[:content_type],
        "#{prefix}_fetched_at": Time.current
      }
    end

    def read_downloaded_file_blob(file)
      file_id = file_id_from(file).to_i
      return nil if file_id <= 0

      file_obj = ensure_file_downloaded(file)
      path = local_path_from(file_obj)
      return nil if path.blank? || !File.exist?(path)

      {
        data: File.binread(path),
        content_type: Rack::Mime.mime_type(File.extname(path), "application/octet-stream")
      }
    rescue StandardError
      nil
    end

    def ensure_file_downloaded(file)
      file_id = file_id_from(file).to_i
      file_obj = file.respond_to?(:local) ? file : @client.get_file(file_id:).value!
      local = file_obj.respond_to?(:local) ? file_obj.local : nil
      return file_obj if local&.is_downloading_completed && local.path.present?

      @client.download_file(
        file_id:,
        priority: 1,
        offset: 0,
        limit: 0,
        synchronous: true
      ).value!
    end

    def resolve_td_value(value)
      return value unless value.respond_to?(:value!) && value.respond_to?(:wait)

      value.value!
    end

    def describe_group_source_chat(chat)
      {
        class: chat.class.to_s,
        chat_id: chat_id_from(chat),
        target: extract_group_target(chat)
      }
    rescue StandardError
      { class: chat.class.to_s }
    end

    def td_stack_versions
      ruby_version = Gem.loaded_specs["tdlib-ruby"]&.version&.to_s || "unknown"
      schema_version = Gem.loaded_specs["tdlib-schema"]&.version&.to_s || "unknown"
      "tdlib-ruby=#{ruby_version} tdlib-schema=#{schema_version}"
    end

    def extract_photo_file(photo, size)
      if photo.is_a?(Hash)
        value = photo[size.to_s] || photo[size]
        return value if value.is_a?(Hash)
      end

      return photo.public_send(size) if photo.respond_to?(size)

      nil
    rescue StandardError
      nil
    end

    def file_id_from(file)
      return file["id"] if file.is_a?(Hash)
      return file.id if file.respond_to?(:id)

      nil
    rescue StandardError
      nil
    end

    def local_path_from(file)
      if file.is_a?(Hash)
        return file.dig("local", "path")
      end

      return file.local&.path if file.respond_to?(:local)

      nil
    rescue StandardError
      nil
    end

    def build_display_name(payload)
      full_name = [payload[:first_name], payload[:last_name]].compact.join(" ").strip
      return full_name if full_name.present?

      payload[:username].presence
    end
  end
end
