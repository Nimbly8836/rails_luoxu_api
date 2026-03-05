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

ActiveRecord::Schema[8.0].define(version: 2026_03_05_083000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.index ["enabled"], name: "index_telegram_accounts_on_enabled"
    t.index ["state"], name: "index_telegram_accounts_on_state"
    t.index ["uuid"], name: "index_telegram_accounts_on_uuid", unique: true
  end
end
