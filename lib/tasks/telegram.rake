# frozen_string_literal: true

namespace :telegram do
  desc "Backfill poll messages by re-syncing message history for an account. Use ACCOUNT_UUID=... and optional CHAT_IDS=1,2,3 ALL_TRACKED=1"
  task backfill_polls: :environment do
    account_uuid = ENV["ACCOUNT_UUID"].to_s.strip
    raise ArgumentError, "ACCOUNT_UUID is required" if account_uuid.blank?

    result = Telegram::Runtime.backfill_poll_messages!(
      account_uuid: account_uuid,
      chat_ids: ENV["CHAT_IDS"],
      limit_per_chat: ENV["LIMIT_PER_CHAT"],
      wait_seconds: ENV["WAIT_SECONDS"],
      all_tracked: ActiveModel::Type::Boolean.new.cast(ENV["ALL_TRACKED"])
    )

    puts(
      {
        account_uuid: account_uuid,
        target_chat_ids: result[:target_chat_ids],
        chats: result[:chats],
        upserted: result[:upserted],
        failed: result[:failed],
        skipped: result[:skipped],
        reason: result[:reason],
        errors: result[:errors]
      }.compact.inspect
    )
  end
end
