# frozen_string_literal: true

class TelegramMessage < ApplicationRecord
  belongs_to :telegram_account

  validates :td_chat_id, :message_id, :message_at, presence: true
end
