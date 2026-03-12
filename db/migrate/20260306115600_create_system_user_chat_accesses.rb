# frozen_string_literal: true

class CreateSystemUserChatAccesses < ActiveRecord::Migration[8.0]
  def change
    create_table :system_user_chat_accesses do |t|
      t.references :system_user, null: false, foreign_key: true
      t.bigint :td_chat_id, null: false

      t.timestamps
    end

    add_index :system_user_chat_accesses, [ :system_user_id, :td_chat_id ], unique: true,
              name: "index_system_user_chat_accesses_on_user_id_and_td_chat_id"
    add_index :system_user_chat_accesses, :td_chat_id
  end
end
