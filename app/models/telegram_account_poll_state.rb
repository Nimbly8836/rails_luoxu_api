# frozen_string_literal: true

class TelegramAccountPollState < ApplicationRecord
  belongs_to :telegram_account, inverse_of: :telegram_account_poll_states

  validates :td_chat_id, :message_id, :poll_id, :snapshot_at, presence: true
end
