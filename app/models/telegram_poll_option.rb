# frozen_string_literal: true

class TelegramPollOption < ApplicationRecord
  belongs_to :telegram_poll, inverse_of: :telegram_poll_options

  validates :option_index, presence: true
end
