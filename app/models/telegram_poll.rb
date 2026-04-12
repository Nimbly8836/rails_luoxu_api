# frozen_string_literal: true

class TelegramPoll < ApplicationRecord
  belongs_to :telegram_account, inverse_of: :telegram_polls
  has_many :telegram_poll_options, dependent: :delete_all, inverse_of: :telegram_poll

  validates :td_chat_id, :message_id, :poll_id, presence: true
end
