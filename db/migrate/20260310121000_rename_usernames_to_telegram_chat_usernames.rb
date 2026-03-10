# frozen_string_literal: true

class RenameUsernamesToTelegramChatUsernames < ActiveRecord::Migration[8.0]
  def change
    if table_exists?(:usernames)
      rename_table :usernames, :telegram_chat_usernames
    end

    if index_name_exists?(:telegram_chat_usernames, "index_usernames_on_uid_and_group_id") &&
       !index_name_exists?(:telegram_chat_usernames, "index_telegram_chat_usernames_on_uid_and_group_id")
      rename_index :telegram_chat_usernames,
                   "index_usernames_on_uid_and_group_id",
                   "index_telegram_chat_usernames_on_uid_and_group_id"
    end
  end
end
