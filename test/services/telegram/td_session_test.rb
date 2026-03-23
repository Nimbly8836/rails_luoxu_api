# frozen_string_literal: true

require "test_helper"

class TelegramTdSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "timeout retry wait falls back to message sync wait seconds" do
    with_env(
      "TELEGRAM_HISTORY_TIMEOUT_RETRIES" => "1",
      "TELEGRAM_HISTORY_TIMEOUT_RETRY_WAIT_SECONDS" => nil,
      "TELEGRAM_MESSAGE_SYNC_WAIT_SECONDS" => "5"
    ) do
      session = build_session
      sleeps = []
      attempts = 0

      session.define_singleton_method(:sleep) do |seconds|
        sleeps << seconds
      end

      result = session.send(:with_td_timeout_retry, operation: "get_chat_history", chat_id: 1, from_message_id: 2) do
        attempts += 1
        raise Timeout::Error, "Timeout error" if attempts == 1

        :ok
      end

      assert_equal :ok, result
      assert_equal 2, attempts
      assert_equal [ 5.0 ], sleeps
    end
  end

  test "history fetch forwards explicit retry wait seconds" do
    session = build_session
    captured_wait_seconds = []
    response = Object.new
    client = Object.new

    response.define_singleton_method(:value!) { :history_page }
    client.define_singleton_method(:get_chat_history) { |**| response }
    session.instance_variable_set(:@client, client)
    session.define_singleton_method(:with_td_timeout_retry) do |operation:, chat_id:, from_message_id:, wait_seconds:, limit: nil, &block|
      captured_wait_seconds << [ operation, chat_id, from_message_id, wait_seconds, limit ]
      block.call
    end

    result = session.send(
      :fetch_history_messages_page,
      chat_id: 123,
      from_message_id: 456,
      offset: 0,
      limit: 20,
      retry_wait_seconds: 7.5
    )

    assert_equal :history_page, result
    assert_equal [ [ "get_chat_history", 123, 456, 7.5, 20 ] ], captured_wait_seconds
  end

  test "history fetch reduces batch size after timeout" do
    session = build_session
    response = Object.new
    client = Object.new
    requested_limits = []

    response.define_singleton_method(:value!) { :history_page }
    client.define_singleton_method(:get_chat_history) do |**kwargs|
      requested_limits << kwargs[:limit]
      raise Timeout::Error, "Timeout error" if requested_limits.one?

      response
    end
    session.instance_variable_set(:@client, client)
    session.define_singleton_method(:with_td_timeout_retry) do |operation:, chat_id:, from_message_id:, wait_seconds:, limit: nil, &block|
      block.call
    end

    with_env("TELEGRAM_MESSAGE_SYNC_MIN_BATCH_LIMIT" => "10") do
      result = session.send(
        :fetch_history_messages_page,
        chat_id: 123,
        from_message_id: 0,
        offset: 0,
        limit: 50,
        retry_wait_seconds: 7.5
      )

      assert_equal :history_page, result
      assert_equal [ 50, 25 ], requested_limits
    end
  end

  test "timeout retry wait grows with each retry" do
    session = build_session
    sleeps = []
    attempts = 0

    with_env(
      "TELEGRAM_HISTORY_TIMEOUT_RETRIES" => "2",
      "TELEGRAM_HISTORY_TIMEOUT_RETRY_WAIT_SECONDS" => nil,
      "TELEGRAM_HISTORY_TIMEOUT_RETRY_MAX_WAIT_SECONDS" => "60",
      "TELEGRAM_MESSAGE_SYNC_WAIT_SECONDS" => "5"
    ) do
      session.define_singleton_method(:sleep) do |seconds|
        sleeps << seconds
      end

      result = session.send(:with_td_timeout_retry, operation: "get_chat_history", chat_id: 1, from_message_id: 2) do
        attempts += 1
        raise Timeout::Error, "Timeout error" if attempts < 3

        :ok
      end

      assert_equal :ok, result
      assert_equal 3, attempts
      assert_equal [ 5.0, 10.0 ], sleeps
    end
  end

  test "history backfill is required only when local history has a gap" do
    session = build_session

    assert_equal true, session.send(:history_backfill_required?, existing_min_message_id: 42, existing_min_td_message_id: 123)
    assert_equal false, session.send(:history_backfill_required?, existing_min_message_id: 1, existing_min_td_message_id: 123)
    assert_equal false, session.send(:history_backfill_required?, existing_min_message_id: 0, existing_min_td_message_id: 0)
  end

  test "backfill reports continuation when page budget is reached" do
    session = build_session
    pages = [
      [
        {
          td_message_id: 900,
          message: { td_chat_id: 123, message_id: 90, message_at: Time.current }
        },
        {
          td_message_id: 850,
          message: { td_chat_id: 123, message_id: 85, message_at: Time.current }
        }
      ]
    ]

    session.define_singleton_method(:fetch_history_messages_page) { |_kwargs = nil, **| :page }
    session.define_singleton_method(:extract_history_count) { |_response| 2 }
    session.define_singleton_method(:extract_history_messages) { |_response| pages.shift || [] }
    session.define_singleton_method(:upsert_usernames_from) { |_bundles| nil }
    session.define_singleton_method(:upsert_messages_bulk) { |messages| messages.size }
    session.define_singleton_method(:sleep) { |_seconds| nil }

    with_env("TELEGRAM_MESSAGE_SYNC_BACKFILL_MAX_PAGES" => "1") do
      result = session.send(
        :backfill_older_messages_for_chat,
        chat_id: 123,
        existing_min_message_id: 100,
        existing_min_td_message_id: 1_000,
        per_chat_limit: nil,
        batch_limit: 200,
        delay: 0.25
      )

      assert_equal true, result[:attempted]
      assert_equal false, result[:reached_start]
      assert_equal true, result[:continuation_required]
      assert_equal "backfill_page_budget_reached", result[:continuation_reason]
      assert_equal 2, result[:upserted]
      assert_equal 85, result[:new_min_message_id]
      assert_equal 850, result[:new_min_td_message_id]
    end
  end

  test "sync_messages_for_chats_async enqueues a message sync job" do
    session = build_session

    result = session.sync_messages_for_chats_async(chat_ids: [ 3, 1, 3 ], limit_per_chat: 20, reason: "manual")

    assert_equal true, result[:enqueued]
    assert_equal "enqueued", result[:status]
    assert result[:job_id].present?
    assert_equal [ 1, 3 ], result[:chat_ids]
    assert_equal false, result[:watched_chat_ids]
    assert_equal 0.5, result[:wait_seconds]
    assert_equal 20, result[:limit_per_chat]
    assert_equal 1, enqueued_jobs.size

    job = enqueued_jobs.last
    assert_equal Telegram::MessageSyncJob, job[:job]
    args = job[:args].first
    assert_equal "test-session", args["account_uuid"]
    assert_equal [ 1, 3 ], args["chat_ids"]
    assert_equal false, args["use_watched_chat_ids"]
    assert_equal 20, args["limit_per_chat"]
    assert_equal 0.5, args["wait_seconds"]
    assert_equal "manual", args["reason"]
    assert_equal 0, args["retry_attempt"]
  end

  test "sync_messages_for_chats_async enqueues watched chat sync job" do
    session = build_session
    result = session.sync_messages_for_watched_chats_async(reason: "boot")

    assert_equal true, result[:enqueued]
    assert_equal "enqueued", result[:status]
    assert_equal [], result[:chat_ids]
    assert_equal true, result[:watched_chat_ids]
    assert_equal 1, enqueued_jobs.size

    job = enqueued_jobs.last
    assert_equal Telegram::MessageSyncJob, job[:job]
    args = job[:args].first
    assert_equal true, args["use_watched_chat_ids"]
    assert_equal [], args["chat_ids"]
    assert_equal "boot", args["reason"]
  end

  test "sync_group_members_for_chats_async enqueues a group member sync job" do
    session = build_session

    result = session.sync_group_members_for_chats_async(chat_ids: [3, 1, 3], reason: "manual")

    assert_equal true, result[:enqueued]
    assert_equal "enqueued", result[:status]
    assert result[:job_id].present?
    assert_equal [1, 3], result[:chat_ids]
    assert_equal true, result[:refresh_avatars]

    job = enqueued_jobs.last
    assert_equal Telegram::GroupMemberSyncJob, job[:job]
    args = job[:args].first
    assert_equal "test-session", args["account_uuid"]
    assert_equal [1, 3], args["chat_ids"]
    assert_equal true, args["refresh_avatars"]
    assert_equal "manual", args["reason"]
    assert_equal 0, args["retry_attempt"]
  end

  test "refresh_chat_async enqueues a chat refresh job" do
    session = build_session

    result = session.refresh_chat_async(chat_id: -100123, reason: "api_me_chat")

    assert_equal true, result[:enqueued]
    assert_equal "enqueued", result[:status]
    assert result[:job_id].present?
    assert_equal(-100123, result[:chat_id])
    assert_equal true, result[:refresh_avatar]

    job = enqueued_jobs.last
    assert_equal Telegram::ChatRefreshJob, job[:job]
    args = job[:args].first
    assert_equal "test-session", args["account_uuid"]
    assert_equal(-100123, args["chat_id"])
    assert_equal true, args["refresh_avatar"]
    assert_equal "api_me_chat", args["reason"]
  end

  test "extract_chat_photo_attrs tolerates missing existing record" do
    session = build_session

    attrs = session.send(:extract_chat_photo_attrs, nil, include_blob: false, existing_record: nil)

    assert_equal(
      {
        avatar_small_file_id: nil,
        avatar_big_file_id: nil,
        avatar_small_data: nil,
        avatar_small_content_type: nil,
        avatar_small_fetched_at: nil
      },
      attrs
    )
  end

  test "extract_user_avatar_attrs tolerates missing existing member" do
    session = build_session

    attrs = session.send(:extract_user_avatar_attrs, Object.new, existing_member: nil, refresh_avatar: false)

    assert_equal(
      {
        avatar_small_file_id: nil,
        avatar_small_data: nil,
        avatar_small_content_type: nil,
        avatar_small_fetched_at: nil
      },
      attrs
    )
  end

  test "client_config includes configurable tdlib timeout" do
    session = build_session
    account = Struct.new(:use_test_dc, :database_directory, :files_directory).new(false, "/tmp/db", "/tmp/files")

    with_env("TDLIB_CLIENT_TIMEOUT_SECONDS" => "90") do
      config = session.send(:client_config, account)

      assert_equal 90.0, config[:timeout]
      assert_equal "/tmp/db", config[:database_directory]
      assert_equal "/tmp/files", config[:files_directory]
    end
  end

  private

  def build_session
    Telegram::TdSession.allocate.tap do |session|
      session.instance_variable_set(:@id, "test-session")
      session.instance_variable_set(:@mutex, Mutex.new)
      session.instance_variable_set(:@operation_mutex, Mutex.new)
    end
  end

  def with_env(overrides)
    sentinel = Object.new
    original = {}
    overrides.each_key do |key|
      original[key] = ENV.key?(key) ? ENV[key] : sentinel
    end

    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end

    yield
  ensure
    original&.each do |key, value|
      value.equal?(sentinel) ? ENV.delete(key) : ENV[key] = value
    end
  end
end
