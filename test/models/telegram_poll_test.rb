# frozen_string_literal: true

require "test_helper"

class TelegramPollTest < ActiveSupport::TestCase
  test "belongs to account and has options" do
    account = build_account
    poll = build_poll(account: account)

    option = TelegramPollOption.new(
      telegram_poll: poll,
      option_index: 0,
      text: "Option A"
    )

    assert_equal account, poll.telegram_account
    assert_includes poll.telegram_poll_options, option
    assert_equal :has_many, TelegramPoll.reflect_on_association(:telegram_poll_options).macro
  end

  test "requires td_chat_id message_id and poll_id" do
    poll = build_poll(
      account: build_account,
      td_chat_id: nil,
      message_id: nil,
      poll_id: nil
    )

    refute_predicate poll, :valid?
    assert_includes poll.errors[:td_chat_id], "can't be blank"
    assert_includes poll.errors[:message_id], "can't be blank"
    assert_includes poll.errors[:poll_id], "can't be blank"
  end

  private

  def build_account
    uuid = SecureRandom.uuid
    TelegramAccount.create!(
      uuid: uuid,
      state: "created",
      database_directory: Rails.root.join("storage", "tdlib", uuid, "db").to_s,
      files_directory: Rails.root.join("storage", "tdlib", uuid, "files").to_s
    )
  end

  def build_poll(account:, td_chat_id: 123, message_id: 456, poll_id: "poll_123")
    TelegramPoll.new(
      telegram_account: account,
      td_chat_id: td_chat_id,
      message_id: message_id,
      poll_id: poll_id,
      question: "Question?",
      raw_payload: {}
    )
  end
end
