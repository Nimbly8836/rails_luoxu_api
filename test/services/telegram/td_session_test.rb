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

  test "history fetch forwards explicit retry wait seconds to remote fallback" do
    session = build_session
    captured_wait_seconds = []
    local_response = Object.new
    remote_response = Object.new
    client = Object.new

    local_response.define_singleton_method(:messages) { [] }
    local_response.define_singleton_method(:value!) { self }
    remote_response.define_singleton_method(:messages) { [ :remote ] }
    remote_response.define_singleton_method(:value!) { self }
    client.define_singleton_method(:get_chat_history) { |**kwargs| kwargs[:only_local] ? local_response : remote_response }
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

    assert_same remote_response, result
    assert_equal [ [ "get_chat_history", 123, 456, 7.5, 25 ] ], captured_wait_seconds
  end

  test "history fetch prefers local tdlib database before remote" do
    session = build_session
    client = Object.new
    calls = []
    local_response = Object.new

    local_response.define_singleton_method(:messages) { [ :local ] }
    local_response.define_singleton_method(:value!) { self }
    client.define_singleton_method(:get_chat_history) do |**kwargs|
      calls << kwargs
      local_response
    end
    session.instance_variable_set(:@client, client)

    result = session.send(
      :fetch_history_messages_page,
      chat_id: 123,
      from_message_id: 456,
      offset: 0,
      limit: 20,
      retry_wait_seconds: 7.5
    )

    assert_same local_response, result
    assert_equal 1, calls.size
    assert_equal true, calls.first[:only_local]
  end

  test "history fetch falls back to remote when local tdlib database is empty" do
    session = build_session
    client = Object.new
    calls = []
    local_response = Object.new
    remote_response = Object.new

    local_response.define_singleton_method(:messages) { [] }
    local_response.define_singleton_method(:value!) { self }
    remote_response.define_singleton_method(:messages) { [ :remote ] }
    remote_response.define_singleton_method(:value!) { self }
    client.define_singleton_method(:get_chat_history) do |**kwargs|
      calls << kwargs
      kwargs[:only_local] ? local_response : remote_response
    end
    session.instance_variable_set(:@client, client)

    result = session.send(
      :fetch_history_messages_page,
      chat_id: 123,
      from_message_id: 456,
      offset: 0,
      limit: 20,
      retry_wait_seconds: 7.5
    )

    assert_same remote_response, result
    assert_equal 2, calls.size
    assert_equal [ true, false ], calls.map { |call| call[:only_local] }
  end

  test "history fetch falls back to remote when local tdlib database times out" do
    session = build_session
    client = Object.new
    calls = []
    remote_response = Object.new

    remote_response.define_singleton_method(:messages) { [ :remote ] }
    remote_response.define_singleton_method(:value!) { self }
    client.define_singleton_method(:get_chat_history) do |**kwargs|
      calls << kwargs
      raise Timeout::Error, "Timeout error" if kwargs[:only_local]

      remote_response
    end
    session.instance_variable_set(:@client, client)

    result = session.send(
      :fetch_history_messages_page,
      chat_id: 123,
      from_message_id: 456,
      offset: 0,
      limit: 20,
      retry_wait_seconds: 7.5
    )

    assert_same remote_response, result
    assert_equal 2, calls.size
    assert_equal [ true, false ], calls.map { |call| call[:only_local] }
  end

  test "history fetch skips further local tdlib probes after a local miss" do
    session = build_session
    client = Object.new
    calls = []
    local_response = Object.new
    remote_response = Object.new
    history_fetch_state = session.send(:default_history_fetch_state)

    local_response.define_singleton_method(:messages) { [] }
    local_response.define_singleton_method(:value!) { self }
    remote_response.define_singleton_method(:messages) { [ :remote ] }
    remote_response.define_singleton_method(:value!) { self }
    client.define_singleton_method(:get_chat_history) do |**kwargs|
      calls << kwargs
      kwargs[:only_local] ? local_response : remote_response
    end
    session.instance_variable_set(:@client, client)

    2.times do
      result = session.send(
        :fetch_history_messages_page,
        chat_id: 123,
        from_message_id: 456,
        offset: 0,
        limit: 20,
        retry_wait_seconds: 7.5,
        history_fetch_state:
      )

      assert_same remote_response, result
    end

    assert_equal [ true, false, false ], calls.map { |call| call[:only_local] }
    assert_equal false, history_fetch_state[:local_enabled]
    assert_equal "empty", history_fetch_state[:local_disabled_reason]
  end

  test "history extraction skips remote sender lookup when disabled" do
    session = build_session
    client = Object.new
    lookups = []
    response = Object.new

    client.define_singleton_method(:get_user) do |**kwargs|
      lookups << kwargs
      raise "should not fetch user remotely"
    end
    session.instance_variable_set(:@client, client)
    response.define_singleton_method(:messages) do
      [
        {
          "id" => 300_000_000_123,
          "chat_id" => -100123,
          "date" => 1_700_000_000,
          "sender_id" => {
            "@type" => "messageSenderUser",
            "user_id" => 42
          },
          "content" => {
            "@type" => "messageText",
            "text" => { "text" => "hello" }
          }
        }
      ]
    end

    bundles = session.send(:extract_history_messages, response, resolve_sender_names: false)

    assert_equal 0, lookups.size
    assert_equal 1, bundles.size
    assert_nil bundles.first.dig(:message, :sender_name)
  end

  test "history fetch reduces batch size after timeout" do
    session = build_session
    local_response = Object.new
    remote_response = Object.new
    client = Object.new
    requested_limits = []

    local_response.define_singleton_method(:messages) { [] }
    local_response.define_singleton_method(:value!) { self }
    remote_response.define_singleton_method(:messages) { [ :remote ] }
    remote_response.define_singleton_method(:value!) { self }
    client.define_singleton_method(:get_chat_history) do |**kwargs|
      return local_response if kwargs[:only_local]

      requested_limits << kwargs[:limit]
      raise Timeout::Error, "Timeout error" if requested_limits.one?

      remote_response
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

      assert_same remote_response, result
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
    session.define_singleton_method(:extract_history_messages) { |_response, **| pages.shift || [] }
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
        delay: 0.25,
        loaded_frontier: session.send(:default_history_frontier),
        history_fetch_state: session.send(:default_history_fetch_state)
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

  test "full history seed reports continuation when page budget is reached" do
    session = build_session
    page = [
      {
        td_message_id: 900,
        message: { td_chat_id: 123, message_id: 90, message_at: Time.current }
      },
      {
        td_message_id: 850,
        message: { td_chat_id: 123, message_id: 85, message_at: Time.current }
      }
    ]

    session.define_singleton_method(:with_operation_lock) { |_kwargs = nil, **, &block| block.call }
    session.define_singleton_method(:raise_if_disposed!) { nil }
    session.define_singleton_method(:wait_until_ready!) { nil }
    session.define_singleton_method(:history_sync_state_lookup) do |_ids|
      { 123 => send(:default_history_sync_state) }
    end
    session.define_singleton_method(:precheck_history_sync_chat) do |chat_id:, **|
      { chat_title: "chat-#{chat_id}", last_message_id: 900, precheck_error: nil }
    end
    session.define_singleton_method(:supports_chat_history_frontier?) { false }
    session.define_singleton_method(:fetch_history_messages_page) { |_kwargs = nil, **| :page }
    session.define_singleton_method(:extract_history_count) { |_response| 2 }
    session.define_singleton_method(:describe_response) { |_response| { class: "TestResponse", message_count: 2 } }
    session.define_singleton_method(:extract_history_messages) { |_response, **| page }
    session.define_singleton_method(:upsert_usernames_from) { |_bundles| nil }
    session.define_singleton_method(:upsert_messages_bulk) { |messages| messages.size }
    session.define_singleton_method(:persist_chat_history_frontier!) { |**| nil }
    session.define_singleton_method(:sleep) { |_seconds| nil }

    with_env("TELEGRAM_MESSAGE_SYNC_SEED_MAX_PAGES" => "1") do
      result = session.sync_messages_for_chats(chat_ids: [ 123 ], limit_per_chat: nil, wait_seconds: nil)

      assert_equal 1, result[:details].size
      detail = result[:details].first
      assert_equal 2, result[:upserted]
      assert_equal "full_history", detail[:mode]
      assert_equal true, detail[:continuation_required]
      assert_equal "seed_page_budget_reached", detail[:continuation_reason]
    end
  end

  test "incremental history reports continuation when forward page budget is reached" do
    session = build_session
    page = [
      {
        td_message_id: 1_000,
        message: { td_chat_id: 123, message_id: 100, message_at: Time.current }
      },
      {
        td_message_id: 900,
        message: { td_chat_id: 123, message_id: 90, message_at: Time.current }
      }
    ]

    session.define_singleton_method(:with_operation_lock) { |_kwargs = nil, **, &block| block.call }
    session.define_singleton_method(:raise_if_disposed!) { nil }
    session.define_singleton_method(:wait_until_ready!) { nil }
    session.define_singleton_method(:history_sync_state_lookup) do |_ids|
      {
        123 => send(:default_history_sync_state).merge(
          chat_known_to_account: true,
          chat_title: "chat-123",
          existing_min_message_id: 1,
          existing_max_message_id: 50
        )
      }
    end
    session.define_singleton_method(:precheck_history_sync_chat) do |chat_id:, **|
      { chat_title: "chat-#{chat_id}", last_message_id: 1_000, precheck_error: nil }
    end
    session.define_singleton_method(:supports_chat_history_frontier?) { false }
    session.define_singleton_method(:fetch_history_messages_page) { |_kwargs = nil, **| :page }
    session.define_singleton_method(:extract_history_count) { |_response| 2 }
    session.define_singleton_method(:describe_response) { |_response| { class: "TestResponse", message_count: 2 } }
    session.define_singleton_method(:extract_history_messages) { |_response, **| page }
    session.define_singleton_method(:upsert_usernames_from) { |_bundles| nil }
    session.define_singleton_method(:upsert_messages_bulk) { |messages| messages.size }
    session.define_singleton_method(:persist_chat_history_frontier!) { |**| nil }
    session.define_singleton_method(:sleep) { |_seconds| nil }

    result = session.sync_messages_for_chats(
      chat_ids: [ 123 ],
      limit_per_chat: nil,
      wait_seconds: nil,
      forward_max_pages: 1
    )

    assert_equal 1, result[:details].size
    detail = result[:details].first
    assert_equal "incremental", detail[:mode]
    assert_equal true, detail[:continuation_required]
    assert_equal "forward_page_budget_reached", detail[:continuation_reason]
  end

  test "sync_messages_for_chats_async schedules local message sync" do
    session = build_session
    captured = nil

    session.define_singleton_method(:schedule_message_sync_locally) do |**kwargs|
      captured = kwargs
      {
        enqueued: true,
        status: "scheduled",
        reason: kwargs[:reason].to_s,
        chat_ids: kwargs[:chat_ids],
        watched_chat_ids: kwargs[:use_watched_chat_ids],
        wait_seconds: 5.0,
        limit_per_chat: kwargs[:limit_per_chat]
      }
    end

    result = session.sync_messages_for_chats_async(chat_ids: [ 3, 1, 3 ], limit_per_chat: 20, reason: "manual")

    assert_equal true, result[:enqueued]
    assert_equal "scheduled", result[:status]
    assert_equal [ 1, 3 ], result[:chat_ids]
    assert_equal false, result[:watched_chat_ids]
    assert_equal 20, result[:limit_per_chat]
    assert_equal 5.0, result[:wait_seconds]
    assert_equal 0, enqueued_jobs.size
    assert_equal [ 1, 3 ], captured[:chat_ids]
    assert_equal false, captured[:use_watched_chat_ids]
    assert_equal 20, captured[:limit_per_chat]
    assert_nil captured[:wait_seconds]
    assert_equal "manual", captured[:reason]
  end

  test "sync_messages_for_chats_async schedules watched chat sync" do
    session = build_session
    captured = nil

    session.define_singleton_method(:schedule_message_sync_locally) do |**kwargs|
      captured = kwargs
      {
        enqueued: true,
        status: "scheduled",
        reason: kwargs[:reason].to_s,
        chat_ids: [ 4, 9 ],
        watched_chat_ids: kwargs[:use_watched_chat_ids],
        wait_seconds: 5.0,
        limit_per_chat: kwargs[:limit_per_chat]
      }
    end

    result = session.sync_messages_for_watched_chats_async(reason: "boot")

    assert_equal true, result[:enqueued]
    assert_equal "scheduled", result[:status]
    assert_equal [ 4, 9 ], result[:chat_ids]
    assert_equal true, result[:watched_chat_ids]
    assert_equal 0, enqueued_jobs.size
    assert_equal true, captured[:use_watched_chat_ids]
    assert_nil captured[:chat_ids]
    assert_equal "boot", captured[:reason]
  end

  test "sync_group_members_for_chats_async enqueues a group member sync job" do
    session = build_session

    result = session.sync_group_members_for_chats_async(chat_ids: [ 3, 1, 3 ], reason: "manual")

    assert_equal true, result[:enqueued]
    assert_equal "enqueued", result[:status]
    assert result[:job_id].present?
    assert_equal [ 1, 3 ], result[:chat_ids]
    assert_equal true, result[:refresh_avatars]

    job = enqueued_jobs.last
    assert_equal Telegram::GroupMemberSyncJob, job[:job]
    args = job[:args].first
    assert_equal "test-session", args["account_uuid"]
    assert_equal [ 1, 3 ], args["chat_ids"]
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
      session.instance_variable_set(:@account_id, 1)
      session.instance_variable_set(:@id, "test-session")
      session.instance_variable_set(:@mutex, Mutex.new)
      session.instance_variable_set(:@operation_mutex, Mutex.new)
      session.instance_variable_set(:@sender_name_cache, {})
      session.instance_variable_set(:@message_link_cache, {})
      session.instance_variable_set(:@opened_chat_ids, {})
      session.instance_variable_set(:@watched_chat_ids_cache, {})
      session.instance_variable_set(:@watched_chat_ids_cache_loaded_at, 0.0)
      session.instance_variable_set(:@message_sync_scheduler_mutex, Mutex.new)
      session.instance_variable_set(:@message_sync_scheduler_cv, ConditionVariable.new)
      session.instance_variable_set(:@scheduled_message_syncs, {})
      session.instance_variable_set(:@message_sync_schedule_sequence, 0)
      session.instance_variable_set(:@message_sync_scheduler_thread, nil)
      session.instance_variable_set(:@disposed, false)
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
