# frozen_string_literal: true

class TelegramPoll < ApplicationRecord
  belongs_to :telegram_account
  has_many :telegram_poll_options, dependent: :delete_all
end
