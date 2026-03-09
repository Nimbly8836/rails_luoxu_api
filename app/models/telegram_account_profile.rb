# frozen_string_literal: true

class TelegramAccountProfile < ApplicationRecord
  belongs_to :telegram_account

  validates :telegram_account_id, uniqueness: true

  def self.all_watched_chat_ids
    pluck(:watched_chat_ids).flatten.compact.map(&:to_i).uniq
  end
end
