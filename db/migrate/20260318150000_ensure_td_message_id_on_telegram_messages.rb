# frozen_string_literal: true

class EnsureTdMessageIdOnTelegramMessages < ActiveRecord::Migration[8.0]
  def up
    add_column :telegram_messages, :td_message_id, :bigint unless column_exists?(:telegram_messages, :td_message_id)

    add_index :telegram_messages, [ :telegram_account_id, :td_chat_id, :td_message_id ],
              unique: true, name: "index_telegram_messages_on_account_chat_message" unless
      index_exists?(:telegram_messages, [ :telegram_account_id, :td_chat_id, :td_message_id ],
                    name: "index_telegram_messages_on_account_chat_message")
  end

  def down
    remove_index :telegram_messages, name: "index_telegram_messages_on_account_chat_message" if
      index_exists?(:telegram_messages, [ :telegram_account_id, :td_chat_id, :td_message_id ],
                    name: "index_telegram_messages_on_account_chat_message")

    remove_column :telegram_messages, :td_message_id if column_exists?(:telegram_messages, :td_message_id)
  end
end
