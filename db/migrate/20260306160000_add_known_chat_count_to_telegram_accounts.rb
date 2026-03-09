# frozen_string_literal: true

class AddKnownChatCountToTelegramAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :telegram_accounts, :known_chat_count, :integer
  end
end
