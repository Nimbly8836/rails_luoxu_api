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
        is_chosen: false
      )
      TelegramPollOption.create!(
        telegram_poll: poll,
        option_index: 1,
        text: "B",
        voter_count: 4,
        is_chosen: true
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
              "is_chosen" => false
            },
            {
              "option_index" => 1,
              "text" => "B",
              "voter_count" => 4,
              "is_chosen" => true
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
  end
end
