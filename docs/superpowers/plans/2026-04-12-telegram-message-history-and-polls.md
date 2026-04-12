# Telegram Message History And Polls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add message history tracking for edited/deleted messages, keep `telegram_messages` as latest state with soft delete, and expose poll data directly in message search responses.

**Architecture:** Extend the current TDLib update pipeline in `Telegram::TdSession` so `updateMessageContent` and `updateDeleteMessages` write `telegram_message_histories`, while poll data is normalized into dedicated poll tables keyed by account/chat/message. Keep query read-path in `Api::MeController#search_messages` by joining precomputed poll snapshots and filtering soft-deleted rows by default.

**Tech Stack:** Ruby on Rails 8, ActiveRecord migrations/upsert, Minitest, TDLib update handlers.

---

### Task 1: Add Schema For Histories, Soft Delete, And Poll Tables

**Files:**
- Create: `db/migrate/20260412090000_add_history_and_poll_tables_for_telegram_messages.rb`
- Modify: `db/schema.rb`
- Test: `test/models/telegram_message_history_test.rb`

- [ ] **Step 1: Write the failing model test for history + poll constraints**

```ruby
# test/models/telegram_message_history_test.rb
require "test_helper"

class TelegramMessageHistoryTest < ActiveSupport::TestCase
  test "validates edited/deleted event types" do
    account = TelegramAccount.create!(uuid: SecureRandom.uuid, state: "ready", database_directory: "tmp/db", files_directory: "tmp/files")

    history = TelegramMessageHistory.new(
      telegram_account: account,
      td_chat_id: -100123,
      message_id: 1,
      event_type: "new",
      event_at: Time.current,
      payload: {}
    )

    assert_not history.valid?
    assert_includes history.errors[:event_type], "is not included in the list"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/telegram_message_history_test.rb`
Expected: FAIL with `uninitialized constant TelegramMessageHistory`.

- [ ] **Step 3: Add migration for all required columns/tables/indexes**

```ruby
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

    add_index :telegram_message_histories,
              %i[telegram_account_id td_chat_id message_id event_at],
              name: "index_telegram_message_histories_on_account_chat_message_time"
    add_index :telegram_message_histories, %i[event_type event_at]

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

    add_index :telegram_polls, %i[telegram_account_id td_chat_id message_id], unique: true,
              name: "index_telegram_polls_on_account_chat_message"
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

    add_index :telegram_poll_options, %i[telegram_poll_id option_index], unique: true,
              name: "index_telegram_poll_options_on_poll_and_option"

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

    add_index :telegram_account_poll_states, %i[telegram_account_id td_chat_id message_id], unique: true,
              name: "index_telegram_account_poll_states_on_account_chat_message"
  end
end
```

- [ ] **Step 4: Run migration + tests**

Run: `bin/rails db:migrate && bin/rails test test/models/telegram_message_history_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260412090000_add_history_and_poll_tables_for_telegram_messages.rb db/schema.rb test/models/telegram_message_history_test.rb
git commit -m "feat: add telegram message history and poll schema"
```

### Task 2: Add ActiveRecord Models And Associations

**Files:**
- Create: `app/models/telegram_message_history.rb`
- Create: `app/models/telegram_poll.rb`
- Create: `app/models/telegram_poll_option.rb`
- Create: `app/models/telegram_account_poll_state.rb`
- Modify: `app/models/telegram_message.rb`
- Modify: `app/models/telegram_account.rb`
- Test: `test/models/telegram_poll_test.rb`

- [ ] **Step 1: Write failing association test**

```ruby
# test/models/telegram_poll_test.rb
require "test_helper"

class TelegramPollTest < ActiveSupport::TestCase
  test "belongs to account and has options" do
    account = TelegramAccount.create!(uuid: SecureRandom.uuid, state: "ready", database_directory: "tmp/db", files_directory: "tmp/files")
    poll = TelegramPoll.create!(telegram_account: account, td_chat_id: -100123, message_id: 77, poll_id: "p-1")

    TelegramPollOption.create!(telegram_poll: poll, option_index: 0, text: "A")

    assert_equal account.id, poll.telegram_account_id
    assert_equal 1, poll.telegram_poll_options.count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/telegram_poll_test.rb`
Expected: FAIL with `uninitialized constant TelegramPoll`.

- [ ] **Step 3: Implement models and associations**

```ruby
# app/models/telegram_message_history.rb
class TelegramMessageHistory < ApplicationRecord
  EVENT_TYPES = %w[edited deleted].freeze

  belongs_to :telegram_account

  validates :td_chat_id, :message_id, :event_at, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES }
end
```

```ruby
# app/models/telegram_poll.rb
class TelegramPoll < ApplicationRecord
  belongs_to :telegram_account
  has_many :telegram_poll_options, dependent: :delete_all

  validates :td_chat_id, :message_id, :poll_id, presence: true
end
```

```ruby
# app/models/telegram_poll_option.rb
class TelegramPollOption < ApplicationRecord
  belongs_to :telegram_poll

  validates :option_index, presence: true
end
```

```ruby
# app/models/telegram_account_poll_state.rb
class TelegramAccountPollState < ApplicationRecord
  belongs_to :telegram_account

  validates :td_chat_id, :message_id, :poll_id, :snapshot_at, presence: true
end
```

```ruby
# app/models/telegram_message.rb
class TelegramMessage < ApplicationRecord
  belongs_to :telegram_account
  has_one :telegram_poll, ->(msg) {
    where(telegram_account_id: msg.telegram_account_id, td_chat_id: msg.td_chat_id, message_id: msg.message_id)
  }, primary_key: :message_id, foreign_key: :message_id

  validates :td_chat_id, :message_id, :message_at, presence: true
end
```

```ruby
# app/models/telegram_account.rb
has_many :telegram_message_histories, dependent: :delete_all
has_many :telegram_polls, dependent: :delete_all
has_many :telegram_account_poll_states, dependent: :delete_all
```

- [ ] **Step 4: Run focused model tests**

Run: `bin/rails test test/models/telegram_message_history_test.rb test/models/telegram_poll_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/telegram_message_history.rb app/models/telegram_poll.rb app/models/telegram_poll_option.rb app/models/telegram_account_poll_state.rb app/models/telegram_message.rb app/models/telegram_account.rb test/models/telegram_poll_test.rb
git commit -m "feat: add telegram history and poll models"
```

### Task 3: Implement TdSession Edited/Deleted History Writes

**Files:**
- Modify: `app/services/telegram/td_session.rb`
- Modify: `test/services/telegram/td_session_test.rb`

- [ ] **Step 1: Write failing tests for content update and delete update**

```ruby
# in test/services/telegram/td_session_test.rb

test "unsupported updateMessageContent updates message and writes history" do
  session = build_session
  account = TelegramAccount.find_by!(uuid: "test-session")
  TelegramMessage.create!(telegram_account: account, td_chat_id: -100123, td_message_id: 300000000077, message_id: 77, message_at: Time.current, text: "before")

  update = Struct.new(:original_type, :raw).new("updateMessageContent", {
    "chat_id" => -100123,
    "message_id" => 300000000077,
    "new_content" => { "@type" => "messageText", "text" => { "text" => "after" } }
  })

  session.send(:handle_unsupported_update, update)

  msg = TelegramMessage.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 77)
  assert_equal "after", msg.text
  assert_not_nil msg.edited_at
  assert_equal "edited", TelegramMessageHistory.last.event_type
end
```

```ruby
test "unsupported updateDeleteMessages soft deletes and writes histories" do
  session = build_session
  account = TelegramAccount.find_by!(uuid: "test-session")
  TelegramMessage.create!(telegram_account: account, td_chat_id: -100123, td_message_id: 300000000078, message_id: 78, message_at: Time.current, text: "bye")

  update = Struct.new(:original_type, :raw).new("updateDeleteMessages", {
    "chat_id" => -100123,
    "message_ids" => [300000000078],
    "is_permanent" => true
  })

  session.send(:handle_unsupported_update, update)

  msg = TelegramMessage.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 78)
  assert_not_nil msg.deleted_at
  assert_equal "deleted", TelegramMessageHistory.last.event_type
end
```

- [ ] **Step 2: Run test to verify RED**

Run: `bin/rails test test/services/telegram/td_session_test.rb -n "/updateMessageContent|updateDeleteMessages/"`
Expected: FAIL because handlers are missing.

- [ ] **Step 3: Implement minimal handler methods and history insert**

```ruby
# in app/services/telegram/td_session.rb, inside handle_unsupported_update case
when "updateMessageContent"
  handle_message_content_update(raw)
when "updateDeleteMessages"
  handle_delete_messages_update(raw)
```

```ruby
# helper methods in TdSession

def handle_message_content_update(raw)
  td_chat_id = raw["chat_id"].to_i
  td_message_id = raw["message_id"].to_i
  return if td_chat_id.zero? || td_message_id <= 0

  message_id = decode_message_id_from_td(td_message_id)
  message = TelegramMessage.find_by(telegram_account_id: @account_id, td_chat_id:, message_id:)
  return if message.nil?

  before_text = message.text
  after_text = extract_message_text({ "content" => raw["new_content"] })
  message.update!(text: after_text, edited_at: Time.current)

  write_message_history!(
    td_chat_id:,
    td_message_id:,
    message_id:,
    event_type: "edited",
    payload: { before: { text: before_text }, after: { text: after_text } }
  )
end

def handle_delete_messages_update(raw)
  td_chat_id = raw["chat_id"].to_i
  td_ids = Array(raw["message_ids"]).map(&:to_i).select(&:positive?)
  return if td_chat_id.zero? || td_ids.empty?

  message_ids = td_ids.map { |id| decode_message_id_from_td(id) }.compact
  now = Time.current
  TelegramMessage.where(telegram_account_id: @account_id, td_chat_id:, message_id: message_ids).update_all(deleted_at: now)

  message_ids.zip(td_ids).each do |message_id, td_message_id|
    write_message_history!(
      td_chat_id:,
      td_message_id:,
      message_id:,
      event_type: "deleted",
      payload: { is_permanent: raw["is_permanent"] == true }
    )
  end
end

def write_message_history!(td_chat_id:, td_message_id:, message_id:, event_type:, payload:)
  TelegramMessageHistory.create!(
    telegram_account_id: @account_id,
    td_chat_id: td_chat_id,
    td_message_id: td_message_id,
    message_id: message_id,
    event_type: event_type,
    event_at: Time.current,
    payload: payload
  )
end
```

- [ ] **Step 4: Run tests to verify GREEN**

Run: `bin/rails test test/services/telegram/td_session_test.rb -n "/updateMessageContent|updateDeleteMessages/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/telegram/td_session.rb test/services/telegram/td_session_test.rb
git commit -m "feat: handle edited and deleted message histories"
```

### Task 4: Implement TdSession Poll Upsert Path

**Files:**
- Modify: `app/services/telegram/td_session.rb`
- Modify: `test/services/telegram/td_session_test.rb`

- [ ] **Step 1: Write failing poll update test**

```ruby
test "unsupported updateMessagePoll upserts poll tables without writing history" do
  session = build_session
  account = TelegramAccount.find_by!(uuid: "test-session")

  update = Struct.new(:original_type, :raw).new("updateMessagePoll", {
    "chat_id" => -100123,
    "message_id" => 300000000090,
    "poll" => {
      "id" => "poll-90",
      "question" => "Lunch?",
      "is_anonymous" => false,
      "allows_multiple_answers" => true,
      "total_voter_count" => 3,
      "is_closed" => false,
      "options" => [
        { "text" => "A", "voter_count" => 1, "is_chosen" => true },
        { "text" => "B", "voter_count" => 2, "is_chosen" => false }
      ]
    }
  })

  session.send(:handle_unsupported_update, update)

  poll = TelegramPoll.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 90)
  assert_equal "Lunch?", poll.question
  assert_equal 2, poll.telegram_poll_options.count
  state = TelegramAccountPollState.find_by!(telegram_account_id: account.id, td_chat_id: -100123, message_id: 90)
  assert_equal true, state.has_voted
  assert_equal [0], state.chosen_option_indexes
  assert_equal 0, TelegramMessageHistory.where(message_id: 90).count
end
```

- [ ] **Step 2: Run test to verify RED**

Run: `bin/rails test test/services/telegram/td_session_test.rb -n "/updateMessagePoll/"`
Expected: FAIL because handler/upsert logic missing.

- [ ] **Step 3: Implement poll parsing + upsert helpers and case branch**

```ruby
# in handle_unsupported_update
when "updateMessagePoll"
  handle_message_poll_update(raw)
```

```ruby
# helper skeleton

def handle_message_poll_update(raw)
  td_chat_id = raw["chat_id"].to_i
  td_message_id = raw["message_id"].to_i
  poll_raw = raw["poll"].is_a?(Hash) ? raw["poll"] : nil
  return if td_chat_id.zero? || td_message_id <= 0 || poll_raw.nil?

  message_id = decode_message_id_from_td(td_message_id)
  now = Time.current

  TelegramPoll.upsert_all([...], unique_by: :index_telegram_polls_on_account_chat_message)
  poll = TelegramPoll.find_by!(telegram_account_id: @account_id, td_chat_id:, message_id:)

  TelegramPollOption.upsert_all([...], unique_by: :index_telegram_poll_options_on_poll_and_option)
  TelegramAccountPollState.upsert_all([...], unique_by: :index_telegram_account_poll_states_on_account_chat_message)
end
```

- [ ] **Step 4: Run test to verify GREEN**

Run: `bin/rails test test/services/telegram/td_session_test.rb -n "/updateMessagePoll/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/telegram/td_session.rb test/services/telegram/td_session_test.rb
git commit -m "feat: persist telegram poll snapshots by account"
```

### Task 5: Extend Message Search API For Soft Delete And Poll Payload

**Files:**
- Modify: `app/controllers/api/me_controller.rb`
- Create: `test/controllers/api/me_controller_test.rb`

- [ ] **Step 1: Write failing API tests**

```ruby
# test/controllers/api/me_controller_test.rb
require "test_helper"

class Api::MeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = SystemUser.create!(username: "u1", password: "secret123", password_confirmation: "secret123", active: true, admin: false)
    @account = TelegramAccount.create!(uuid: SecureRandom.uuid, state: "ready", database_directory: "tmp/db", files_directory: "tmp/files")
    SystemUserChatAccess.create!(system_user: @user, td_chat_id: -100123)

    @message = TelegramMessage.create!(telegram_account: @account, td_chat_id: -100123, td_message_id: 300000000090, message_id: 90, message_at: Time.current, text: "poll")
    poll = TelegramPoll.create!(telegram_account: @account, td_chat_id: -100123, message_id: 90, poll_id: "poll-90", question: "Lunch?")
    TelegramPollOption.create!(telegram_poll: poll, option_index: 0, text: "A", voter_count: 1, is_chosen: true)
    TelegramAccountPollState.create!(telegram_account: @account, td_chat_id: -100123, message_id: 90, poll_id: "poll-90", has_voted: true, chosen_option_indexes: [0], snapshot_at: Time.current)
  end

  test "search messages excludes soft deleted by default" do
    @message.update!(deleted_at: Time.current)

    get "/api/me/search/messages", params: { q: "poll" }, headers: { "Authorization" => "Bearer #{@user.api_token}" }

    assert_response :success
    assert_equal 0, response.parsed_body["items"].size
  end

  test "search messages includes poll payload" do
    get "/api/me/search/messages", params: { q: "poll" }, headers: { "Authorization" => "Bearer #{@user.api_token}" }

    assert_response :success
    poll = response.parsed_body.fetch("items").first.fetch("poll")
    assert_equal "Lunch?", poll["question"]
    assert_equal true, poll["account_state"]["has_voted"]
  end
end
```

- [ ] **Step 2: Run test to verify RED**

Run: `bin/rails test test/controllers/api/me_controller_test.rb`
Expected: FAIL because API does not filter deleted rows and does not emit poll payload.

- [ ] **Step 3: Implement API behavior**

```ruby
# app/controllers/api/me_controller.rb (inside search_messages)
include_deleted = ActiveModel::Type::Boolean.new.cast(params[:include_deleted])
scope = TelegramMessage.where(td_chat_id: permitted_ids)
scope = scope.where(deleted_at: nil) unless include_deleted
```

```ruby
# preload poll/state maps and merge in serialize_message
polls = TelegramPoll.where(telegram_account_id: messages.map(&:telegram_account_id), td_chat_id: messages.map(&:td_chat_id), message_id: messages.map(&:message_id))
poll_map = polls.index_by { |p| [p.telegram_account_id, p.td_chat_id, p.message_id] }
option_map = TelegramPollOption.where(telegram_poll_id: polls.map(&:id)).group_by(&:telegram_poll_id)
state_map = TelegramAccountPollState.where(telegram_account_id: messages.map(&:telegram_account_id), td_chat_id: messages.map(&:td_chat_id), message_id: messages.map(&:message_id)).index_by { |s| [s.telegram_account_id, s.td_chat_id, s.message_id] }
```

```ruby
# serialized message poll field shape
poll: serialize_poll_payload(message, poll_map:, option_map:, state_map:)
```

- [ ] **Step 4: Run tests to verify GREEN**

Run: `bin/rails test test/controllers/api/me_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/me_controller.rb test/controllers/api/me_controller_test.rb
git commit -m "feat: expose poll payload and soft-delete filtering in message search"
```

### Task 6: Full Verification And Cleanup

**Files:**
- Modify: `test/services/telegram/td_session_test.rb` (if fixture leakage fixes needed)
- Modify: `test/controllers/api/me_controller_test.rb` (if deterministic ordering assertions needed)

- [ ] **Step 1: Run targeted suites for changed behavior**

Run: `bin/rails test test/services/telegram/td_session_test.rb test/controllers/api/me_controller_test.rb test/models/telegram_message_history_test.rb test/models/telegram_poll_test.rb`
Expected: all PASS.

- [ ] **Step 2: Run broader regression suite already present for message sync path**

Run: `bin/rails test test/jobs/telegram/message_sync_job_test.rb test/services/telegram/runtime_test.rb`
Expected: PASS, no regressions.

- [ ] **Step 3: Run lint/format checks if project uses them (optional if configured)**

Run: `bin/rails runner 'puts "ok"'`
Expected: `ok` (sanity boot check).

- [ ] **Step 4: Final commit for any follow-up adjustments**

```bash
git add app/services/telegram/td_session.rb app/controllers/api/me_controller.rb test/services/telegram/td_session_test.rb test/controllers/api/me_controller_test.rb
git commit -m "test: stabilize telegram history and poll coverage"
```

- [ ] **Step 5: Produce implementation summary linked to acceptance criteria**

Checklist:
- Edited/deleted histories persisted to `telegram_message_histories` only.
- `telegram_messages` represents latest state with soft delete.
- Poll tables persist per-account snapshots.
- `/api/me/search/messages` returns poll payload directly and filters deleted rows by default.
