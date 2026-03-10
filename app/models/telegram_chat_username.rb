# frozen_string_literal: true

class TelegramChatUsername < ApplicationRecord
  self.table_name = "telegram_chat_usernames"

  validates :uid, :group_id, :name, :last_seen, presence: true
  validates :uid, numericality: { only_integer: true }
  validates :group_id, numericality: { only_integer: true }
  validates :avatar_small_file_id, numericality: { only_integer: true }, allow_nil: true
end
