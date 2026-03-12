# frozen_string_literal: true

module Api
  class AuthController < ApplicationController
    before_action :authenticate_system_user!, only: %i[register users update_chat_ids]
    before_action :authenticate_admin!, only: %i[register users update_chat_ids]

    def register
      user = SystemUser.new(
        username: params.require(:username),
        password: params.require(:password),
        password_confirmation: params[:password_confirmation] || params.require(:password),
        admin: ActiveModel::Type::Boolean.new.cast(params[:admin])
      )
      user.save!

      replace_chat_accesses!(user, chat_ids_param) if chat_ids_param_provided?

      render json: user_payload(user, include_token: true), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def login
      user = SystemUser.find_by(username: params.require(:username))
      if user&.authenticate(params.require(:password)) && user.active?
        render json: user_payload(user, include_token: true)
      else
        render json: { error: "Invalid username or password" }, status: :unauthorized
      end
    end

    def users
      render json: SystemUser.order(:id).map { |user| user_payload(user, include_token: false) }
    end

    def update_chat_ids
      user = SystemUser.find(params.require(:id))
      ids = resolve_updated_chat_ids(user)
      persist_chat_accesses!(user, ids)

      render json: user_payload(user, include_token: false)
    rescue ActiveRecord::RecordNotFound
      render json: { error: "User not found" }, status: :not_found
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def user_payload(user, include_token:)
      chat_ids = user.chat_accesses.order(:td_chat_id).pluck(:td_chat_id)
      {
        user_id: user.id,
        username: user.username,
        admin: user.admin,
        active: user.active,
        chat_ids: chat_ids,
        watched_chats: watched_chats_payload(chat_ids)
      }.tap do |payload|
        payload[:token] = user.api_token if include_token
      end
    end

    def replace_chat_accesses!(user, chat_ids)
      ids = normalize_chat_ids(chat_ids)
      validate_assignable_chat_ids!(ids, field: "chat_ids")
      persist_chat_accesses!(user, ids)
    end

    def resolve_updated_chat_ids(user)
      return replace_chat_ids_param if chat_ids_param_provided?

      add_ids = normalize_chat_ids(params[:add_chat_ids] || params.dig(:auth, :add_chat_ids))
      remove_ids = normalize_chat_ids(params[:remove_chat_ids] || params.dig(:auth, :remove_chat_ids))
      raise ArgumentError, "provide chat_ids or add_chat_ids/remove_chat_ids" if add_ids.empty? && remove_ids.empty?

      validate_assignable_chat_ids!(add_ids, field: "add_chat_ids")
      current_ids = user.chat_accesses.order(:td_chat_id).pluck(:td_chat_id)
      (current_ids | add_ids) - remove_ids
    end

    def replace_chat_ids_param
      ids = normalize_chat_ids(chat_ids_param)
      validate_assignable_chat_ids!(ids, field: "chat_ids")
      ids
    end

    def validate_assignable_chat_ids!(ids, field:)
      return if ids.empty?

      known_ids = TelegramChat.where(td_chat_id: ids).distinct.pluck(:td_chat_id)
      unknown_ids = ids - known_ids
      return if unknown_ids.empty?

      raise ArgumentError, "#{field} include unknown chats: #{unknown_ids.join(',')}"
    end

    def persist_chat_accesses!(user, ids)
      current_ids = user.chat_accesses.order(:td_chat_id).pluck(:td_chat_id)
      added_ids = ids - current_ids
      sync_targets = watch_targets_by_account_for_chat_ids(added_ids)

      SystemUser.transaction do
        user.chat_accesses.delete_all
        rows = ids.map do |chat_id|
          { system_user_id: user.id, td_chat_id: chat_id, created_at: Time.current, updated_at: Time.current }
        end
        SystemUserChatAccess.insert_all(rows) if rows.any?
        TelegramAccountProfile.append_watched_chat_ids_for_chat_ids!(added_ids) if added_ids.any?
      end
      sync_messages_for_added_watch_targets!(sync_targets) if sync_targets.any?
    end

    def normalize_chat_ids(raw_ids)
      Array(raw_ids).map(&:to_i).reject(&:zero?).uniq
    end

    def chat_ids_param
      params[:chat_ids] || params.dig(:auth, :chat_ids)
    end

    def chat_ids_param_provided?
      return true if params.key?(:chat_ids)

      auth = params[:auth]
      auth.respond_to?(:key?) && auth.key?(:chat_ids)
    end

    def watch_targets_by_account_for_chat_ids(chat_ids)
      ids = normalize_chat_ids(chat_ids)
      return {} if ids.empty?

      rows = TelegramChat.where(td_chat_id: ids).distinct.pluck(:telegram_account_id, :td_chat_id)
      rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(account_id, td_chat_id), memo|
        memo[account_id.to_i] << td_chat_id.to_i
      end.transform_values { |values| values.uniq.sort }
    end

    def sync_messages_for_added_watch_targets!(added_watch_targets)
      accounts = TelegramAccount.where(id: added_watch_targets.keys, enabled: true).index_by(&:id)

      added_watch_targets.each do |account_id, chat_ids|
        account = accounts[account_id]
        next if account.nil? || chat_ids.empty?

        begin
          session = ::Telegram::Runtime.fetch(account.uuid) || ::Telegram::Runtime.start(account)
          session.invalidate_watched_chat_ids_cache! if session.respond_to?(:invalidate_watched_chat_ids_cache!)
          state = session.wait_for_initial_state(timeout: 3)
          if state == :initializing
            session.wait_until_ready!(timeout: 20)
            state = session.snapshot[:state]
          end
          if state != :ready
            Rails.logger.info("Skip auto sync for account #{account_id}: state=#{state}")
            next
          end

          sync = session.sync_messages_for_chats(chat_ids: chat_ids)
          Rails.logger.info("Auto synced history for account #{account_id} chats=#{chat_ids.inspect}: #{sync.inspect}")
        rescue StandardError => e
          Rails.logger.warn("Failed auto syncing history for account #{account_id} chats=#{chat_ids.inspect}: #{e.message}")
        end
      end
    end

    def watched_chats_payload(chat_ids)
      return [] if chat_ids.empty?

      chats_by_id = TelegramChat.where(td_chat_id: chat_ids).order(:td_chat_id, updated_at: :desc).group_by(&:td_chat_id)
      chat_ids.map do |chat_id|
        chat = chats_by_id[chat_id]&.first
        {
          td_chat_id: chat_id,
          title: chat&.title,
          chat_type: chat&.chat_type
        }
      end
    end
  end
end
