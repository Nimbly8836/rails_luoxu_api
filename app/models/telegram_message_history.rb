# frozen_string_literal: true

class TelegramMessageHistory < ApplicationRecord
  EVENT_TYPES = %w[edited deleted].freeze

  belongs_to :telegram_account

  validates :event_type, inclusion: { in: EVENT_TYPES }
end
