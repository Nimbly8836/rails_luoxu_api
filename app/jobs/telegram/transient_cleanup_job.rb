# frozen_string_literal: true

module Telegram
  class TransientCleanupJob < ApplicationJob
    queue_as :telegram_maintenance

    def perform(account_id:, reason: "transient_session")
      Telegram::Runtime.cleanup_transient_account!(account_id, reason:)
    end
  end
end
