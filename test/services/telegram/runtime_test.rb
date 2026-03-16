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
end
