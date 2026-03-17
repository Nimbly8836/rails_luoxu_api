# frozen_string_literal: true

class DropTdMessageIdFromTelegramMessages < ActiveRecord::Migration[8.0]
  def up
    if index_exists?(:telegram_messages, [ :telegram_account_id, :td_chat_id, :td_message_id ],
                     name: "index_telegram_messages_on_account_chat_message")
      remove_index :telegram_messages, name: "index_telegram_messages_on_account_chat_message"
    end

    add_index :telegram_messages, [ :telegram_account_id, :td_chat_id, :message_id ],
              unique: true, name: "index_telegram_messages_on_account_chat_message_id"

    change_column_null :telegram_messages, :message_id, false
    remove_column :telegram_messages, :td_message_id, :bigint
  end

  def down
    add_column :telegram_messages, :td_message_id, :bigint
    execute <<~SQL.squish
      UPDATE telegram_messages
      SET td_message_id = message_id + 300000000000
      WHERE message_id IS NOT NULL
    SQL

    remove_index :telegram_messages, name: "index_telegram_messages_on_account_chat_message_id"
    add_index :telegram_messages, [ :telegram_account_id, :td_chat_id, :td_message_id ],
              unique: true, name: "index_telegram_messages_on_account_chat_message"
    change_column_null :telegram_messages, :td_message_id, false
  end
end
