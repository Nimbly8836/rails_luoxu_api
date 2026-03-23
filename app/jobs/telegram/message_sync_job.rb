# frozen_string_literal: true

module Telegram
  class MessageSyncJob < ApplicationJob
    queue_as :telegram_sync

    limits_concurrency \
      key: ->(arguments) { arguments[:account_uuid] || arguments["account_uuid"] },
      group: "TelegramSession",
      duration: 2.hours

    retry_on Telegram::TdSession::InvalidStateError, wait: :polynomially_longer, attempts: 15

    def perform(account_uuid:, chat_ids: [], use_watched_chat_ids: false, limit_per_chat: nil, wait_seconds: nil, reason: "manual", retry_attempt: 0)
      account = TelegramAccount.find_by(uuid: account_uuid)
      return if account.nil? || !account.enabled?

      session = Telegram::Runtime.fetch(account.uuid) || Telegram::Runtime.start(account)
      session.invalidate_watched_chat_ids_cache! if session.respond_to?(:invalidate_watched_chat_ids_cache!)

      ids = normalize_chat_ids(chat_ids)
      ids |= session.watched_chat_ids if use_watched_chat_ids && session.respond_to?(:watched_chat_ids)
      if ids.empty?
        Rails.logger.info("Skip message sync job for account #{account.uuid}: no chats")
        return
      end

      normalized_wait_seconds = normalize_wait_seconds(wait_seconds)
      normalized_limit_per_chat = normalize_limit_per_chat(limit_per_chat)
      sync = session.sync_messages_for_chats(
        chat_ids: ids,
        limit_per_chat: normalized_limit_per_chat,
        wait_seconds: normalized_wait_seconds
      )
      Rails.logger.info(
        "Message sync job for account #{account.uuid} reason=#{reason} retry_attempt=#{retry_attempt}: #{sync.inspect}"
      )

      failed_chat_ids = failed_chat_ids_from(sync)
      continuation_chat_ids = continuation_chat_ids_from(sync) - failed_chat_ids
      enqueue_continuation_job(
        account:,
        chat_ids: continuation_chat_ids,
        limit_per_chat: normalized_limit_per_chat,
        wait_seconds: normalized_wait_seconds,
        reason:
      )
      return if failed_chat_ids.empty?

      if retry_attempt.to_i >= max_retry_attempts
        Rails.logger.error(
          "Message sync job exhausted retries for account #{account.uuid} chats=#{failed_chat_ids.inspect} reason=#{reason}"
        )
        return
      end

      next_retry_attempt = retry_attempt.to_i + 1
      retry_delay_seconds = retry_delay_seconds_for(next_retry_attempt)
      next_wait_seconds = next_wait_seconds_for(normalized_wait_seconds)
      retry_job = self.class.set(wait: retry_delay_seconds.seconds).perform_later(
        account_uuid: account.uuid,
        chat_ids: failed_chat_ids,
        use_watched_chat_ids: false,
        limit_per_chat: normalized_limit_per_chat,
        wait_seconds: next_wait_seconds,
        reason: "#{reason}:retry#{next_retry_attempt}",
        retry_attempt: next_retry_attempt
      )
      Rails.logger.warn(
        "Re-enqueued message sync for account #{account.uuid} chats=#{failed_chat_ids.inspect} " \
        "retry_attempt=#{next_retry_attempt} wait=#{retry_delay_seconds}s sync_wait=#{next_wait_seconds}s job_id=#{retry_job.job_id}"
      )
    end

    private

    def normalize_chat_ids(chat_ids)
      Array(chat_ids).map(&:to_i).select(&:nonzero?).uniq.sort
    end

    def normalize_limit_per_chat(limit_per_chat)
      value = limit_per_chat.present? ? limit_per_chat.to_i : nil
      value&.positive? ? value : nil
    end

    def normalize_wait_seconds(wait_seconds)
      seconds = wait_seconds.present? ? wait_seconds.to_f : default_wait_seconds
      seconds.negative? ? 0.0 : seconds
    end

    def continuation_chat_ids_from(sync)
      details = Array(sync[:details] || sync["details"])
      details.filter_map do |detail|
        next unless ActiveModel::Type::Boolean.new.cast(detail[:continuation_required] || detail["continuation_required"])

        chat_id = detail[:chat_id] || detail["chat_id"]
        chat_id.to_i if chat_id.present?
      end.select(&:nonzero?).uniq.sort
    end

    def failed_chat_ids_from(sync)
      details = Array(sync[:details] || sync["details"])
      ids = details.filter_map do |detail|
        error = detail[:error] || detail["error"]
        next if error.blank?

        chat_id = detail[:chat_id] || detail["chat_id"]
        chat_id.to_i if chat_id.present?
      end

      if ids.empty?
        ids = Array(sync[:errors] || sync["errors"]).filter_map do |error|
          error.to_s[/chat\s+(-?\d+):/, 1]&.to_i
        end
      end

      ids.select(&:nonzero?).uniq.sort
    end

    def enqueue_continuation_job(account:, chat_ids:, limit_per_chat:, wait_seconds:, reason:)
      ids = normalize_chat_ids(chat_ids)
      return if ids.empty?

      wait_seconds_for_job = continuation_delay_seconds
      next_reason = reason.to_s.include?(":continue") ? reason.to_s : "#{reason}:continue"
      job = self.class.set(wait: wait_seconds_for_job.seconds).perform_later(
        account_uuid: account.uuid,
        chat_ids: ids,
        use_watched_chat_ids: false,
        limit_per_chat: limit_per_chat,
        wait_seconds: wait_seconds,
        reason: next_reason,
        retry_attempt: 0
      )
      Rails.logger.info(
        "Queued continuation message sync for account #{account.uuid} chats=#{ids.inspect} " \
        "wait=#{wait_seconds_for_job}s sync_wait=#{wait_seconds}s job_id=#{job.job_id}"
      )
    end

    def next_wait_seconds_for(current_wait_seconds)
      base_wait = current_wait_seconds.to_f.positive? ? current_wait_seconds.to_f : default_wait_seconds
      max_wait = ENV.fetch("TELEGRAM_MESSAGE_SYNC_JOB_MAX_WAIT_SECONDS", "60").to_f
      [ base_wait * 2, max_wait.positive? ? max_wait : base_wait * 2 ].min
    end

    def retry_delay_seconds_for(retry_attempt)
      base_wait = [ ENV.fetch("TELEGRAM_MESSAGE_SYNC_JOB_RETRY_BASE_WAIT_SECONDS", "60").to_i, 1 ].max
      max_wait = ENV.fetch("TELEGRAM_MESSAGE_SYNC_JOB_RETRY_MAX_WAIT_SECONDS", "1800").to_i
      wait_seconds = base_wait * (2**[ retry_attempt - 1, 0 ].max)
      [ wait_seconds, max_wait.positive? ? max_wait : wait_seconds ].min
    end

    def max_retry_attempts
      ENV.fetch("TELEGRAM_MESSAGE_SYNC_JOB_RETRY_ATTEMPTS", "12").to_i.clamp(1, 100)
    end

    def continuation_delay_seconds
      ENV.fetch("TELEGRAM_MESSAGE_SYNC_CONTINUATION_WAIT_SECONDS", "1").to_f.clamp(0.0, 60.0)
    end

    def default_wait_seconds
      ENV.fetch("TELEGRAM_MESSAGE_SYNC_WAIT_SECONDS", "0.5").to_f
    end
  end
end
