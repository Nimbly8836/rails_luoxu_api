# frozen_string_literal: true

class DropSenderTypeAndTimestampsFromTelegramMessages < ActiveRecord::Migration[8.0]
  def change
    remove_column :telegram_messages, :sender_type, :string
    remove_column :telegram_messages, :created_at, :datetime
    remove_column :telegram_messages, :updated_at, :datetime
  end
end
