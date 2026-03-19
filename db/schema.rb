# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_03_19_121000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgroonga"

  create_table "system_user_chat_accesses", force: :cascade do |t|
    t.bigint "system_user_id", null: false
    t.bigint "td_chat_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["system_user_id", "td_chat_id"], name: "index_system_user_chat_accesses_on_user_id_and_td_chat_id", unique: true
    t.index ["system_user_id"], name: "index_system_user_chat_accesses_on_system_user_id"
    t.index ["td_chat_id"], name: "index_system_user_chat_accesses_on_td_chat_id"
  end

  create_table "system_users", force: :cascade do |t|
    t.string "password_digest", null: false
    t.string "api_token", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "admin", default: false, null: false
    t.string "username", null: false
    t.index ["admin"], name: "index_system_users_on_admin"
    t.index ["api_token"], name: "index_system_users_on_api_token", unique: true
    t.index ["username"], name: "index_system_users_on_username", unique: true
  end

  create_table "telegram_account_profiles", force: :cascade do |t|
    t.bigint "telegram_account_id", null: false
    t.bigint "td_user_id"
    t.string "username"
    t.string "first_name"
    t.string "last_name"
    t.string "phone_number"
    t.string "language_code"
    t.boolean "is_verified"
    t.boolean "is_premium"
    t.boolean "is_support"
    t.boolean "is_scam"
    t.boolean "is_fake"
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["td_user_id"], name: "index_telegram_account_profiles_on_td_user_id"
    t.index ["telegram_account_id"], name: "index_telegram_account_profiles_on_telegram_account_id", unique: true
  end

  create_table "telegram_account_watch_targets", force: :cascade do |t|
    t.bigint "telegram_account_id", null: false
    t.bigint "td_chat_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["td_chat_id"], name: "index_telegram_account_watch_targets_on_td_chat_id"
    t.index ["telegram_account_id", "td_chat_id"], name: "index_telegram_account_watch_targets_on_account_and_chat", unique: true
    t.index ["telegram_account_id"], name: "index_telegram_account_watch_targets_on_telegram_account_id"
  end

  create_table "telegram_accounts", force: :cascade do |t|
    t.string "uuid", null: false
    t.string "state", default: "created", null: false
    t.string "phone_number"
    t.bigint "td_user_id"
    t.string "username"
    t.string "first_name"
    t.string "last_name"
    t.jsonb "me_payload", default: {}, null: false
    t.text "last_error"
    t.boolean "use_test_dc", default: false, null: false
    t.boolean "enabled", default: true, null: false
    t.string "database_directory", null: false
    t.string "files_directory", null: false
    t.datetime "connected_at"
    t.datetime "last_state_at"
    t.datetime "disabled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "known_chat_count"
    t.index ["enabled"], name: "index_telegram_accounts_on_enabled"
    t.index ["state"], name: "index_telegram_accounts_on_state"
    t.index ["uuid"], name: "index_telegram_accounts_on_uuid", unique: true
  end

  create_table "telegram_chat_usernames", force: :cascade do |t|
    t.bigint "uid", null: false
    t.bigint "group_id", null: false
    t.text "name", null: false
    t.datetime "last_seen", null: false
    t.string "username"
    t.bigint "avatar_small_file_id"
    t.binary "avatar_small_data"
    t.string "avatar_small_content_type"
    t.datetime "avatar_small_fetched_at"
    t.index ["name", "username"], name: "usernames_idx", using: :pgroonga
    t.index ["name"], name: "telegram_chat_usernames_name_idx", using: :pgroonga
    t.index ["uid", "group_id"], name: "index_telegram_chat_usernames_on_uid_and_group_id", unique: true
    t.index ["username"], name: "telegram_chat_usernames_username_idx", using: :pgroonga
  end

  create_table "telegram_chats", force: :cascade do |t|
    t.bigint "telegram_account_id", null: false
    t.bigint "td_chat_id", null: false
    t.string "title", null: false
    t.string "chat_type"
    t.bigint "avatar_small_file_id"
    t.bigint "avatar_big_file_id"
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "synced_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.binary "avatar_small_data"
    t.string "avatar_small_content_type"
    t.datetime "avatar_small_fetched_at"
    t.index ["synced_at"], name: "index_telegram_chats_on_synced_at"
    t.index ["td_chat_id"], name: "index_telegram_chats_on_td_chat_id"
    t.index ["telegram_account_id", "td_chat_id"], name: "index_telegram_chats_on_telegram_account_id_and_td_chat_id", unique: true
    t.index ["telegram_account_id"], name: "index_telegram_chats_on_telegram_account_id"
  end

  create_table "telegram_messages", force: :cascade do |t|
    t.bigint "telegram_account_id", null: false
    t.bigint "td_chat_id", null: false
    t.bigint "td_message_id", null: false
    t.bigint "td_sender_id"
    t.datetime "message_at", null: false
    t.text "text"
    t.string "sender_name"
    t.bigint "message_id", null: false
    t.index ["message_at"], name: "index_telegram_messages_on_message_at"
    t.index ["td_chat_id", "message_id"], name: "index_telegram_messages_on_td_chat_id_and_message_id"
    t.index ["td_chat_id"], name: "index_telegram_messages_on_td_chat_id"
    t.index ["telegram_account_id", "td_chat_id", "td_message_id"], name: "index_telegram_messages_on_account_chat_message", unique: true
    t.index ["telegram_account_id"], name: "index_telegram_messages_on_telegram_account_id"
    t.index ["text"], name: "message_idx", using: :pgroonga
  end

  add_foreign_key "system_user_chat_accesses", "system_users"
  add_foreign_key "telegram_account_profiles", "telegram_accounts"
  add_foreign_key "telegram_account_watch_targets", "telegram_accounts"
  add_foreign_key "telegram_chats", "telegram_accounts"
  add_foreign_key "telegram_messages", "telegram_accounts"
end
