# frozen_string_literal: true

module Api
  module Telegram
    class ChatsController < ApplicationController
      before_action :authenticate_system_user!
      def index
        rows = TelegramChat.includes(:telegram_account).order(:td_chat_id, :telegram_account_id)
        grouped = rows.group_by(&:td_chat_id)

        render json: grouped.values.map { |entries| serialize_default_chat(entries.first, entries.size) }
      end

      private

      def serialize_default_chat(chat, source_count)
        {
          td_chat_id: chat.td_chat_id,
          title: chat.title,
          chat_type: chat.chat_type,
          avatar_small_remote_id: chat.avatar_small_remote_id,
          avatar_big_remote_id: chat.avatar_big_remote_id,
          source_session_id: chat.telegram_account.uuid,
          source_count: source_count,
          synced_at: chat.synced_at
        }
      end
    end
  end
end
