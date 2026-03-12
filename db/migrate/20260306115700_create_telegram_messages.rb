# frozen_string_literal: true

class CreateTelegramMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :telegram_messages do |t|
      t.references :telegram_account, null: false, foreign_key: true
      t.bigint :td_chat_id, null: false
      t.bigint :td_message_id, null: false
      t.bigint :td_sender_id
      t.string :sender_type
      t.datetime :message_at, null: false
      t.text :text
      t.jsonb :raw_payload, null: false, default: {}

      t.timestamps
    end

    add_index :telegram_messages, [ :telegram_account_id, :td_chat_id, :td_message_id ], unique: true,
              name: "index_telegram_messages_on_account_chat_message"
    add_index :telegram_messages, :td_chat_id
    add_index :telegram_messages, :message_at
  end
end
