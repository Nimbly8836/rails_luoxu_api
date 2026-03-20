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
    session.define_singleton_method(:with_td_timeout_retry) do |operation:, chat_id:, from_message_id:, wait_seconds:, &block|
      captured_wait_seconds << [ operation, chat_id, from_message_id, wait_seconds ]
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
    assert_equal [ [ "get_chat_history", 123, 456, 7.5 ] ], captured_wait_seconds
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

  test "sync_messages_for_chats_async enqueues a message sync job" do
    session = build_session

    result = session.sync_messages_for_chats_async(chat_ids: [ 3, 1, 3 ], limit_per_chat: 20, reason: "manual")

    assert_equal true, result[:enqueued]
    assert_equal "enqueued", result[:status]
    assert result[:job_id].present?
    assert_equal [ 1, 3 ], result[:chat_ids]
    assert_equal false, result[:watched_chat_ids]
    assert_equal 5.0, result[:wait_seconds]
    assert_equal 20, result[:limit_per_chat]
    assert_equal 1, enqueued_jobs.size

    job = enqueued_jobs.last
    assert_equal Telegram::MessageSyncJob, job[:job]
    args = job[:args].first
    assert_equal "test-session", args["account_uuid"]
    assert_equal [ 1, 3 ], args["chat_ids"]
    assert_equal false, args["use_watched_chat_ids"]
    assert_equal 20, args["limit_per_chat"]
    assert_equal 5.0, args["wait_seconds"]
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

  private

  def build_session
    Telegram::TdSession.allocate.tap do |session|
      session.instance_variable_set(:@id, "test-session")
      session.instance_variable_set(:@mutex, Mutex.new)
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
