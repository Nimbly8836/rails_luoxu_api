# frozen_string_literal: true

require "test_helper"

class TelegramTdSessionTest < ActiveSupport::TestCase
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

  private

  def build_session
    Telegram::TdSession.allocate.tap do |session|
      session.instance_variable_set(:@id, "test-session")
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
