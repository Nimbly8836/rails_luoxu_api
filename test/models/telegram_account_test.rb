# frozen_string_literal: true

require "test_helper"

class TelegramAccountTest < ActiveSupport::TestCase
  test "fresh created account is an auto cleanup candidate" do
    account = build_account(state: "created")

    assert_predicate account, :auto_cleanup_candidate?
    refute_predicate account, :login_progressed?
  end

  test "account with phone verification progress is not an auto cleanup candidate" do
    account = build_account(state: "wait_code", phone_number: "+8613800000000")

    refute_predicate account, :auto_cleanup_candidate?
    assert_predicate account, :login_progressed?
  end

  test "account with persisted profile data is not an auto cleanup candidate" do
    account = build_account(state: "closed")
    TelegramAccountProfile.create!(telegram_account: account, phone_number: "+8613800000000")

    refute_predicate account.reload, :auto_cleanup_candidate?
    assert_predicate account, :login_progressed?
  end

  private

  def build_account(state:, **attrs)
    uuid = SecureRandom.uuid
    TelegramAccount.create!(
      {
        uuid: uuid,
        state: state,
        database_directory: Rails.root.join("storage", "tdlib", uuid, "db").to_s,
        files_directory: Rails.root.join("storage", "tdlib", uuid, "files").to_s
      }.merge(attrs)
    )
  end
end
