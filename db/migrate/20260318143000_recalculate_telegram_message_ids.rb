# frozen_string_literal: true

class RecalculateTelegramMessageIds < ActiveRecord::Migration[8.0]
  CHANNEL_TDLIB_MESSAGE_ID_BASE = 300_000_000_000
  CHANNEL_TDLIB_MESSAGE_ID_MAX = 400_000_000_000
  TDLIB_MESSAGE_ID_SHIFT = 20
  TDLIB_MESSAGE_ID_UNIT = 1 << TDLIB_MESSAGE_ID_SHIFT

  def up
    return unless column_exists?(:telegram_messages, :td_message_id)
    return unless column_exists?(:telegram_messages, :message_id)

    execute <<~SQL.squish
      UPDATE telegram_messages
      SET message_id = CASE
        WHEN td_message_id > 0 AND MOD(td_message_id, #{TDLIB_MESSAGE_ID_UNIT}) = 0
          THEN (td_message_id >> #{TDLIB_MESSAGE_ID_SHIFT})
        WHEN td_message_id >= #{CHANNEL_TDLIB_MESSAGE_ID_BASE}
          AND td_message_id < #{CHANNEL_TDLIB_MESSAGE_ID_MAX}
          THEN td_message_id - #{CHANNEL_TDLIB_MESSAGE_ID_BASE}
        WHEN td_message_id > 0
          THEN (td_message_id >> #{TDLIB_MESSAGE_ID_SHIFT})
        ELSE NULL
      END
    SQL
  end

  def down
    # irreversible data correction
  end
end
