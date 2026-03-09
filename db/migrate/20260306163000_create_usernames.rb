# frozen_string_literal: true

class CreateUsernames < ActiveRecord::Migration[8.0]
  def change
    create_table :usernames do |t|
      t.bigint :uid, null: false
      t.bigint :group_id, null: false
      t.text :name, null: false
      t.datetime :last_seen, null: false
    end

    add_index :usernames, [:uid, :group_id], unique: true, name: "index_usernames_on_uid_and_group_id"
  end
end
