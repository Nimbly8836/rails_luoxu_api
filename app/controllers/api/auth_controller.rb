# frozen_string_literal: true

module Api
  class AuthController < ApplicationController
    before_action :authenticate_system_user!, only: :register
    before_action :authenticate_admin!, only: :register

    def register
      user = SystemUser.new(
        username: params.require(:username),
        password: params.require(:password),
        password_confirmation: params[:password_confirmation] || params.require(:password),
        admin: ActiveModel::Type::Boolean.new.cast(params[:admin])
      )
      user.save!

      replace_chat_accesses!(user, params[:chat_ids]) if params.key?(:chat_ids)

      render json: auth_payload(user), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def login
      user = SystemUser.find_by(username: params.require(:username))
      if user&.authenticate(params.require(:password)) && user.active?
        render json: auth_payload(user)
      else
        render json: { error: "Invalid username or password" }, status: :unauthorized
      end
    end

    private

    def auth_payload(user)
      {
        user_id: user.id,
        username: user.username,
        admin: user.admin,
        token: user.api_token,
        chat_ids: user.chat_accesses.order(:td_chat_id).pluck(:td_chat_id)
      }
    end

    def replace_chat_accesses!(user, chat_ids)
      ids = Array(chat_ids).map(&:to_i).uniq
      allowed_ids = TelegramAccountProfile.all_watched_chat_ids
      disallowed_ids = ids - allowed_ids
      raise ArgumentError, "chat_ids include unwatched chats: #{disallowed_ids.join(',')}" if disallowed_ids.any?

      user.chat_accesses.delete_all
      rows = ids.map { |chat_id| { system_user_id: user.id, td_chat_id: chat_id, created_at: Time.current, updated_at: Time.current } }
      SystemUserChatAccess.insert_all(rows) if rows.any?
    end
  end
end
