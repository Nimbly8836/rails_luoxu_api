# frozen_string_literal: true

module Telegram
  class ChatRefreshJob < ApplicationJob
    queue_as :telegram_sync

    limits_concurrency \
      key: ->(arguments) { arguments[:account_uuid] || arguments["account_uuid"] },
      group: "TelegramSession",
      duration: 30.minutes

    retry_on Telegram::TdSession::InvalidStateError, wait: :polynomially_longer, attempts: 10

    def perform(account_uuid:, chat_id:, refresh_avatar: true, reason: "manual")
      account = TelegramAccount.find_by(uuid: account_uuid)
      return if account.nil? || !account.enabled?

      normalized_chat_id = chat_id.to_i
      return if normalized_chat_id.zero?

      session = Telegram::Runtime.fetch(account.uuid) || Telegram::Runtime.start(account)
      session.refresh_chat(chat_id: normalized_chat_id, refresh_avatar: ActiveModel::Type::Boolean.new.cast(refresh_avatar))
      Rails.logger.info(
        "Chat refresh job for account #{account.uuid} reason=#{reason} chat_id=#{normalized_chat_id}"
      )
    end
  end
end
