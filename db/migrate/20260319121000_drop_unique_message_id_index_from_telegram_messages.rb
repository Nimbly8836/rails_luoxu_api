# frozen_string_literal: true

class DropUniqueMessageIdIndexFromTelegramMessages < ActiveRecord::Migration[8.0]
  def up
    remove_index :telegram_messages, name: "index_telegram_messages_on_account_chat_message_id" if
      index_exists?(:telegram_messages, [ :telegram_account_id, :td_chat_id, :message_id ],
                    name: "index_telegram_messages_on_account_chat_message_id")
  end

  def down
    add_index :telegram_messages, [ :telegram_account_id, :td_chat_id, :message_id ],
              unique: true, name: "index_telegram_messages_on_account_chat_message_id" unless
      index_exists?(:telegram_messages, [ :telegram_account_id, :td_chat_id, :message_id ],
                    name: "index_telegram_messages_on_account_chat_message_id")
  end
end
