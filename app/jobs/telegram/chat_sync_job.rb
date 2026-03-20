# frozen_string_literal: true

module Telegram
  class ChatSyncJob < ApplicationJob
    queue_as :telegram_sync

    limits_concurrency \
      key: ->(arguments) { arguments[:account_uuid] || arguments["account_uuid"] },
      group: "TelegramSession",
      duration: 30.minutes

    retry_on Telegram::TdSession::InvalidStateError, wait: :polynomially_longer, attempts: 10

    def perform(account_uuid:, limit: nil, force_full: false)
      account = TelegramAccount.find_by(uuid: account_uuid)
      return if account.nil? || !account.enabled?

      session = Telegram::Runtime.fetch(account.uuid) || Telegram::Runtime.start(account)
      result = session.sync_chats_now(limit:, force_full:)
      Rails.logger.info("Chat sync job for account #{account.uuid}: #{result.inspect}")
    end
  end
end
