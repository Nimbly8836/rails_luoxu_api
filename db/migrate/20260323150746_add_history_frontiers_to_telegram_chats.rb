# frozen_string_literal: true

class AddHistoryFrontiersToTelegramChats < ActiveRecord::Migration[8.0]
  def up
    add_column :telegram_chats, :loaded_min_message_id, :bigint
    add_column :telegram_chats, :loaded_max_message_id, :bigint
    add_column :telegram_chats, :loaded_min_td_message_id, :bigint
    add_column :telegram_chats, :loaded_max_td_message_id, :bigint

    say_with_time "Backfilling telegram chat history frontiers" do
      execute <<~SQL
        UPDATE telegram_chats chats
        SET loaded_min_message_id = stats.min_message_id,
            loaded_max_message_id = stats.max_message_id,
            loaded_min_td_message_id = stats.min_td_message_id,
            loaded_max_td_message_id = stats.max_td_message_id,
            updated_at = GREATEST(chats.updated_at, CURRENT_TIMESTAMP)
        FROM (
          SELECT telegram_account_id,
                 td_chat_id,
                 MIN(message_id) AS min_message_id,
                 MAX(message_id) AS max_message_id,
                 MIN(td_message_id) AS min_td_message_id,
                 MAX(td_message_id) AS max_td_message_id
          FROM telegram_messages
          GROUP BY telegram_account_id, td_chat_id
        ) stats
        WHERE chats.telegram_account_id = stats.telegram_account_id
          AND chats.td_chat_id = stats.td_chat_id
      SQL
    end
  end

  def down
    remove_column :telegram_chats, :loaded_max_td_message_id
    remove_column :telegram_chats, :loaded_min_td_message_id
    remove_column :telegram_chats, :loaded_max_message_id
    remove_column :telegram_chats, :loaded_min_message_id
  end
end
