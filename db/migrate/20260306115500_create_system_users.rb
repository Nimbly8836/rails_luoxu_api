# frozen_string_literal: true

class CreateSystemUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :system_users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :api_token, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :system_users, :email, unique: true
    add_index :system_users, :api_token, unique: true
  end
end
