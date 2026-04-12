# frozen_string_literal: true

class TelegramMessage < ApplicationRecord
  belongs_to :telegram_account
  has_one :telegram_poll, foreign_key: :message_id, primary_key: :message_id

  validates :td_chat_id, :message_id, :message_at, presence: true
end
