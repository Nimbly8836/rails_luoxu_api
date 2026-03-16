# frozen_string_literal: true

class TelegramAccount < ApplicationRecord
  has_one :profile, class_name: "TelegramAccountProfile", dependent: :destroy
  has_many :telegram_chats, dependent: :destroy
  has_many :telegram_messages, dependent: :delete_all
  has_many :watch_targets, class_name: "TelegramAccountWatchTarget", dependent: :delete_all

  AUTO_CLEANUP_STATES = %w[created wait_phone_number closed].freeze
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

  def auto_cleanup_candidate?
    AUTO_CLEANUP_STATES.include?(state) && !login_progressed?
  end

  def login_progressed?
    return true if state.in?(%w[wait_code wait_password ready disabled])
    return true if phone_number.present? || td_user_id.present?
    return true if username.present? || first_name.present? || last_name.present?
    return true if me_payload.present? && me_payload != {}
    return true if connected_at.present? || known_chat_count.to_i.positive?
    return true if TelegramAccountProfile.exists?(telegram_account_id: id)
    return true if TelegramChat.exists?(telegram_account_id: id)
    return true if TelegramMessage.exists?(telegram_account_id: id)
    return true if TelegramAccountWatchTarget.exists?(telegram_account_id: id)

    false
  end
end
