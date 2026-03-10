# frozen_string_literal: true

class StoreAvatarFilesAndGroupMemberProfiles < ActiveRecord::Migration[8.0]
  def change
    change_table :telegram_chats, bulk: true do |t|
      t.binary :avatar_small_data
      t.string :avatar_small_content_type
      t.datetime :avatar_small_fetched_at
    end

    change_table :usernames, bulk: true do |t|
      t.string :username
      t.bigint :avatar_small_file_id
      t.binary :avatar_small_data
      t.string :avatar_small_content_type
      t.datetime :avatar_small_fetched_at
    end

    remove_column :telegram_chats, :avatar_small_remote_id, :string
    remove_column :telegram_chats, :avatar_big_remote_id, :string
    remove_column :telegram_chats, :avatar_small_local_path, :string
    remove_column :telegram_chats, :avatar_big_local_path, :string
  end
end
