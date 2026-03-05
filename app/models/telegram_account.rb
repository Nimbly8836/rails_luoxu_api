# frozen_string_literal: true

class TelegramAccount < ApplicationRecord
  STATES = %w[
    created
    wait_phone_number
    wait_code
    wait_password
    ready
    closed
    disabled
  ].freeze

  validates :uuid, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validates :database_directory, presence: true
  validates :files_directory, presence: true
end
