# frozen_string_literal: true

require "fileutils"

module Telegram
  class Runtime
    class << self
      def boot!
        return if @booted
        return unless telegram_accounts_table_exists?

        @booted = true
        TelegramAccount.where(enabled: true).find_each do |account|
          start(account)
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
      end

      def fetch(uuid)
        mutex.synchronize { sessions[uuid] }
      end

      def stop(uuid)
        session = mutex.synchronize { sessions.delete(uuid) }
        session&.dispose
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
