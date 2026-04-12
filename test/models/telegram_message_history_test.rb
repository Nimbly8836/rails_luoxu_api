# frozen_string_literal: true

require "test_helper"

class TelegramMessageHistory < ApplicationRecord
  self.table_name = "telegram_message_histories"
end

class TelegramMessageHistoryTest < ActiveSupport::TestCase
  test "allows edited and deleted event types" do
    account = build_account
    edited_history = build_history(account: account, event_type: "edited")
    deleted_history = build_history(account: account, event_type: "deleted")

    assert_predicate edited_history, :valid?
    assert_predicate deleted_history, :valid?
  end

  test "rejects new event type" do
    history = build_history(account: build_account, event_type: "new")

    refute_predicate history, :valid?
    assert_includes history.errors[:event_type], "is not included in the list"
  end

  private

  def build_account
    TelegramAccount.new(
      uuid: SecureRandom.uuid,
      state: "created",
      database_directory: Rails.root.join("storage", "tdlib", SecureRandom.uuid, "db").to_s,
      files_directory: Rails.root.join("storage", "tdlib", SecureRandom.uuid, "files").to_s
    )
  end

  def build_history(account:, event_type:)
    TelegramMessageHistory.new(
      telegram_account: account,
      td_chat_id: 123,
      message_id: 456,
      event_type: event_type,
      event_at: Time.current,
      payload: {}
    )
  end
end
