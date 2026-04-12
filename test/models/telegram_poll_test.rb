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

  test "message poll lookup stays scoped by account and chat" do
    account = build_account
    poll_one = build_poll(account: account, td_chat_id: 111, message_id: 456, poll_id: "poll_one")
    poll_two = build_poll(account: account, td_chat_id: 222, message_id: 456, poll_id: "poll_two")
    poll_one.save!
    poll_two.save!

    TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: 111,
      td_message_id: 111_456,
      message_id: 456,
      message_at: Time.current
    )
    TelegramMessage.create!(
      telegram_account: account,
      td_chat_id: 222,
      td_message_id: 222_456,
      message_id: 456,
      message_at: Time.current
    )

    message_one = TelegramMessage.find_by!(telegram_account: account, td_chat_id: 111, message_id: 456)
    message_two = TelegramMessage.find_by!(telegram_account: account, td_chat_id: 222, message_id: 456)

    assert_equal poll_one, message_one.telegram_poll
    assert_equal poll_two, message_two.telegram_poll
  end

  test "destroying an account destroys polls before poll options" do
    account = build_account
    poll = build_poll(account: account)
    poll.save!

    option = TelegramPollOption.create!(
      telegram_poll: poll,
      option_index: 0,
      text: "Option A"
    )

    account.destroy!

    refute TelegramPoll.exists?(poll.id)
    refute TelegramPollOption.exists?(option.id)
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
