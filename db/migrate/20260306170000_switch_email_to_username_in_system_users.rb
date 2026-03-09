# frozen_string_literal: true

class SwitchEmailToUsernameInSystemUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :system_users, :username, :string

    # backfill from email
    execute <<~SQL
      UPDATE system_users SET username = email WHERE username IS NULL OR username = ''
    SQL

    # ensure non-null usernames
    execute <<~SQL
      UPDATE system_users SET username = CONCAT('user_', id) WHERE username IS NULL OR username = ''
    SQL

    change_column_null :system_users, :username, false
    add_index :system_users, :username, unique: true

    remove_index :system_users, :email if index_exists?(:system_users, :email)
    remove_column :system_users, :email
  end

  def down
    add_column :system_users, :email, :string, null: true
    execute <<~SQL
      UPDATE system_users SET email = username WHERE email IS NULL OR email = ''
    SQL
    change_column_null :system_users, :email, false
    add_index :system_users, :email, unique: true

    remove_index :system_users, :username if index_exists?(:system_users, :username)
    remove_column :system_users, :username
  end
end
