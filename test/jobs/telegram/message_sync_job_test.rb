# frozen_string_literal: true

require "test_helper"

class TelegramMessageSyncJobTest < ActiveSupport::TestCase
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
    session = build_session do |chat_ids:, limit_per_chat:, wait_seconds:|
      calls << [ chat_ids, limit_per_chat, wait_seconds ]
      {
        failed: 1,
        errors: [ "chat 2: Timeout error" ],
        details: [ { chat_id: 2, error: "Timeout error" } ]
      }
    end

    with_env(
      "TELEGRAM_MESSAGE_SYNC_JOB_RETRY_BASE_WAIT_SECONDS" => "60",
      "TELEGRAM_MESSAGE_SYNC_JOB_RETRY_MAX_WAIT_SECONDS" => "1800",
      "TELEGRAM_MESSAGE_SYNC_JOB_MAX_WAIT_SECONDS" => "60"
    ) do
      with_runtime_session(account, session) do
        Telegram::MessageSyncJob.perform_now(
          account_uuid: account.uuid,
          chat_ids: [ 2 ],
          limit_per_chat: 20,
          wait_seconds: 5,
          reason: "manual",
          retry_attempt: 0
        )
      end
    end

    assert_equal [ [ [ 2 ], 20, 5.0 ] ], calls
    assert_equal 1, enqueued_jobs.size

    job = enqueued_jobs.last
    assert_equal Telegram::MessageSyncJob, job[:job]
    args = job[:args].first
    assert_equal account.uuid, args["account_uuid"]
    assert_equal [ 2 ], args["chat_ids"]
    assert_equal false, args["use_watched_chat_ids"]
    assert_equal 20, args["limit_per_chat"]
    assert_equal 10.0, args["wait_seconds"]
    assert_equal "manual:retry1", args["reason"]
    assert_equal 1, args["retry_attempt"]
    assert_equal "telegram_sync", job[:queue]
    assert_in_delta 60.seconds.from_now.to_f, job[:at], 3.0
  end

  test "perform uses watched chat ids when requested" do
    account = create_account
    session = build_session(watched_chat_ids: [ 3, 4 ]) do |chat_ids:, **|
      raise "watched chat fan-out should not sync in the parent job"
    end

    with_runtime_session(account, session) do
      Telegram::MessageSyncJob.perform_now(
        account_uuid: account.uuid,
        chat_ids: [],
        use_watched_chat_ids: true,
        limit_per_chat: nil,
        wait_seconds: nil,
        reason: "boot",
        retry_attempt: 0
      )
    end

    assert_equal 2, enqueued_jobs.size
    assert_equal [ [ 3 ], [ 4 ] ], enqueued_jobs.map { |job| job[:args].first["chat_ids"] }
    assert_equal [ "telegram_sync", "telegram_sync" ], enqueued_jobs.map { |job| job[:queue] }
  end

  test "perform fans out explicit multi chat sync into one job per chat" do
    account = create_account
    session = build_session do |chat_ids:, **|
      raise "multi chat fan-out should not sync in the parent job"
    end

    with_runtime_session(account, session) do
      Telegram::MessageSyncJob.perform_now(
        account_uuid: account.uuid,
        chat_ids: [ 3, 1, 3 ],
        use_watched_chat_ids: false,
        limit_per_chat: 20,
        wait_seconds: 5,
        reason: "manual",
        retry_attempt: 0
      )
    end

    assert_equal 2, enqueued_jobs.size
    assert_equal [ [ 1 ], [ 3 ] ], enqueued_jobs.map { |job| job[:args].first["chat_ids"] }
    assert_equal [ "telegram_sync", "telegram_sync" ], enqueued_jobs.map { |job| job[:queue] }
  end

  test "perform enqueues continuation when backfill needs another pass" do
    account = create_account
    calls = []
    session = build_session do |chat_ids:, limit_per_chat:, wait_seconds:|
      calls << [ chat_ids, limit_per_chat, wait_seconds ]
      {
        failed: 0,
        errors: [],
        details: [ { chat_id: 4, continuation_required: true } ]
      }
    end

    with_env("TELEGRAM_MESSAGE_SYNC_CONTINUATION_WAIT_SECONDS" => "1.5") do
      with_runtime_session(account, session) do
        Telegram::MessageSyncJob.perform_now(
          account_uuid: account.uuid,
          chat_ids: [ 4 ],
          limit_per_chat: nil,
          wait_seconds: nil,
          reason: "manual",
          retry_attempt: 0
        )
      end
    end

    assert_equal [ [ [ 4 ], nil, 5.0 ] ], calls
    assert_equal 1, enqueued_jobs.size

    job = enqueued_jobs.last
    assert_equal Telegram::MessageSyncJob, job[:job]
    args = job[:args].first
    assert_equal account.uuid, args["account_uuid"]
    assert_equal [ 4 ], args["chat_ids"]
    assert_equal false, args["use_watched_chat_ids"]
    assert_nil args["limit_per_chat"]
    assert_equal 5.0, args["wait_seconds"]
    assert_equal "manual:continue", args["reason"]
    assert_equal 0, args["retry_attempt"]
    assert_equal "telegram_sync_backfill", job[:queue]
    assert_in_delta 1.5.seconds.from_now.to_f, job[:at], 3.0
  end

  test "perform does not enqueue continuation for failed chats" do
    account = create_account
    session = build_session do |chat_ids:, **|
      {
        failed: 1,
        errors: [ "chat 7: Timeout error" ],
        details: [
          { chat_id: 7, continuation_required: true, error: "Timeout error" }
        ]
      }
    end

    with_env(
      "TELEGRAM_MESSAGE_SYNC_JOB_RETRY_BASE_WAIT_SECONDS" => "60",
      "TELEGRAM_MESSAGE_SYNC_JOB_RETRY_MAX_WAIT_SECONDS" => "1800",
      "TELEGRAM_MESSAGE_SYNC_JOB_MAX_WAIT_SECONDS" => "60"
    ) do
      with_runtime_session(account, session) do
        Telegram::MessageSyncJob.perform_now(
          account_uuid: account.uuid,
          chat_ids: [ 7 ],
          limit_per_chat: nil,
          wait_seconds: nil,
          reason: "manual",
          retry_attempt: 0
        )
      end
    end

    assert_equal 1, enqueued_jobs.size
    args = enqueued_jobs.last[:args].first
    assert_equal [ 7 ], args["chat_ids"]
    assert_equal "manual:retry1", args["reason"]
    assert_equal "telegram_sync", enqueued_jobs.last[:queue]
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

  def build_session(watched_chat_ids: [], &sync_block)
    Object.new.tap do |session|
      session.define_singleton_method(:invalidate_watched_chat_ids_cache!) { nil }
      session.define_singleton_method(:watched_chat_ids) { watched_chat_ids }
      session.define_singleton_method(:sync_messages_for_chats, &sync_block)
    end
  end

  def with_runtime_session(account, session)
    runtime_singleton = class << Telegram::Runtime; self; end
    fetch_backup = :__telegram_message_sync_job_test_original_fetch
    start_backup = :__telegram_message_sync_job_test_original_start

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
