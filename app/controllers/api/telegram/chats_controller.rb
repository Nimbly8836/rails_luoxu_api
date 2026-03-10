# frozen_string_literal: true

require "base64"

module Api
  module Telegram
    class ChatsController < ApplicationController
      before_action :authenticate_system_user!
      before_action :authenticate_admin!
      def index
        name = params[:name].to_s.strip
        page = params[:page].to_i
        page = 1 if page < 1
        per_page = (params[:per_page] || params[:limit] || 20).to_i.clamp(1, 200)
        offset = (page - 1) * per_page

        scope = TelegramChat.all
        scope = scope.where("title ILIKE ?", "%#{name}%") if name.present?

        total = scope.select(:td_chat_id).distinct.count
        td_chat_ids = scope.select(:td_chat_id).distinct.order(:td_chat_id).offset(offset).limit(per_page).pluck(:td_chat_id)
        counts = scope.where(td_chat_id: td_chat_ids).group(:td_chat_id).count

        rows = TelegramChat.includes(:telegram_account).where(td_chat_id: td_chat_ids).order(:td_chat_id, :telegram_account_id)
        grouped = rows.group_by(&:td_chat_id)

        items = td_chat_ids.filter_map do |chat_id|
          entries = grouped[chat_id]
          next if entries.blank?

          serialize_default_chat(entries.first, counts[chat_id] || entries.size)
        end

        render json: {
          page:,
          per_page:,
          total:,
          items:
        }
      end

      private

      def serialize_default_chat(chat, source_count)
        {
          td_chat_id: chat.td_chat_id,
          title: chat.title,
          chat_type: chat.chat_type,
          avatar_small_content_type: chat.avatar_small_content_type,
          avatar_small_base64: base64_blob(chat.avatar_small_data),
          source_session_id: chat.telegram_account.uuid,
          source_count: source_count,
          synced_at: chat.synced_at
        }
      end

      def base64_blob(blob)
        return nil if blob.blank?

        Base64.strict_encode64(blob)
      end
    end
  end
end
