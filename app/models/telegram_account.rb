# frozen_string_literal: true

class TelegramAccount < ApplicationRecord
  has_one :profile, class_name: "TelegramAccountProfile", dependent: :destroy
  has_many :telegram_chats, dependent: :destroy
  has_many :telegram_messages, dependent: :delete_all

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
