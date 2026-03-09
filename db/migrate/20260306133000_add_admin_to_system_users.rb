# frozen_string_literal: true

class AddAdminToSystemUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :system_users, :admin, :boolean, null: false, default: false
    add_index :system_users, :admin
  end
end
