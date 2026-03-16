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
        TelegramAccount.where(id: account.id).delete_all
        Rails.logger.info("Deleted transient Telegram account #{account.uuid}: #{reason}")
      end

      def purge_account_storage!(account)
        storage_root = Rails.root.join("storage").to_s
        [account.database_directory, account.files_directory].each do |path|
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
