# frozen_string_literal: true

class TelegramMessage < ApplicationRecord
  belongs_to :telegram_account
  has_one :telegram_poll,
          ->(message) { where(telegram_account_id: message.telegram_account_id, td_chat_id: message.td_chat_id) },
          class_name: "TelegramPoll",
          foreign_key: :message_id,
          primary_key: :message_id

  validates :td_chat_id, :message_id, :message_at, presence: true
end
