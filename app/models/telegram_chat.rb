# frozen_string_literal: true

class TelegramChat < ApplicationRecord
  belongs_to :telegram_account

  validates :td_chat_id, presence: true
  validates :title, presence: true
  validates :synced_at, presence: true
  validates :td_chat_id, uniqueness: { scope: :telegram_account_id }
end
