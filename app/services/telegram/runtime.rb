# frozen_string_literal: true

require "fileutils"

module Telegram
  class Runtime
    class << self
      def boot!
        return if @booted
        return unless telegram_accounts_table_exists?

        @booted = true
        cleanup_stale_transient_accounts!
        TelegramAccount.where(enabled: true).find_each do |account|
          session = start(account)
          session.boot_recovery_sync_async!
        rescue StandardError => e
          Rails.logger.error("Failed to boot Telegram account #{account.uuid}: #{e.message}")
        end
      end

      def create_account!(use_test_dc: false)
        uuid = SecureRandom.uuid
        account = TelegramAccount.create!(
          uuid:,
          state: "created",
          use_test_dc:,
          database_directory: db_dir(uuid),
          files_directory: files_dir(uuid)
        )
        start(account)
      rescue StandardError
        destroy_account!(account, reason: "create_account_failed", force: true) if account
        raise
      end

      def start(account)
        mutex.synchronize do
          return sessions[account.uuid] if sessions.key?(account.uuid)
        end

        FileUtils.mkdir_p(account.database_directory)
        FileUtils.mkdir_p(account.files_directory)

        session = TdSession.new(account:)
        mutex.synchronize { sessions[account.uuid] = session }
        session
      rescue StandardError
        destroy_account!(account, reason: "start_failed", force: true) if account&.auto_cleanup_candidate?
        raise
      end

      def fetch(uuid)
        mutex.synchronize { sessions[uuid] }
      end

      def stop(uuid)
        session = mutex.synchronize { sessions.delete(uuid) }
        session&.dispose
      end

      def cleanup_stale_transient_accounts!(before: stale_transient_cutoff_time)
        return 0 unless telegram_accounts_table_exists?

        cleaned = 0
        TelegramAccount.where(state: TelegramAccount::AUTO_CLEANUP_STATES)
                       .where("updated_at < ?", before)
                       .find_each do |account|
          next unless account.auto_cleanup_candidate?

          destroy_account!(account, reason: "stale_transient_session")
          cleaned += 1
        rescue StandardError => e
          Rails.logger.warn("Failed cleaning transient Telegram account #{account.uuid}: #{e.message}")
        end
        cleaned
      end

      def cleanup_transient_account!(account_id, reason: "transient_session")
        return false unless telegram_accounts_table_exists?

        account = TelegramAccount.find_by(id: account_id)
        return false unless account&.auto_cleanup_candidate?

        destroy_account!(account, reason:)
        true
      end

      def sync_enabled_accounts_messages_async!(reason: "recurring")
        return 0 unless telegram_accounts_table_exists?

        synced = 0
        TelegramAccount.where(enabled: true).find_each do |account|
          session = fetch(account.uuid) || start(account)
          session.sync_messages_for_tracked_chats_async(reason:)
          synced += 1
        rescue StandardError => e
          Rails.logger.warn("Failed scheduling watched-chat sync for Telegram account #{account.uuid}: #{e.message}")
        end
        synced
      end

      def backfill_poll_messages!(account_uuid:, chat_ids: nil, limit_per_chat: nil, wait_seconds: nil, all_tracked: false)
        account = TelegramAccount.find_by!(uuid: account_uuid)
        ids = normalize_backfill_chat_ids(chat_ids)
        ids = candidate_backfill_chat_ids_for(account) if ids.empty?

        return {
          chats: 0,
          upserted: 0,
          failed: 0,
          errors: [],
          details: [],
          target_chat_ids: [],
          skipped: true,
          reason: "no_candidate_chats"
        } if ids.empty?

        session = fetch(account.uuid) || start(account)
        result = session.sync_messages_for_chats(
          chat_ids: ids,
          limit_per_chat: normalize_backfill_limit(limit_per_chat),
          wait_seconds: normalize_backfill_wait(wait_seconds),
          repair_existing: true
        )
        result.merge(target_chat_ids: ids)
      end

      def delete_account!(account, reason: "manual_purge")
        destroy_account!(account, reason:, force: true)
      end

      private

      def db_dir(uuid)
        Rails.root.join("storage", "tdlib", uuid, "db").to_s
      end

      def files_dir(uuid)
        Rails.root.join("storage", "tdlib", uuid, "files").to_s
      end

      def sessions
        @sessions ||= {}
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def destroy_account!(account, reason:, force: false)
        return unless account
        return if !force && !TelegramAccount.where(id: account.id).first&.auto_cleanup_candidate?

        stop(account.uuid)
        purge_account_storage!(account)
        TelegramPollOption.joins(:telegram_poll)
                          .where(telegram_polls: { telegram_account_id: account.id })
                          .delete_all
        account.destroy!
        Rails.logger.info("Deleted transient Telegram account #{account.uuid}: #{reason}")
      end

      def purge_account_storage!(account)
        storage_root = Rails.root.join("storage").to_s
        [ account.database_directory, account.files_directory ].each do |path|
          next if path.blank?
          next unless path.start_with?("#{storage_root}/")

          FileUtils.rm_rf(path)
        end

        account_root = File.dirname(account.database_directory.to_s)
        return unless account_root.start_with?("#{storage_root}/")
        return unless Dir.exist?(account_root)
        return unless Dir.empty?(account_root)

        Dir.rmdir(account_root)
      end

      def stale_transient_cutoff_time
        ttl_minutes = ENV.fetch("TELEGRAM_TRANSIENT_SESSION_TTL_MINUTES", "30").to_i
        ttl_minutes = 1 if ttl_minutes < 1
        ttl_minutes.minutes.ago
      end

      def normalize_backfill_chat_ids(chat_ids)
        Array(chat_ids).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?).map(&:to_i).select(&:nonzero?).uniq.sort
      end

      def candidate_backfill_chat_ids_for(account)
        scope = account.telegram_messages
        scope.distinct.order(:td_chat_id).pluck(:td_chat_id).map(&:to_i).select(&:nonzero?)
      end

      def normalize_backfill_limit(limit_per_chat)
        value = limit_per_chat.present? ? limit_per_chat.to_i : nil
        value&.positive? ? value : nil
      end

      def normalize_backfill_wait(wait_seconds)
        return nil unless wait_seconds.present?

        value = wait_seconds.to_f
        value.negative? ? 0.0 : value
      end

      def telegram_accounts_table_exists?
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.data_source_exists?("telegram_accounts")
        end
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
        false
      end
    end
  end
end
