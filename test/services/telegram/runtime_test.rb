# frozen_string_literal: true

require "test_helper"
require "fileutils"

class TelegramRuntimeTest < ActiveSupport::TestCase
  teardown do
    TelegramAccount.delete_all
  end

  test "cleanup removes stale transient accounts and their tdlib directories" do
    account = create_account(state: "wait_phone_number")
    uuid_root = File.dirname(account.database_directory)

    account.update_columns(created_at: 2.hours.ago, updated_at: 2.hours.ago)

    assert Dir.exist?(account.database_directory)
    assert Dir.exist?(account.files_directory)

    cleaned = Telegram::Runtime.cleanup_stale_transient_accounts!(before: 1.hour.ago)

    assert_equal 1, cleaned
    refute TelegramAccount.exists?(account.id)
    refute Dir.exist?(uuid_root)
  end

  test "delete_account removes owned history and poll rows before removing the account" do
    account = create_account(state: "created")
    uuid_root = File.dirname(account.database_directory)
    create_owned_records(account)

    Telegram::Runtime.delete_account!(account, reason: "manual_purge")

    refute TelegramAccount.exists?(account.id)
    refute TelegramMessageHistory.exists?(telegram_account_id: account.id)
    refute TelegramPoll.exists?(telegram_account_id: account.id)
    refute TelegramAccountPollState.exists?(telegram_account_id: account.id)
    refute TelegramPollOption.joins(:telegram_poll).where(telegram_polls: { telegram_account_id: account.id }).exists?
    refute Dir.exist?(uuid_root)
  end

  test "cleanup keeps stale accounts that already entered login flow" do
    account = create_account(state: "wait_code", phone_number: "+8613800000000")
    uuid_root = File.dirname(account.database_directory)

    account.update_columns(created_at: 2.hours.ago, updated_at: 2.hours.ago)

    cleaned = Telegram::Runtime.cleanup_stale_transient_accounts!(before: 1.hour.ago)

    assert_equal 0, cleaned
    assert TelegramAccount.exists?(account.id)
    assert Dir.exist?(uuid_root)
  ensure
    FileUtils.rm_rf(uuid_root) if uuid_root.present?
  end

  test "sync_enabled_accounts_messages_async schedules watched chat sync for enabled accounts only" do
    enabled_account = create_account(state: "ready", enabled: true)
    create_account(state: "ready", enabled: false)

    sync_calls = []
    fake_session = Object.new
    fake_session.define_singleton_method(:sync_messages_for_watched_chats_async) do |reason:|
      sync_calls << reason
    end

    Telegram::Runtime.stub(:fetch, nil) do
      Telegram::Runtime.stub(:start, fake_session) do
        synced = Telegram::Runtime.sync_enabled_accounts_messages_async!(reason: "recurring")

        assert_equal 1, synced
        assert_equal [ "recurring" ], sync_calls
      end
    end
  ensure
    FileUtils.rm_rf(File.dirname(enabled_account.database_directory)) if enabled_account
  end

  private

  def create_account(state:, **attrs)
    uuid = SecureRandom.uuid
    db_dir = Rails.root.join("storage", "tdlib", uuid, "db")
    files_dir = Rails.root.join("storage", "tdlib", uuid, "files")
    FileUtils.mkdir_p(db_dir)
    FileUtils.mkdir_p(files_dir)

    TelegramAccount.create!(
      {
        uuid: uuid,
        state: state,
        database_directory: db_dir.to_s,
        files_directory: files_dir.to_s
      }.merge(attrs)
    )
  end

  def create_owned_records(account)
    TelegramMessageHistory.create!(
      telegram_account: account,
      td_chat_id: 123,
      message_id: 456,
      event_type: "edited",
      event_at: Time.current,
      payload: {}
    )

    poll = TelegramPoll.create!(
      telegram_account: account,
      td_chat_id: 123,
      message_id: 456,
      poll_id: "poll_123",
      question: "Question?",
      raw_payload: {}
    )

    TelegramPollOption.create!(
      telegram_poll: poll,
      option_index: 0,
      text: "A"
    )

    TelegramAccountPollState.create!(
      telegram_account: account,
      td_chat_id: 123,
      message_id: 456,
      poll_id: "poll_123",
      chosen_option_indexes: [],
      snapshot_at: Time.current,
      raw_payload: {}
    )
  end
end
