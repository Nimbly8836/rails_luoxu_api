# frozen_string_literal: true

class AddHistoryAndPollTablesForTelegramMessages < ActiveRecord::Migration[8.0]
  def change
    change_table :telegram_messages, bulk: true do |t|
      t.datetime :deleted_at
      t.datetime :edited_at
    end
    add_index :telegram_messages, :deleted_at

    create_table :telegram_message_histories do |t|
      t.references :telegram_account, null: false, foreign_key: true
      t.bigint :td_chat_id, null: false
      t.bigint :message_id, null: false
      t.bigint :td_message_id
      t.string :event_type, null: false
      t.datetime :event_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_check_constraint :telegram_message_histories,
                         "event_type IN ('edited', 'deleted')",
                         name: "check_telegram_message_histories_event_type"

    add_index :telegram_message_histories,
              [ :telegram_account_id, :td_chat_id, :message_id, :event_at ],
              name: "index_telegram_message_histories_on_account_chat_message_time"
    add_index :telegram_message_histories, [ :event_type, :event_at ]

    create_table :telegram_polls do |t|
      t.references :telegram_account, null: false, foreign_key: true
      t.bigint :td_chat_id, null: false
      t.bigint :message_id, null: false
      t.string :poll_id, null: false
      t.text :question
      t.boolean :is_anonymous, null: false, default: true
      t.boolean :allows_multiple_answers, null: false, default: false
      t.integer :total_voter_count, null: false, default: 0
      t.boolean :is_closed, null: false, default: false
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end

    add_index :telegram_polls, [ :telegram_account_id, :td_chat_id, :message_id ],
              unique: true, name: "index_telegram_polls_on_account_chat_message"
    add_index :telegram_polls, :poll_id

    create_table :telegram_poll_options do |t|
      t.references :telegram_poll, null: false, foreign_key: true
      t.integer :option_index, null: false
      t.text :text
      t.integer :voter_count, null: false, default: 0
      t.boolean :is_chosen, null: false, default: false
      t.boolean :is_correct
      t.timestamps
    end

    add_index :telegram_poll_options, [ :telegram_poll_id, :option_index ],
              unique: true, name: "index_telegram_poll_options_on_poll_and_option"

    create_table :telegram_account_poll_states do |t|
      t.references :telegram_account, null: false, foreign_key: true
      t.bigint :td_chat_id, null: false
      t.bigint :message_id, null: false
      t.string :poll_id, null: false
      t.jsonb :chosen_option_indexes, null: false, default: []
      t.boolean :has_voted, null: false, default: false
      t.datetime :snapshot_at, null: false
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end

    add_index :telegram_account_poll_states, [ :telegram_account_id, :td_chat_id, :message_id ],
              unique: true, name: "index_telegram_account_poll_states_on_account_chat_message"
  end
end
