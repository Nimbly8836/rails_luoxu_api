# frozen_string_literal: true

module Api
  class MeController < ApplicationController
    before_action :authenticate_system_user!

    def chats
      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      rows = TelegramChat.where(td_chat_id: permitted_ids).order(:td_chat_id, :telegram_account_id)
      grouped = rows.group_by(&:td_chat_id)

      render json: grouped.values.map { |entries| serialize_chat(entries.first, entries.size) }
    end

    def search_messages
      query = params.require(:q).to_s.strip
      chat_id = params[:chat_id].to_i if params[:chat_id].present?
      page = params[:page].to_i
      page = 1 if page < 1
      per_page = (params[:per_page] || params[:limit] || 50).to_i.clamp(1, 200)
      offset = (page - 1) * per_page

      permitted_ids = current_system_user.chat_accesses.pluck(:td_chat_id)
      permitted_ids &= [chat_id] if chat_id.present?
      return render json: [] if permitted_ids.empty?

      scope = TelegramMessage.where(td_chat_id: permitted_ids)
      if query.present?
        mode = params[:mode].to_s
        if mode == "regex"
          scope = scope.where("text &~ ?", query)
        else
          scope = scope.where("text &@~ ?", query)
        end
      end

      total = scope.count
      highlight_sql = if query.present?
                        ActiveRecord::Base.send(
                          :sanitize_sql_array,
                          ["pgroonga_highlight_html(text, ARRAY[?]::text[]) AS highlight", query]
                        )
                      else
                        "NULL AS highlight"
                      end
      messages = scope
                 .select("telegram_messages.*", highlight_sql)
                 .order(message_at: :desc)
                 .offset(offset)
                 .limit(per_page)

      render json: {
        page:,
        per_page:,
        total:,
        items: messages.map { |m| serialize_message(m).merge(highlight: m.try(:highlight)) }
      }
    end

    private

    def serialize_chat(chat, source_count)
      {
        td_chat_id: chat.td_chat_id,
        title: chat.title,
        chat_type: chat.chat_type,
        avatar_small_remote_id: chat.avatar_small_remote_id,
        avatar_big_remote_id: chat.avatar_big_remote_id,
        source_session_id: chat.telegram_account.uuid,
        source_count: source_count
      }
    end

    def serialize_message(message)
      {
        td_chat_id: message.td_chat_id,
        td_message_id: message.td_message_id,
        text: message.text,
        sender_id: message.td_sender_id,
        sender_name: message.sender_name,
        message_at: message.message_at
      }
    end
  end
end
