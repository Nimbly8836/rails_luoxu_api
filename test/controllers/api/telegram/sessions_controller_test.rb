# frozen_string_literal: true

require "test_helper"

module Api
  module Telegram
    class SessionsControllerTest < ActionDispatch::IntegrationTest
      test "sync_messages enqueues poll repair sync for requested chats with null text rows" do
        user = create_system_user
        account = create_account
        TelegramMessage.create!(
          telegram_account: account,
          td_chat_id: -100123,
          td_message_id: 300_000_000_456,
          td_sender_id: 42,
          message_at: Time.at(1_700_000_000),
          message_id: 456,
          text: nil
        )
        TelegramMessage.create!(
          telegram_account: account,
          td_chat_id: -100456,
          td_message_id: 300_000_000_789,
          td_sender_id: 42,
          message_at: Time.at(1_700_000_100),
          message_id: 789,
          text: "healthy"
        )

        calls = []
        fake_session = build_session(calls)

        with_runtime_session(account, fake_session) do
          post "/api/telegram/sessions/#{account.uuid}/sync_messages",
               params: { chat_ids: [ -100123, -100456 ], message_limit: 20 },
               as: :json,
               headers: auth_headers(user)
        end

        assert_response :accepted
        assert_equal 2, calls.size

        assert_equal(
          {
            chat_ids: [ -100456, -100123 ],
            limit_per_chat: 20,
            wait_seconds: nil,
            reason: "api_sync_messages",
            repair_existing: false
          },
          calls.first
        )
        assert_equal(
          {
            chat_ids: [ -100123 ],
            limit_per_chat: 20,
            wait_seconds: nil,
            reason: "api_sync_messages_poll_repair",
            repair_existing: true
          },
          calls.second
        )

        response_body = response.parsed_body
        assert_equal [ -100123, -100456 ], response_body["chat_ids"]
        assert_equal false, response_body.dig("message_sync", "repair_existing")
        assert_equal [ -100123 ], response_body.dig("poll_repair_sync", "chat_ids")
        assert_equal true, response_body.dig("poll_repair_sync", "repair_existing")
      ensure
        cleanup_account_storage(account)
      end

      test "sync_messages skips poll repair when requested chats have no local history" do
        user = create_system_user
        account = create_account

        calls = []
        fake_session = build_session(calls)

        with_runtime_session(account, fake_session) do
          post "/api/telegram/sessions/#{account.uuid}/sync_messages",
               params: { chat_ids: [ -100456 ], message_limit: 20 },
               as: :json,
               headers: auth_headers(user)
        end

        assert_response :accepted
        assert_equal 1, calls.size
        assert_equal false, response.parsed_body.dig("message_sync", "repair_existing")
        assert_equal false, response.parsed_body.dig("poll_repair_sync", "enqueued")
        assert_equal "no_candidate_chats", response.parsed_body.dig("poll_repair_sync", "reason")
      ensure
        cleanup_account_storage(account)
      end

      test "sync_messages enqueues poll repair for requested chats with existing history even when text is present" do
        user = create_system_user
        account = create_account
        TelegramMessage.create!(
          telegram_account: account,
          td_chat_id: -100456,
          td_message_id: 300_000_000_789,
          td_sender_id: 42,
          message_at: Time.at(1_700_000_100),
          message_id: 789,
          text: "Historical poll question"
        )

        calls = []
        fake_session = build_session(calls)

        with_runtime_session(account, fake_session) do
          post "/api/telegram/sessions/#{account.uuid}/sync_messages",
               params: { chat_ids: [ -100456 ], message_limit: 20 },
               as: :json,
               headers: auth_headers(user)
        end

        assert_response :accepted
        assert_equal 2, calls.size
        assert_equal(
          {
            chat_ids: [ -100456 ],
            limit_per_chat: 20,
            wait_seconds: nil,
            reason: "api_sync_messages_poll_repair",
            repair_existing: true
          },
          calls.second
        )
        assert_equal [ -100456 ], response.parsed_body.dig("poll_repair_sync", "chat_ids")
      ensure
        cleanup_account_storage(account)
      end

      private

      def auth_headers(user)
        { "Authorization" => "Bearer #{user.api_token}" }
      end

      def create_system_user
        token = SecureRandom.hex(16)
        SystemUser.create!(
          username: "user_#{token}",
          password: "password123",
          password_confirmation: "password123",
          api_token: token,
          active: true,
          admin: false
        )
      end

      def create_account
        uuid = SecureRandom.uuid
        TelegramAccount.create!(
          uuid: uuid,
          state: "ready",
          enabled: true,
          database_directory: Rails.root.join("tmp", "tdlib", uuid, "db").to_s,
          files_directory: Rails.root.join("tmp", "tdlib", uuid, "files").to_s
        )
      end

      def build_session(calls)
        Object.new.tap do |session|
          session.define_singleton_method(:sync_messages_for_chats_async) do |**kwargs|
            normalized = {
              chat_ids: Array(kwargs[:chat_ids]).map(&:to_i).sort,
              limit_per_chat: kwargs[:limit_per_chat]&.to_i,
              wait_seconds: kwargs[:wait_seconds],
              reason: kwargs[:reason].to_s,
              repair_existing: ActiveModel::Type::Boolean.new.cast(kwargs[:repair_existing])
            }
            calls << normalized
            { enqueued: true, status: "scheduled" }.merge(normalized)
          end
        end
      end

      def with_runtime_session(account, session)
        runtime_singleton = class << ::Telegram::Runtime; self; end
        fetch_backup = :__telegram_sessions_controller_test_original_fetch
        start_backup = :__telegram_sessions_controller_test_original_start

        runtime_singleton.alias_method fetch_backup, :fetch
        runtime_singleton.alias_method start_backup, :start
        runtime_singleton.define_method(:fetch) do |uuid|
          uuid == account.uuid ? session : nil
        end
        runtime_singleton.define_method(:start) do |runtime_account|
          runtime_account.uuid == account.uuid ? session : send(start_backup, runtime_account)
        end
        yield
      ensure
        if runtime_singleton.method_defined?(fetch_backup)
          runtime_singleton.alias_method :fetch, fetch_backup
          runtime_singleton.remove_method fetch_backup
        end
        if runtime_singleton.method_defined?(start_backup)
          runtime_singleton.alias_method :start, start_backup
          runtime_singleton.remove_method start_backup
        end
      end

      def cleanup_account_storage(account)
        return unless account

        FileUtils.rm_rf(File.dirname(account.database_directory))
      end
    end
  end
end
