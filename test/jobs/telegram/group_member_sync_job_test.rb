# frozen_string_literal: true

require "test_helper"

class TelegramGroupMemberSyncJobTest < ActiveSupport::TestCase
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
    TelegramAccount.delete_all
  end

  test "perform re enqueues failed chats with longer waits" do
    account = create_account
    calls = []
    session = Object.new
    session.define_singleton_method(:sync_group_members_for_chats) do |chat_ids:, refresh_avatars:|
      calls << [ chat_ids, refresh_avatars ]
      {
        failed: 1,
        errors: [ "chat 2: Timeout error" ],
        details: [ { chat_id: 2, error: "Timeout error" } ]
      }
    end

    with_env(
      "TELEGRAM_GROUP_MEMBER_SYNC_JOB_RETRY_BASE_WAIT_SECONDS" => "60",
      "TELEGRAM_GROUP_MEMBER_SYNC_JOB_RETRY_MAX_WAIT_SECONDS" => "1800"
    ) do
      with_runtime_session(account, session) do
        Telegram::GroupMemberSyncJob.perform_now(
          account_uuid: account.uuid,
          chat_ids: [ 2, 1 ],
          refresh_avatars: true,
          reason: "manual",
          retry_attempt: 0
        )
      end
    end

    assert_equal [ [ [ 1, 2 ], true ] ], calls
    assert_equal 1, enqueued_jobs.size

    job = enqueued_jobs.last
    assert_equal Telegram::GroupMemberSyncJob, job[:job]
    args = job[:args].first
    assert_equal account.uuid, args["account_uuid"]
    assert_equal [ 2 ], args["chat_ids"]
    assert_equal true, args["refresh_avatars"]
    assert_equal "manual:retry1", args["reason"]
    assert_equal 1, args["retry_attempt"]
    assert_in_delta 60.seconds.from_now.to_f, job[:at], 3.0
  end

  private

  def create_account
    TelegramAccount.create!(
      uuid: SecureRandom.uuid,
      state: "ready",
      database_directory: Rails.root.join("tmp", "tdlib-test-db").to_s,
      files_directory: Rails.root.join("tmp", "tdlib-test-files").to_s
    )
  end

  def with_runtime_session(account, session)
    runtime_singleton = class << Telegram::Runtime; self; end
    fetch_backup = :__telegram_group_member_sync_job_test_original_fetch
    start_backup = :__telegram_group_member_sync_job_test_original_start

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
    original.each do |key, value|
      value.equal?(sentinel) ? ENV.delete(key) : ENV[key] = value
    end
  end
end
