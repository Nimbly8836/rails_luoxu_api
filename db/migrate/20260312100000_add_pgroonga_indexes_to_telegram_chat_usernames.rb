# frozen_string_literal: true

class AddPgroongaIndexesToTelegramChatUsernames < ActiveRecord::Migration[8.0]
  def up
    add_index :telegram_chat_usernames,
              :name,
              using: :pgroonga,
              name: "telegram_chat_usernames_name_idx" unless index_exists?(:telegram_chat_usernames, :name,
                                                                            name: "telegram_chat_usernames_name_idx")

    add_index :telegram_chat_usernames,
              :username,
              using: :pgroonga,
              name: "telegram_chat_usernames_username_idx" unless index_exists?(:telegram_chat_usernames, :username,
                                                                                name: "telegram_chat_usernames_username_idx")
  end

  def down
    remove_index :telegram_chat_usernames, name: "telegram_chat_usernames_name_idx" if index_exists?(:telegram_chat_usernames,
                                                                                                       :name,
                                                                                                       name: "telegram_chat_usernames_name_idx")
    remove_index :telegram_chat_usernames,
                 name: "telegram_chat_usernames_username_idx" if index_exists?(:telegram_chat_usernames,
                                                                                :username,
                                                                                name: "telegram_chat_usernames_username_idx")
  end
end
