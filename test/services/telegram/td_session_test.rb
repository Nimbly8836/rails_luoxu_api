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
    TelegramAccountPollState.delete_all
    TelegramPollOption.delete_all
    TelegramPoll.delete_all
    clear_enqueued_jobs
    clear_performed_jobs
    TelegramMessageHistory.delete_all
    TelegramMessage.delete_all
    TelegramAccount.delete_all
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

  test "history extraction parses unsupported foundChatMessages payloads" do
    session = build_session
    response = Struct.new(:original_type, :raw).new(
      "foundChatMessages",
      {
        "messages" => [
          {
            "id" => 300_000_000_123,
            "chat_id" => -100123,
            "date" => 1_700_000_000,
            "sender_id" => {
              "@type" => "messageSenderUser",
              "user_id" => 42
            },
            "content" => {
              "@type" => "messagePoll",
              "poll" => {
                "id" => "poll_123",
                "question" => "Recovered by search",
                "options" => []
              }
            }
          }
        ]
      }
    )

    bundles = session.send(:extract_history_messages, response, resolve_sender_names: false)

    assert_equal 1, session.send(:extract_history_count, response)
    assert_equal "Struct", session.send(:describe_response, response)[:class]
    assert_equal 1, bundles.size
    assert_equal "Recovered by search", bundles.first.dig(:message, :text)
    assert_equal "poll_123", bundles.first.dig(:poll_snapshot, :poll_id)
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

  test "backfill falls back to search when anchored history fetch returns empty" do
    session = build_session
    fetch_calls = []
    search_calls = []
    search_page = [
      {
        td_message_id: 900,
        message: { td_chat_id: 123, message_id: 90, message_at: Time.current, text: "poll question" }
      }
    ]

    session.define_singleton_method(:fetch_history_messages_page) do |chat_id:, from_message_id:, **|
      fetch_calls << [ chat_id, from_message_id ]
      :empty_page
    end
    session.define_singleton_method(:fetch_search_messages_page) do |chat_id:, from_message_id:, **|
      search_calls << [ chat_id, from_message_id ]
      search_calls.one? ? :search_page : :empty_search_page
    end
    session.define_singleton_method(:extract_history_count) do |response|
      case response
      when :search_page then 1
      else 0
      end
    end
    session.define_singleton_method(:extract_history_messages) do |response, **|
      response == :search_page ? search_page : []
    end
    session.define_singleton_method(:persist_message_bundles) { |bundles| bundles.size }
    session.define_singleton_method(:sleep) { |_seconds| nil }

    result = session.send(
      :backfill_older_messages_for_chat,
      chat_id: 123,
      existing_min_message_id: 100,
      existing_min_td_message_id: 1_000,
      per_chat_limit: nil,
      batch_limit: 200,
      delay: 0.25,
      loaded_frontier: session.send(:default_history_frontier),
      history_fetch_state: session.send(:default_history_fetch_state),
      max_pages: 2
    )

    assert_equal [ [ 123, 1_000 ], [ 123, 900 ] ], fetch_calls
    assert_equal [ [ 123, 1_000 ], [ 123, 900 ] ], search_calls
    assert_equal 1, result[:upserted]
    assert_equal 1, result[:fetched]
    assert_equal 1, result[:parsed]
    assert_equal true, result[:reached_start]
    assert_equal 90, result[:new_min_message_id]
    assert_equal 900, result[:new_min_td_message_id]
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

  test "sync_messages_for_chats backfills poll snapshots from historical poll messages" do
    account = create_account
    session = build_session(account_id: account.id)
    page = [
      session.send(
        :extract_message_bundle,
        {
          "id" => 300_000_000_456,
          "chat_id" => -100123,
          "date" => 1_700_000_000,
          "sender_id" => {
            "@type" => "messageSenderUser",
            "user_id" => 42
          },
          "content" => {
            "@type" => "messagePoll",
            "poll" => {
              "id" => "history_poll_123",
              "question" => "Historical poll",
              "is_anonymous" => false,
              "allows_multiple_answers" => true,
              "total_voter_count" => 7,
              "is_closed" => false,
              "options" => [
                {
                  "text" => "A",
                  "voter_count" => 3,
                  "is_chosen" => false
                },
                {
                  "text" => "B",
                  "voter_count" => 4,
                  "is_chosen" => true
                }
              ]
            }
          }
        },
        resolve_sender_names: false
      )
    ]

    session.define_singleton_method(:with_operation_lock) { |_kwargs = nil, **, &block| block.call }
    session.define_singleton_method(:raise_if_disposed!) { nil }
    session.define_singleton_method(:wait_until_ready!) { nil }
    session.define_singleton_method(:history_sync_state_lookup) do |_ids|
      { -100123 => send(:default_history_sync_state) }
    end
    session.define_singleton_method(:precheck_history_sync_chat) do |chat_id:, **|
      { chat_title: "chat-#{chat_id}", last_message_id: 300_000_000_456, precheck_error: nil }
    end
    session.define_singleton_method(:supports_chat_history_frontier?) { false }
    session.define_singleton_method(:fetch_history_messages_page) { |_kwargs = nil, **| :page }
    session.define_singleton_method(:extract_history_count) { |_response| page.present? ? 1 : 0 }
    session.define_singleton_method(:describe_response) { |_response| { class: "TestResponse", message_count: 1 } }
    session.define_singleton_method(:extract_history_messages) { |_response, **| page.tap { page = [] } }
    session.define_singleton_method(:persist_chat_history_frontier!) { |**| nil }
    session.define_singleton_method(:sleep) { |_seconds| nil }

    assert_difference("TelegramMessage.count", 1) do
      assert_difference("TelegramPoll.count", 1) do
        assert_difference("TelegramPollOption.count", 2) do
          assert_difference("TelegramAccountPollState.count", 1) do
            result = session.sync_messages_for_chats(chat_ids: [ -100123 ], limit_per_chat: nil, wait_seconds: nil)
            assert_equal 1, result[:upserted]
          end
        end
      end
    end

    message = TelegramMessage.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "Historical poll", message.text

    poll = TelegramPoll.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "history_poll_123", poll.poll_id
    assert_equal "Historical poll", poll.question

    state = TelegramAccountPollState.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal [ 1 ], state.chosen_option_indexes
  end

  test "sync_messages_for_chats can repair existing poll messages when requested" do
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

    session = build_session(account_id: account.id)
    page = [
      session.send(
        :extract_message_bundle,
        {
          "id" => 300_000_000_456,
          "chat_id" => -100123,
          "date" => 1_700_000_000,
          "sender_id" => {
            "@type" => "messageSenderUser",
            "user_id" => 42
          },
          "content" => {
            "@type" => "messagePoll",
            "poll" => {
              "id" => "repair_poll_123",
              "question" => {
                "text" => "Repair this poll",
                "entities" => []
              },
              "is_anonymous" => false,
              "allows_multiple_answers" => true,
              "total_voter_count" => 7,
              "is_closed" => false,
              "options" => [
                {
                  "text" => {
                    "text" => "A",
                    "entities" => []
                  },
                  "voter_count" => 3,
                  "is_chosen" => false
                },
                {
                  "text" => {
                    "text" => "B",
                    "entities" => []
                  },
                  "voter_count" => 4,
                  "is_chosen" => true
                }
              ]
            }
          }
        },
        resolve_sender_names: false
      )
    ]

    session.define_singleton_method(:with_operation_lock) { |_kwargs = nil, **, &block| block.call }
    session.define_singleton_method(:raise_if_disposed!) { nil }
    session.define_singleton_method(:wait_until_ready!) { nil }
    session.define_singleton_method(:history_sync_state_lookup) do |_ids|
      {
        -100123 => send(:default_history_sync_state).merge(
          chat_known_to_account: true,
          chat_title: "chat--100123",
          existing_max_message_id: 456,
          existing_min_message_id: 456,
          existing_max_td_message_id: 300_000_000_456,
          existing_min_td_message_id: 300_000_000_456
        )
      }
    end
    session.define_singleton_method(:precheck_history_sync_chat) do |chat_id:, **|
      { chat_title: "chat-#{chat_id}", last_message_id: 300_000_000_456, precheck_error: nil }
    end
    session.define_singleton_method(:supports_chat_history_frontier?) { false }
    session.define_singleton_method(:fetch_history_messages_page) { |_kwargs = nil, **| :page }
    session.define_singleton_method(:extract_history_count) { |_response| page.present? ? 1 : 0 }
    session.define_singleton_method(:describe_response) { |_response| { class: "TestResponse", message_count: 1 } }
    session.define_singleton_method(:extract_history_messages) { |_response, **| page.tap { page = [] } }
    session.define_singleton_method(:persist_chat_history_frontier!) { |**| nil }
    session.define_singleton_method(:sleep) { |_seconds| nil }

    assert_no_difference("TelegramMessage.count") do
      assert_difference("TelegramPoll.count", 1) do
        assert_difference("TelegramPollOption.count", 2) do
          assert_difference("TelegramAccountPollState.count", 1) do
            result = session.sync_messages_for_chats(
              chat_ids: [ -100123 ],
              limit_per_chat: nil,
              wait_seconds: nil,
              repair_existing: true
            )
            assert_equal 1, result[:upserted]
          end
        end
      end
    end

    message = TelegramMessage.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "Repair this poll", message.text

    poll = TelegramPoll.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "repair_poll_123", poll.poll_id
    assert_equal "Repair this poll", poll.question

    state = TelegramAccountPollState.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal [ 1 ], state.chosen_option_indexes
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

  test "sync_messages_for_tracked_chats_async schedules known chat sync" do
    session = build_session
    captured = nil

    session.define_singleton_method(:tracked_chat_ids) { [ 4, 9 ] }
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

    result = session.sync_messages_for_tracked_chats_async(reason: "boot")

    assert_equal true, result[:enqueued]
    assert_equal "scheduled", result[:status]
    assert_equal [ 4, 9 ], result[:chat_ids]
    assert_equal false, result[:watched_chat_ids]
    assert_equal [ 4, 9 ], captured[:chat_ids]
    assert_equal false, captured[:use_watched_chat_ids]
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

  test "unsupported updateMessageContent updates message text edited_at and writes edited history" do
    account = create_account
    session = build_session(account_id: account.id)
    message = TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: -100123,
      td_message_id: 300_000_000_456,
      td_sender_id: 42,
      message_at: Time.at(1_700_000_000),
      message_id: 456,
      text: "before edit"
    )
    update = Struct.new(:original_type, :raw).new(
      "updateMessageContent",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "new_content" => {
          "@type" => "messageText",
          "text" => { "text" => "after edit" }
        }
      }
    )

    assert_difference("TelegramMessageHistory.where(event_type: 'edited').count", 1) do
      session.send(:handle_unsupported_update, update)
    end

    message.reload
    assert_equal "after edit", message.text
    assert_not_nil message.edited_at
    assert_nil message.deleted_at

    history = TelegramMessageHistory.order(:created_at).last
    assert_equal account.id, history.telegram_account_id
    assert_equal(-100123, history.td_chat_id)
    assert_equal 456, history.message_id
    assert_equal 300_000_000_456, history.td_message_id
    assert_equal "edited", history.event_type
    assert_equal "before edit", history.payload.dig("before", "text")
    assert_equal "after edit", history.payload.dig("after", "text")
    assert_equal "after edit", history.payload.dig("update", "new_content", "text", "text")
    assert_in_delta message.edited_at.to_f, history.event_at.to_f, 1.0
  end

  test "unsupported updateDeleteMessages soft deletes matching messages and writes deleted history" do
    account = create_account
    session = build_session(account_id: account.id)
    kept_message = TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: -100123,
      td_message_id: 300_000_000_111,
      td_sender_id: 42,
      message_at: Time.at(1_700_000_000),
      message_id: 111,
      text: "keep me"
    )
    deleted_message = TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: -100123,
      td_message_id: 300_000_000_222,
      td_sender_id: 42,
      message_at: Time.at(1_700_000_100),
      message_id: 222,
      text: "delete me"
    )
    update = Struct.new(:original_type, :raw).new(
      "updateDeleteMessages",
      {
        "chat_id" => -100123,
        "message_ids" => [ 300_000_000_222, 300_000_000_333 ],
        "from_cache" => false,
        "is_permanent" => true
      }
    )

    assert_difference("TelegramMessageHistory.where(event_type: 'deleted').count", 1) do
      session.send(:handle_unsupported_update, update)
    end

    kept_message.reload
    deleted_message.reload
    assert_nil kept_message.deleted_at
    assert_nil kept_message.edited_at
    assert_equal "keep me", kept_message.text
    assert_not_nil deleted_message.deleted_at
    assert_nil deleted_message.edited_at
    assert_equal "delete me", deleted_message.text

    history = TelegramMessageHistory.order(:created_at).last
    assert_equal account.id, history.telegram_account_id
    assert_equal(-100123, history.td_chat_id)
    assert_equal 222, history.message_id
    assert_equal 300_000_000_222, history.td_message_id
    assert_equal "deleted", history.event_type
    assert_equal [ 300_000_000_222, 300_000_000_333 ], history.payload["message_ids"]
    assert_in_delta deleted_message.deleted_at.to_f, history.event_at.to_f, 1.0
  end

  test "unsupported updateMessageContent does not fall back to message_id lookup when td_message_id storage is available" do
    account = create_account
    session = build_session(account_id: account.id)
    message = TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: -100123,
      td_message_id: 300_000_000_999,
      td_sender_id: 42,
      message_at: Time.at(1_700_000_000),
      message_id: 456,
      text: "before edit"
    )
    update = Struct.new(:original_type, :raw).new(
      "updateMessageContent",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "new_content" => {
          "@type" => "messageText",
          "text" => { "text" => "after edit" }
        }
      }
    )

    assert_no_difference("TelegramMessageHistory.where(event_type: 'edited').count") do
      session.send(:handle_unsupported_update, update)
    end

    message.reload
    assert_equal "before edit", message.text
    assert_nil message.edited_at
    assert_nil message.deleted_at
  end

  test "unsupported updateMessageContent rolls back message update when history write fails" do
    account = create_account
    session = build_session(account_id: account.id)
    message = TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: -100123,
      td_message_id: 300_000_000_456,
      td_sender_id: 42,
      message_at: Time.at(1_700_000_000),
      message_id: 456,
      text: "before edit"
    )
    update = Struct.new(:original_type, :raw).new(
      "updateMessageContent",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "new_content" => {
          "@type" => "messageText",
          "text" => { "text" => "after edit" }
        }
      }
    )
    session.define_singleton_method(:create_message_history!) do |**|
      raise ActiveRecord::RecordInvalid, TelegramMessageHistory.new
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      session.send(:handle_unsupported_update, update)
    end

    message.reload
    assert_equal "before edit", message.text
    assert_nil message.edited_at
    assert_nil message.deleted_at
    assert_equal 0, TelegramMessageHistory.where(event_type: "edited").count
  end

  test "unsupported updateDeleteMessages rolls back soft delete when history write fails" do
    account = create_account
    session = build_session(account_id: account.id)
    message = TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: -100123,
      td_message_id: 300_000_000_222,
      td_sender_id: 42,
      message_at: Time.at(1_700_000_100),
      message_id: 222,
      text: "delete me"
    )
    update = Struct.new(:original_type, :raw).new(
      "updateDeleteMessages",
      {
        "chat_id" => -100123,
        "message_ids" => [ 300_000_000_222 ],
        "from_cache" => false,
        "is_permanent" => true
      }
    )
    session.define_singleton_method(:create_message_history!) do |**|
      raise ActiveRecord::RecordInvalid, TelegramMessageHistory.new
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      session.send(:handle_unsupported_update, update)
    end

    message.reload
    assert_nil message.deleted_at
    assert_nil message.edited_at
    assert_equal "delete me", message.text
    assert_equal 0, TelegramMessageHistory.where(event_type: "deleted").count
  end

  test "unsupported updateMessagePoll upserts poll snapshot rows without writing message history" do
    account = create_account
    session = build_session(account_id: account.id)
    first_update = Struct.new(:original_type, :raw).new(
      "updateMessagePoll",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "poll" => {
          "id" => "poll_123",
          "question" => "Pick a letter",
          "is_anonymous" => false,
          "allows_multiple_answers" => true,
          "total_voter_count" => 7,
          "is_closed" => false,
          "options" => [
            {
              "text" => "A",
              "voter_count" => 3,
              "is_chosen" => false,
              "is_correct" => nil
            },
            {
              "text" => "B",
              "voter_count" => 4,
              "is_chosen" => true,
              "is_correct" => nil
            }
          ]
        }
      }
    )

    assert_difference("TelegramPoll.count", 1) do
      assert_difference("TelegramPollOption.count", 2) do
        assert_difference("TelegramAccountPollState.count", 1) do
          assert_no_difference("TelegramMessageHistory.count") do
            session.send(:handle_unsupported_update, first_update)
          end
        end
      end
    end

    poll = TelegramPoll.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 456)
    assert_equal "poll_123", poll.poll_id
    assert_equal "Pick a letter", poll.question
    assert_equal false, poll.is_anonymous
    assert_equal true, poll.allows_multiple_answers
    assert_equal 7, poll.total_voter_count
    assert_equal false, poll.is_closed
    assert_equal "poll_123", poll.raw_payload["id"]

    options = poll.telegram_poll_options.order(:option_index).to_a
    assert_equal 2, options.size
    assert_equal [ "A", "B" ], options.map(&:text)
    assert_equal [ 3, 4 ], options.map(&:voter_count)
    assert_equal [ false, true ], options.map(&:is_chosen)

    state = TelegramAccountPollState.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 456)
    assert_equal "poll_123", state.poll_id
    assert_equal true, state.has_voted
    assert_equal [ 1 ], state.chosen_option_indexes
    assert_equal "poll_123", state.raw_payload.dig("poll", "id")
    assert_not_nil state.snapshot_at

    second_update = Struct.new(:original_type, :raw).new(
      "updateMessagePoll",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "poll" => {
          "id" => "poll_123",
          "question" => "Pick a better letter",
          "is_anonymous" => true,
          "allows_multiple_answers" => false,
          "total_voter_count" => 9,
          "is_closed" => true,
          "options" => [
            {
              "text" => "A",
              "voter_count" => 5,
              "is_chosen" => true,
              "is_correct" => false
            },
            {
              "text" => "B",
              "voter_count" => 4,
              "is_chosen" => false,
              "is_correct" => true
            }
          ]
        }
      }
    )

    assert_no_difference("TelegramPoll.count") do
      assert_no_difference("TelegramPollOption.count") do
        assert_no_difference("TelegramAccountPollState.count") do
          assert_no_difference("TelegramMessageHistory.count") do
            session.send(:handle_unsupported_update, second_update)
          end
        end
      end
    end

    poll.reload
    assert_equal "Pick a better letter", poll.question
    assert_equal true, poll.is_anonymous
    assert_equal false, poll.allows_multiple_answers
    assert_equal 9, poll.total_voter_count
    assert_equal true, poll.is_closed

    options = poll.telegram_poll_options.order(:option_index).to_a
    assert_equal [ 5, 4 ], options.map(&:voter_count)
    assert_equal [ true, false ], options.map(&:is_chosen)
    assert_equal [ false, true ], options.map(&:is_correct)

    state.reload
    assert_equal true, state.has_voted
    assert_equal [ 0 ], state.chosen_option_indexes
    assert_equal "Pick a better letter", state.raw_payload.dig("poll", "question")
  end

  test "unsupported updateMessagePoll safely ignores invalid payloads" do
    account = create_account
    session = build_session(account_id: account.id)
    invalid_updates = [
      Struct.new(:original_type, :raw).new("updateMessagePoll", nil),
      Struct.new(:original_type, :raw).new(
        "updateMessagePoll",
        {
          "chat_id" => -100123,
          "message_id" => 300_000_000_456
        }
      ),
      Struct.new(:original_type, :raw).new(
        "updateMessagePoll",
        {
          "chat_id" => -100123,
          "message_id" => 0,
          "poll" => { "id" => "poll_123" }
        }
      ),
      Struct.new(:original_type, :raw).new(
        "updateMessagePoll",
        {
          "chat_id" => -100123,
          "message_id" => 300_000_000_456,
          "poll" => { "question" => "missing id" }
        }
      )
    ]

    assert_no_difference("TelegramPoll.count") do
      assert_no_difference("TelegramPollOption.count") do
        assert_no_difference("TelegramAccountPollState.count") do
          assert_no_difference("TelegramMessageHistory.count") do
            invalid_updates.each do |update|
              session.send(:handle_unsupported_update, update)
            end
          end
        end
      end
    end
  end

  test "unsupported updateMessagePoll ignores malformed options payload without changing snapshot" do
    account = create_account
    session = build_session(account_id: account.id)
    initial_update = Struct.new(:original_type, :raw).new(
      "updateMessagePoll",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "poll" => {
          "id" => "poll_123",
          "question" => "Initial question",
          "is_anonymous" => false,
          "allows_multiple_answers" => true,
          "total_voter_count" => 7,
          "is_closed" => false,
          "options" => [
            {
              "text" => "A",
              "voter_count" => 3,
              "is_chosen" => false
            },
            {
              "text" => "B",
              "voter_count" => 4,
              "is_chosen" => true
            }
          ]
        }
      }
    )
    session.send(:handle_unsupported_update, initial_update)

    poll = TelegramPoll.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 456)
    state = TelegramAccountPollState.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 456)
    baseline_poll_updated_at = poll.updated_at
    baseline_state_updated_at = state.updated_at
    baseline_option_snapshot = poll.telegram_poll_options.order(:option_index).map { |option| [ option.text, option.voter_count, option.is_chosen ] }

    malformed_update = Struct.new(:original_type, :raw).new(
      "updateMessagePoll",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "poll" => {
          "id" => "poll_123",
          "question" => "Broken question",
          "is_anonymous" => true,
          "allows_multiple_answers" => false,
          "total_voter_count" => 99,
          "is_closed" => true,
          "options" => [
            {
              "text" => "A",
              "voter_count" => 5,
              "is_chosen" => true
            },
            {
              "voter_count" => 4,
              "is_chosen" => false
            }
          ]
        }
      }
    )

    assert_no_difference("TelegramPoll.count") do
      assert_no_difference("TelegramPollOption.count") do
        assert_no_difference("TelegramAccountPollState.count") do
          assert_no_difference("TelegramMessageHistory.count") do
            session.send(:handle_unsupported_update, malformed_update)
          end
        end
      end
    end

    poll.reload
    state.reload
    assert_equal "Initial question", poll.question
    assert_equal false, poll.is_anonymous
    assert_equal true, poll.allows_multiple_answers
    assert_equal 7, poll.total_voter_count
    assert_equal false, poll.is_closed
    assert_equal baseline_poll_updated_at, poll.updated_at
    assert_equal baseline_state_updated_at, state.updated_at
    assert_equal true, state.has_voted
    assert_equal [ 1 ], state.chosen_option_indexes
    assert_equal baseline_option_snapshot, poll.telegram_poll_options.order(:option_index).map { |option| [ option.text, option.voter_count, option.is_chosen ] }
  end

  test "unsupported updateMessagePoll rolls back snapshot when option upsert fails" do
    account = create_account
    session = build_session(account_id: account.id)
    update = Struct.new(:original_type, :raw).new(
      "updateMessagePoll",
      {
        "chat_id" => -100123,
        "message_id" => 300_000_000_456,
        "poll" => {
          "id" => "poll_123",
          "question" => "Rollback me",
          "is_anonymous" => false,
          "allows_multiple_answers" => true,
          "total_voter_count" => 7,
          "is_closed" => false,
          "options" => [
            {
              "text" => "A",
              "voter_count" => 3,
              "is_chosen" => false
            },
            {
              "text" => "B",
              "voter_count" => 4,
              "is_chosen" => true
            }
          ]
        }
      }
    )

    error = Class.new(StandardError)

    TelegramPollOption.stub(:upsert_all, ->(*) { raise error, "boom" }) do
      assert_raises(error) do
        session.send(:handle_unsupported_update, update)
      end
    end

    assert_equal 0, TelegramPoll.where(telegram_account_id: account.id).count
    assert_equal 0, TelegramPollOption.count
    assert_equal 0, TelegramAccountPollState.where(telegram_account_id: account.id).count
    assert_equal 0, TelegramMessageHistory.where(telegram_account_id: account.id).count
  end

  test "new poll message stores poll question as text and writes poll snapshot rows" do
    account = create_account
    session = build_session(account_id: account.id)
    session.define_singleton_method(:tracked_chat_id?) { |_chat_id| true }
    session.define_singleton_method(:persist_chat_history_frontier!) { |**| nil }

    message = {
      "id" => 300_000_000_456,
      "chat_id" => -100123,
      "date" => 1_700_000_000,
      "sender_id" => {
        "@type" => "messageSenderUser",
        "user_id" => 42
      },
      "content" => {
        "@type" => "messagePoll",
        "poll" => {
          "id" => "poll_from_new_message",
          "question" => "Pick a letter",
          "is_anonymous" => false,
          "allows_multiple_answers" => true,
          "total_voter_count" => 7,
          "is_closed" => false,
          "options" => [
            {
              "text" => "A",
              "voter_count" => 3,
              "is_chosen" => false
            },
            {
              "text" => "B",
              "voter_count" => 4,
              "is_chosen" => true
            }
          ]
        }
      }
    }

    assert_difference("TelegramMessage.count", 1) do
      assert_difference("TelegramPoll.count", 1) do
        assert_difference("TelegramPollOption.count", 2) do
          assert_difference("TelegramAccountPollState.count", 1) do
            session.send(:handle_new_message, message)
          end
        end
      end
    end

    stored_message = TelegramMessage.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "Pick a letter", stored_message.text

    poll = TelegramPoll.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "poll_from_new_message", poll.poll_id
    assert_equal "Pick a letter", poll.question
    assert_equal [ "A", "B" ], poll.telegram_poll_options.order(:option_index).map(&:text)

    state = TelegramAccountPollState.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal [ 1 ], state.chosen_option_indexes
    assert_equal true, state.has_voted
  end

  test "new poll message persists for chats with existing history even when not watched" do
    account = create_account
    TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: -100123,
      td_message_id: 300_000_000_400,
      td_sender_id: 42,
      message_at: Time.at(1_700_000_000),
      message_id: 400,
      text: "existing message"
    )
    session = build_session(account_id: account.id)
    session.define_singleton_method(:persist_chat_history_frontier!) { |**| nil }

    message = {
      "id" => 300_000_000_456,
      "chat_id" => -100123,
      "date" => 1_700_000_100,
      "sender_id" => {
        "@type" => "messageSenderUser",
        "user_id" => 42
      },
      "content" => {
        "@type" => "messagePoll",
        "poll" => {
          "id" => "poll_for_existing_history",
          "question" => "Recovered poll",
          "is_anonymous" => false,
          "allows_multiple_answers" => false,
          "total_voter_count" => 3,
          "is_closed" => false,
          "options" => [
            {
              "text" => "Yes",
              "voter_count" => 3,
              "is_chosen" => true
            }
          ]
        }
      }
    }

    assert_difference("TelegramPoll.count", 1) do
      assert_difference("TelegramAccountPollState.count", 1) do
        session.send(:handle_new_message, message)
      end
    end

    stored_message = TelegramMessage.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "Recovered poll", stored_message.text
  end

  test "new poll message normalizes nested to_h payloads before persisting poll data" do
    account = create_account
    session = build_session(account_id: account.id)
    session.define_singleton_method(:tracked_chat_id?) { |_chat_id| true }
    session.define_singleton_method(:persist_chat_history_frontier!) { |**| nil }

    option_a = Struct.new(:payload) do
      def to_h
        payload
      end
    end.new(
      {
        text: "A",
        voter_count: 3,
        is_chosen: false
      }
    )
    option_b = Struct.new(:payload) do
      def to_h
        payload
      end
    end.new(
      {
        text: "B",
        voter_count: 4,
        is_chosen: true
      }
    )
    poll = Struct.new(:payload) do
      def to_h
        payload
      end
    end.new(
      {
        id: "poll_from_nested_objects",
        question: "Nested poll",
        is_anonymous: false,
        allows_multiple_answers: true,
        total_voter_count: 7,
        is_closed: false,
        options: [ option_a, option_b ]
      }
    )
    content = Struct.new(:payload) do
      def to_h
        payload
      end
    end.new(
      {
        "@type": "messagePoll",
        poll:
      }
    )
    message = Struct.new(:payload) do
      def to_h
        payload
      end
    end.new(
      {
        id: 300_000_000_456,
        chat_id: -100123,
        date: 1_700_000_000,
        sender_id: {
          "@type": "messageSenderUser",
          user_id: 42
        },
        content:
      }
    )

    assert_difference("TelegramMessage.count", 1) do
      assert_difference("TelegramPoll.count", 1) do
        assert_difference("TelegramPollOption.count", 2) do
          assert_difference("TelegramAccountPollState.count", 1) do
            session.send(:handle_new_message, message)
          end
        end
      end
    end

    stored_message = TelegramMessage.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "Nested poll", stored_message.text

    poll_record = TelegramPoll.find_by!(
      telegram_account_id: account.id,
      td_chat_id: -100123,
      message_id: 456
    )
    assert_equal "poll_from_nested_objects", poll_record.poll_id
    assert_equal "Nested poll", poll_record.question
    assert_equal [ "A", "B" ], poll_record.telegram_poll_options.order(:option_index).map(&:text)
  end

  test "extract_message_text returns poll question for poll messages" do
    session = build_session

    text = session.send(
      :extract_message_text,
      {
        "content" => {
          "@type" => "messagePoll",
          "poll" => {
            "question" => "Poll title"
          }
        }
      }
    )

    assert_equal "Poll title", text
  end

  private

  def build_session(account_id: 1)
    Telegram::TdSession.allocate.tap do |session|
      session.instance_variable_set(:@account_id, account_id)
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

  def create_account
    uuid = SecureRandom.uuid
    TelegramAccount.create!(
      uuid: uuid,
      state: "created",
      database_directory: Rails.root.join("storage", "tdlib", uuid, "db").to_s,
      files_directory: Rails.root.join("storage", "tdlib", uuid, "files").to_s
    )
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
