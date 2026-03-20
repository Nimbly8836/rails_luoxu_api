# frozen_string_literal: true

module Telegram
  class GroupMemberSyncJob < ApplicationJob
    queue_as :telegram_sync

    limits_concurrency \
      key: ->(arguments) { arguments[:account_uuid] || arguments["account_uuid"] },
      group: "TelegramSession",
      duration: 1.hour

    retry_on Telegram::TdSession::InvalidStateError, wait: :polynomially_longer, attempts: 12

    def perform(account_uuid:, chat_ids:, refresh_avatars: true, reason: "manual", retry_attempt: 0)
      account = TelegramAccount.find_by(uuid: account_uuid)
      return if account.nil? || !account.enabled?

      ids = normalize_chat_ids(chat_ids)
      return if ids.empty?

      session = Telegram::Runtime.fetch(account.uuid) || Telegram::Runtime.start(account)
      sync = session.sync_group_members_for_chats(chat_ids: ids, refresh_avatars: ActiveModel::Type::Boolean.new.cast(refresh_avatars))
      Rails.logger.info(
        "Group member sync job for account #{account.uuid} reason=#{reason} retry_attempt=#{retry_attempt}: #{sync.inspect}"
      )

      failed_chat_ids = failed_chat_ids_from(sync)
      return if failed_chat_ids.empty?

      if retry_attempt.to_i >= max_retry_attempts
        Rails.logger.error(
          "Group member sync job exhausted retries for account #{account.uuid} chats=#{failed_chat_ids.inspect} reason=#{reason}"
        )
        return
      end

      next_retry_attempt = retry_attempt.to_i + 1
      retry_delay_seconds = retry_delay_seconds_for(next_retry_attempt)
      retry_job = self.class.set(wait: retry_delay_seconds.seconds).perform_later(
        account_uuid: account.uuid,
        chat_ids: failed_chat_ids,
        refresh_avatars: refresh_avatars,
        reason: "#{reason}:retry#{next_retry_attempt}",
        retry_attempt: next_retry_attempt
      )
      Rails.logger.warn(
        "Re-enqueued group member sync for account #{account.uuid} chats=#{failed_chat_ids.inspect} " \
        "retry_attempt=#{next_retry_attempt} wait=#{retry_delay_seconds}s job_id=#{retry_job.job_id}"
      )
    end

    private

    def normalize_chat_ids(chat_ids)
      Array(chat_ids).map(&:to_i).select(&:nonzero?).uniq.sort
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

    def retry_delay_seconds_for(retry_attempt)
      base_wait = [ ENV.fetch("TELEGRAM_GROUP_MEMBER_SYNC_JOB_RETRY_BASE_WAIT_SECONDS", "60").to_i, 1 ].max
      max_wait = ENV.fetch("TELEGRAM_GROUP_MEMBER_SYNC_JOB_RETRY_MAX_WAIT_SECONDS", "1800").to_i
      wait_seconds = base_wait * (2**[ retry_attempt - 1, 0 ].max)
      [ wait_seconds, max_wait.positive? ? max_wait : wait_seconds ].min
    end

    def max_retry_attempts
      ENV.fetch("TELEGRAM_GROUP_MEMBER_SYNC_JOB_RETRY_ATTEMPTS", "8").to_i.clamp(1, 100)
    end
  end
end
