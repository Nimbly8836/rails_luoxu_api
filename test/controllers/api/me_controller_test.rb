# frozen_string_literal: true

require "test_helper"

module Api
  class MeControllerTest < ActionDispatch::IntegrationTest
    test "search_messages excludes soft deleted rows by default and includes them when requested" do
      user = create_system_user
      account = create_account
      chat_id = 123_456
      SystemUserChatAccess.create!(system_user: user, td_chat_id: chat_id)

      visible_message = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 1001,
        td_sender_id: 2001,
        message_id: 501,
        message_at: Time.current - 1.minute,
        text: "visible message"
      )
      deleted_message = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 1002,
        td_sender_id: 2002,
        message_id: 502,
        message_at: Time.current,
        text: "deleted message",
        deleted_at: Time.current
      )

      get "/api/me/search/messages", params: { q: "", chat_id: chat_id }, headers: auth_headers(user)

      assert_response :success
      response_body = response.parsed_body
      assert_equal 1, response_body["total"]
      assert_equal [ visible_message.message_id ], response_body["items"].map { |item| item["message_id"] }

      get "/api/me/search/messages",
          params: { q: "", chat_id: chat_id, include_deleted: true },
          headers: auth_headers(user)

      assert_response :success
      response_body = response.parsed_body
      assert_equal 2, response_body["total"]
      assert_equal [ deleted_message.message_id, visible_message.message_id ], response_body["items"].map { |item| item["message_id"] }
    end

    test "search_messages filters by message_at range and honors ascending order" do
      user = create_system_user
      account = create_account
      chat_id = 124_456
      SystemUserChatAccess.create!(system_user: user, td_chat_id: chat_id)

      before_range = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 1100,
        td_sender_id: 2100,
        message_id: 510,
        message_at: Time.zone.parse("2026-05-11T02:09:59.999Z"),
        text: "before range"
      )
      first_in_range = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 1101,
        td_sender_id: 2101,
        message_id: 511,
        message_at: Time.zone.parse("2026-05-11T02:10:00.000Z"),
        text: "first in range"
      )
      second_in_range = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 1102,
        td_sender_id: 2102,
        message_id: 512,
        message_at: Time.zone.parse("2026-05-13T02:10:00.000Z"),
        text: "second in range"
      )
      last_in_range = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 1103,
        td_sender_id: 2103,
        message_id: 513,
        message_at: Time.zone.parse("2026-05-17T02:10:59.999Z"),
        text: "last in range"
      )
      after_range = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 1104,
        td_sender_id: 2104,
        message_id: 514,
        message_at: Time.zone.parse("2026-05-17T02:11:00.000Z"),
        text: "after range"
      )

      get "/api/me/search/messages",
          params: {
            q: "",
            chat_id: chat_id,
            start_at: "2026-05-11T02:10:00.000Z",
            end_at: "2026-05-17T02:10:59.999Z",
            order: "asc"
          },
          headers: auth_headers(user)

      assert_response :success
      response_body = response.parsed_body
      assert_equal 3, response_body["total"]
      assert_equal(
        [ first_in_range.message_id, second_in_range.message_id, last_in_range.message_id ],
        response_body["items"].map { |item| item["message_id"] }
      )
      refute_includes response_body["items"].map { |item| item["message_id"] }, before_range.message_id
      refute_includes response_body["items"].map { |item| item["message_id"] }, after_range.message_id
    end

    test "search_messages includes poll payload with options and account state" do
      user = create_system_user
      account = create_account
      chat_id = 654_321
      SystemUserChatAccess.create!(system_user: user, td_chat_id: chat_id)

      message = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 2001,
        td_sender_id: 3001,
        message_id: 601,
        message_at: Time.current,
        text: "poll message"
      )

      poll = TelegramPoll.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        message_id: message.message_id,
        poll_id: "poll_601",
        question: "Pick a letter",
        is_anonymous: false,
        allows_multiple_answers: true,
        total_voter_count: 7,
        is_closed: false,
        raw_payload: {}
      )
      TelegramPollOption.create!(
        telegram_poll: poll,
        option_index: 0,
        text: "A",
        voter_count: 3,
        is_chosen: false,
        is_correct: false
      )
      TelegramPollOption.create!(
        telegram_poll: poll,
        option_index: 1,
        text: "B",
        voter_count: 4,
        is_chosen: true,
        is_correct: true
      )
      TelegramAccountPollState.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        message_id: message.message_id,
        poll_id: poll.poll_id,
        has_voted: true,
        chosen_option_indexes: [ 1 ],
        snapshot_at: Time.current,
        raw_payload: {}
      )

      get "/api/me/search/messages", params: { q: "", chat_id: chat_id }, headers: auth_headers(user)

      assert_response :success
      item = response.parsed_body.fetch("items").first

      assert_equal(
        {
          "question" => "Pick a letter",
          "is_anonymous" => false,
          "allows_multiple_answers" => true,
          "total_voter_count" => 7,
          "is_closed" => false,
          "options" => [
            {
              "option_index" => 0,
              "text" => "A",
              "voter_count" => 3,
              "is_chosen" => false,
              "is_correct" => false
            },
            {
              "option_index" => 1,
              "text" => "B",
              "voter_count" => 4,
              "is_chosen" => true,
              "is_correct" => true
            }
          ],
          "account_state" => {
            "has_voted" => true,
            "chosen_option_indexes" => [ 1 ]
          }
        },
        item["poll"]
      )
    end

    test "search_messages falls back to raw poll payload options when option rows are missing" do
      user = create_system_user
      account = create_account
      chat_id = 765_432
      SystemUserChatAccess.create!(system_user: user, td_chat_id: chat_id)

      message = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 2501,
        td_sender_id: 3501,
        message_id: 651,
        message_at: Time.current,
        text: "raw payload poll message"
      )

      TelegramPoll.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        message_id: message.message_id,
        poll_id: "poll_651",
        question: "Raw fallback poll",
        is_anonymous: true,
        allows_multiple_answers: false,
        total_voter_count: 5,
        is_closed: false,
        raw_payload: {
          "options" => [
            {
              "text" => { "text" => "First" },
              "voter_count" => 2,
              "is_chosen" => false,
              "is_correct" => true
            },
            {
              "text" => "Second"
            }
          ]
        }
      )

      get "/api/me/search/messages", params: { q: "", chat_id: chat_id }, headers: auth_headers(user)

      assert_response :success
      options = response.parsed_body.fetch("items").first.dig("poll", "options")
      assert_equal(
        [
          {
            "option_index" => 0,
            "text" => "First",
            "voter_count" => 2,
            "is_chosen" => false,
            "is_correct" => true
          },
          {
            "option_index" => 1,
            "text" => "Second",
            "voter_count" => 0,
            "is_chosen" => false,
            "is_correct" => nil
          }
        ],
        options
      )
    end

    test "search_messages prefers raw poll options when persisted options are incomplete" do
      user = create_system_user
      account = create_account
      chat_id = 876_543
      SystemUserChatAccess.create!(system_user: user, td_chat_id: chat_id)

      message = TelegramMessage.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        td_message_id: 2601,
        td_sender_id: 3601,
        message_id: 661,
        message_at: Time.current,
        text: "partial poll message"
      )
      poll = TelegramPoll.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        message_id: message.message_id,
        poll_id: "poll_661",
        question: "Partial fallback poll",
        is_anonymous: true,
        allows_multiple_answers: false,
        total_voter_count: 5,
        is_closed: false,
        raw_payload: {
          "options" => [
            { "text" => "First", "voter_count" => 2, "is_chosen" => false },
            { "text" => "Second", "voter_count" => 3, "is_chosen" => true }
          ]
        }
      )
      TelegramPollOption.create!(
        telegram_poll: poll,
        option_index: 0,
        text: "First",
        voter_count: 2,
        is_chosen: false
      )

      get "/api/me/search/messages", params: { q: "", chat_id: chat_id }, headers: auth_headers(user)

      assert_response :success
      options = response.parsed_body.fetch("items").first.dig("poll", "options")
      assert_equal [ "First", "Second" ], options.map { |option| option["text"] }
    end

    test "search_messages loads poll snapshots by exact message tuples" do
      user = create_system_user
      primary_account = create_account
      secondary_account = create_account
      primary_chat_id = 111_111
      secondary_chat_id = 222_222
      SystemUserChatAccess.create!(system_user: user, td_chat_id: primary_chat_id)
      SystemUserChatAccess.create!(system_user: user, td_chat_id: secondary_chat_id)

      first_message = TelegramMessage.create!(
        telegram_account: primary_account,
        td_chat_id: primary_chat_id,
        td_message_id: 3001,
        td_sender_id: 4001,
        message_id: 701,
        message_at: Time.current - 1.minute,
        text: "first poll message"
      )
      second_message = TelegramMessage.create!(
        telegram_account: secondary_account,
        td_chat_id: secondary_chat_id,
        td_message_id: 3002,
        td_sender_id: 4002,
        message_id: 702,
        message_at: Time.current,
        text: "second poll message"
      )

      create_poll_snapshot(
        account: primary_account,
        chat_id: primary_chat_id,
        message_id: first_message.message_id,
        poll_id: "poll_701",
        question: "Primary question"
      )
      create_poll_snapshot(
        account: secondary_account,
        chat_id: secondary_chat_id,
        message_id: second_message.message_id,
        poll_id: "poll_702",
        question: "Secondary question"
      )

      create_poll_snapshot(
        account: primary_account,
        chat_id: secondary_chat_id,
        message_id: first_message.message_id,
        poll_id: "poll_distractor_1",
        question: "Distractor one"
      )
      create_poll_snapshot(
        account: secondary_account,
        chat_id: primary_chat_id,
        message_id: second_message.message_id,
        poll_id: "poll_distractor_2",
        question: "Distractor two"
      )

      poll_queries = capture_sql_queries(/JOIN LATERAL \( SELECT telegram_polls\.id|FROM "telegram_polls"|FROM "telegram_account_poll_states"/) do
        get "/api/me/search/messages", params: { q: "" }, headers: auth_headers(user)
      end

      assert_response :success

      items = response.parsed_body.fetch("items")
      assert_equal [ "Secondary question", "Primary question" ], items.map { |item| item.dig("poll", "question") }

      assert_equal 3, poll_queries.size
      assert_match(/JOIN LATERAL \( SELECT telegram_polls\.id FROM telegram_polls/, poll_queries.first)
      assert_match(/telegram_polls\.td_chat_id = telegram_messages\.td_chat_id/, poll_queries.first)
      assert_match(/telegram_polls\.message_id = telegram_messages\.message_id/, poll_queries.first)
      assert_match(/telegram_polls\.telegram_account_id = telegram_messages\.telegram_account_id/, poll_queries.first)
      assert_match(/"telegram_polls"\."id" IN \(/, poll_queries.second)
      assert_match(/\(\s*telegram_account_id\s*,\s*td_chat_id\s*,\s*message_id\s*\)\s+IN\s+\(\(/, poll_queries.third)
    end

    test "search_messages falls back to same chat message poll snapshot from another account" do
      user = create_system_user
      poll_account = create_account
      message_account = create_account
      chat_id = 333_333
      SystemUserChatAccess.create!(system_user: user, td_chat_id: chat_id)

      TelegramMessage.create!(
        telegram_account: message_account,
        td_chat_id: chat_id,
        td_message_id: 4001,
        td_sender_id: 5001,
        message_id: 801,
        message_at: Time.current,
        text: "shared poll message"
      )
      create_poll_snapshot(
        account: poll_account,
        chat_id: chat_id,
        message_id: 801,
        poll_id: "poll_shared_801",
        question: "Shared poll question"
      )
      get "/api/me/search/messages", params: { q: "", chat_id: chat_id }, headers: auth_headers(user)

      assert_response :success
      poll_payload = response.parsed_body.fetch("items").first.fetch("poll")
      assert_equal "Shared poll question", poll_payload["question"]
      assert_equal(
        {
          "has_voted" => false,
          "chosen_option_indexes" => []
        },
        poll_payload["account_state"]
      )
    end

    private

    def auth_headers(user)
      { "Authorization" => "Bearer #{user.api_token}" }
    end

    def create_system_user
      token = SecureRandom.hex(16)
      SystemUser.create!(
        username: "user_#{token}",
        password: "password123",
        password_confirmation: "password123",
        api_token: token,
        active: true,
        admin: false
      )
    end

    def create_account
      uuid = SecureRandom.uuid
      TelegramAccount.create!(
        uuid: uuid,
        state: "created",
        database_directory: Rails.root.join("tmp", "tdlib", uuid, "db").to_s,
        files_directory: Rails.root.join("tmp", "tdlib", uuid, "files").to_s
      )
    end

    def create_poll_snapshot(account:, chat_id:, message_id:, poll_id:, question:)
      poll = TelegramPoll.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        message_id: message_id,
        poll_id: poll_id,
        question: question,
        is_anonymous: false,
        allows_multiple_answers: false,
        total_voter_count: 1,
        is_closed: false,
        raw_payload: {}
      )
      TelegramPollOption.create!(
        telegram_poll: poll,
        option_index: 0,
        text: "Only option",
        voter_count: 1,
        is_chosen: true
      )
      TelegramAccountPollState.create!(
        telegram_account: account,
        td_chat_id: chat_id,
        message_id: message_id,
        poll_id: poll_id,
        has_voted: true,
        chosen_option_indexes: [ 0 ],
        snapshot_at: Time.current,
        raw_payload: {}
      )
    end

    def capture_sql_queries(pattern)
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        queries << sql if sql.match?(pattern)
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
  end
end
