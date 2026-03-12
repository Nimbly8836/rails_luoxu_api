# frozen_string_literal: true

class TelegramAccountWatchTarget < ApplicationRecord
  belongs_to :telegram_account

  validates :td_chat_id, presence: true, uniqueness: { scope: :telegram_account_id }
end
