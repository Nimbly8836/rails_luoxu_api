# frozen_string_literal: true

class CreateTelegramAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :telegram_accounts do |t|
      t.string :uuid, null: false
      t.string :state, null: false, default: "created"
      t.string :phone_number
      t.bigint :td_user_id
      t.string :username
      t.string :first_name
      t.string :last_name
      t.jsonb :me_payload, null: false, default: {}
      t.text :last_error
      t.boolean :use_test_dc, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.string :database_directory, null: false
      t.string :files_directory, null: false
      t.datetime :connected_at
      t.datetime :last_state_at
      t.datetime :disabled_at

      t.timestamps
    end

    add_index :telegram_accounts, :uuid, unique: true
    add_index :telegram_accounts, :enabled
    add_index :telegram_accounts, :state
  end
end
