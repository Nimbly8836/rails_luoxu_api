# frozen_string_literal: true

class CreateTelegramChats < ActiveRecord::Migration[8.0]
  def change
    create_table :telegram_chats do |t|
      t.references :telegram_account, null: false, foreign_key: true
      t.bigint :td_chat_id, null: false
      t.string :title, null: false
      t.string :chat_type
      t.bigint :avatar_small_file_id
      t.bigint :avatar_big_file_id
      t.string :avatar_small_remote_id
      t.string :avatar_big_remote_id
      t.string :avatar_small_local_path
      t.string :avatar_big_local_path
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :synced_at, null: false

      t.timestamps
    end

    add_index :telegram_chats, :td_chat_id
    add_index :telegram_chats, [:telegram_account_id, :td_chat_id], unique: true
    add_index :telegram_chats, :synced_at
  end
end
