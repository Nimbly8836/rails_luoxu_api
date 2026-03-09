# frozen_string_literal: true

class AddSenderNameAndRemoveRawPayloadFromTelegramMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :telegram_messages, :sender_name, :string
    remove_column :telegram_messages, :raw_payload, :jsonb
  end
end
