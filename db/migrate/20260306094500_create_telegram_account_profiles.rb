# frozen_string_literal: true

class CreateTelegramAccountProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :telegram_account_profiles do |t|
      t.references :telegram_account, null: false, foreign_key: true, index: { unique: true }

      t.bigint :td_user_id
      t.string :username
      t.string :first_name
      t.string :last_name
      t.string :phone_number
      t.string :language_code
      t.boolean :is_verified
      t.boolean :is_premium
      t.boolean :is_support
      t.boolean :is_scam
      t.boolean :is_fake

      # Group list to watch for this logged-in account. Keep as JSON for flexible future settings.
      t.jsonb :watched_chat_ids, null: false, default: []

      # Full raw payload returned by getMe for troubleshooting and compatibility.
      t.jsonb :raw_payload, null: false, default: {}

      t.timestamps
    end

    add_index :telegram_account_profiles, :td_user_id
  end
end
