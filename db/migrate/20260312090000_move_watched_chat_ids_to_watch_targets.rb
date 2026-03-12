# frozen_string_literal: true

class MoveWatchedChatIdsToWatchTargets < ActiveRecord::Migration[8.0]
  def up
    create_table :telegram_account_watch_targets do |t|
      t.references :telegram_account, null: false, foreign_key: true
      t.bigint :td_chat_id, null: false
      t.timestamps
    end
    add_index :telegram_account_watch_targets, [:telegram_account_id, :td_chat_id], unique: true,
              name: "index_telegram_account_watch_targets_on_account_and_chat"
    add_index :telegram_account_watch_targets, :td_chat_id

    execute <<~SQL.squish
      INSERT INTO telegram_account_watch_targets (telegram_account_id, td_chat_id, created_at, updated_at)
      SELECT p.telegram_account_id, value::bigint, NOW(), NOW()
      FROM telegram_account_profiles p,
           LATERAL jsonb_array_elements_text(COALESCE(p.watched_chat_ids, '[]'::jsonb)) AS value
      ON CONFLICT (telegram_account_id, td_chat_id) DO NOTHING
    SQL

    remove_column :telegram_account_profiles, :watched_chat_ids, :jsonb
  end

  def down
    add_column :telegram_account_profiles, :watched_chat_ids, :jsonb, null: false, default: []

    execute <<~SQL.squish
      UPDATE telegram_account_profiles p
      SET watched_chat_ids = COALESCE(src.chat_ids, '[]'::jsonb)
      FROM (
        SELECT telegram_account_id, jsonb_agg(td_chat_id ORDER BY td_chat_id) AS chat_ids
        FROM telegram_account_watch_targets
        GROUP BY telegram_account_id
      ) src
      WHERE p.telegram_account_id = src.telegram_account_id
    SQL

    drop_table :telegram_account_watch_targets
  end
end
