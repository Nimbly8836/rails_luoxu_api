# frozen_string_literal: true

require "test_helper"

class TelegramChatRefreshJobTest < ActiveSupport::TestCase
  test "perform refreshes chat through runtime session" do
    account = TelegramAccount.create!(
      uuid: SecureRandom.uuid,
      state: "ready",
      database_directory: Rails.root.join("tmp", "tdlib-test-db").to_s,
      files_directory: Rails.root.join("tmp", "tdlib-test-files").to_s
    )

    calls = []
    session = Object.new
    session.define_singleton_method(:refresh_chat) do |chat_id:, refresh_avatar:|
      calls << [ chat_id, refresh_avatar ]
    end

    with_runtime_session(account, session) do
      Telegram::ChatRefreshJob.perform_now(
        account_uuid: account.uuid,
        chat_id: -100123,
        refresh_avatar: true,
        reason: "manual"
      )
    end

    assert_equal [ [ -100123, true ] ], calls
  ensure
    TelegramAccount.delete_all
  end

  private

  def with_runtime_session(account, session)
    runtime_singleton = class << Telegram::Runtime; self; end
    fetch_backup = :__telegram_chat_refresh_job_test_original_fetch
    start_backup = :__telegram_chat_refresh_job_test_original_start

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
end
