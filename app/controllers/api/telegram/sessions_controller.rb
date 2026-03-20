# frozen_string_literal: true

module Api
  module Telegram
    class SessionsController < ApplicationController
      before_action :authenticate_system_user!
      before_action :find_account, only: %i[show phone code password destroy purge watch_targets update_watch_targets sync_chats sync_messages sync_group_members]

      rescue_from ::Telegram::TdSession::InvalidStateError, with: :render_invalid_state
      rescue_from ActionController::ParameterMissing, with: :render_bad_request
      rescue_from ArgumentError, with: :render_unprocessable
      rescue_from StandardError, with: :render_internal_error

      def index
        accounts = TelegramAccount.includes(:profile, :telegram_chats).order(created_at: :desc).limit(100)
        render json: accounts.map { |account| account_snapshot(account) }
      end

      def create
        session = ::Telegram::Runtime.create_account!(use_test_dc: ActiveModel::Type::Boolean.new.cast(params[:use_test_dc]))
        session.wait_for_initial_state(timeout: 2)
        account = TelegramAccount.find_by!(uuid: session.id)
        runtime_snapshot = session.snapshot
        render json: account_snapshot(account).merge(
          state: runtime_snapshot[:state],
          me: runtime_snapshot[:me],
          error: runtime_snapshot[:error]
        ), status: :created
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def show
        render json: current_snapshot
      end

      def phone
        render json: ensure_session!.submit_phone(phone_number: params.require(:phone_number))
      end

      def code
        render json: ensure_session!.submit_code(code: params.require(:code))
      end

      def password
        render json: ensure_session!.submit_password(password: params.require(:password))
      end

      def destroy
        @account.update!(enabled: false, disabled_at: Time.current, state: "disabled")
        ::Telegram::Runtime.stop(@account.uuid)
        head :no_content
      end

      def purge
        if account_ready?
          render json: { error: "Cannot purge a ready account. Disable or move it out of ready state first." }, status: :unprocessable_entity
          return
        end

        ::Telegram::Runtime.delete_account!(@account, reason: "manual_purge")
        head :no_content
      end

      def watch_targets
        render json: watch_targets_payload(@account)
      end

      def update_watch_targets
        chat_ids = Array(params.require(:chat_ids)).map(&:to_i).uniq
        profile = TelegramAccountProfile.find_or_initialize_by(telegram_account_id: @account.id)
        profile.save! if profile.new_record?
        profile.replace_watched_chat_ids!(chat_ids)
        full_sync = ActiveModel::Type::Boolean.new.cast(params[:full_sync])
        session = ensure_session!
        session.invalidate_watched_chat_ids_cache! if session.respond_to?(:invalidate_watched_chat_ids_cache!)
        sync = session.sync_messages_for_chats_async(
          chat_ids:,
          limit_per_chat: full_sync ? nil : params[:message_limit],
          wait_seconds: params[:wait_seconds],
          reason: "watch_targets"
        )
        render json: watch_targets_payload(@account, watched_chat_ids: chat_ids).merge(message_sync: sync), status: :accepted
      end

      def sync_chats
        session = ensure_session!
        sync_result = session.sync_chats_now(limit: params[:limit])
        render json: { session_id: @account.uuid, sync: sync_result }
      end

      def sync_messages
        profile = TelegramAccountProfile.find_by(telegram_account_id: @account.id)
        fallback_ids = profile&.watched_chat_ids
        chat_ids = Array(params[:chat_ids] || fallback_ids).map(&:to_i).uniq
        sync = ensure_session!.sync_messages_for_chats_async(
          chat_ids:,
          limit_per_chat: params[:message_limit],
          wait_seconds: params[:wait_seconds],
          reason: "api_sync_messages"
        )
        render json: { session_id: @account.uuid, chat_ids:, message_sync: sync }, status: :accepted
      end

      def sync_group_members
        profile = TelegramAccountProfile.find_by(telegram_account_id: @account.id)
        fallback_ids = profile&.watched_chat_ids
        chat_ids = Array(params[:chat_ids] || fallback_ids).map(&:to_i).uniq
        sync = ensure_session!.sync_group_members_for_chats(chat_ids:)
        render json: { session_id: @account.uuid, chat_ids:, group_member_sync: sync }
      end

      private

      def find_account
        @account = TelegramAccount.find_by(uuid: params[:id])
        return if @account

        render json: { error: "Telegram account not found" }, status: :not_found
        nil
      end

      def ensure_session!
        session = ::Telegram::Runtime.fetch(@account.uuid)
        return session if session

        raise ::Telegram::TdSession::InvalidStateError, "Account is disabled" unless @account.enabled?

        ::Telegram::Runtime.start(@account)
      end

      def current_snapshot
        session = ::Telegram::Runtime.fetch(@account.uuid)
        session ? session.snapshot : persisted_snapshot
      end

      def account_ready?
        snapshot_state = current_snapshot[:state].to_s
        snapshot_state == "ready" || @account.state.to_s == "ready"
      end

      def persisted_snapshot
        account_snapshot(@account)
      end

      def account_snapshot(account)
        {
          session_id: account.uuid,
          state: account.state,
          me: account.me_payload.presence,
          profile: profile_snapshot(account.profile),
          error: account.last_error,
          enabled: account.enabled,
          use_test_dc: account.use_test_dc,
          connected_at: account.connected_at,
          chat_count: account.telegram_chats.size,
          updated_at: account.updated_at
        }
      end

      def profile_snapshot(profile)
        return nil unless profile

        {
          td_user_id: profile.td_user_id,
          username: profile.username,
          first_name: profile.first_name,
          last_name: profile.last_name,
          phone_number: profile.phone_number,
          watched_chat_ids: profile.watched_chat_ids
        }
      end

      def watch_targets_payload(account, watched_chat_ids: nil)
        chat_ids = Array(watched_chat_ids || account.watch_targets.order(:td_chat_id).pluck(:td_chat_id)).map(&:to_i).uniq.sort
        chats_by_id = TelegramChat.where(telegram_account_id: account.id, td_chat_id: chat_ids)
                                 .order(:td_chat_id, updated_at: :desc)
                                 .group_by(&:td_chat_id)

        {
          session_id: account.uuid,
          watched_chat_ids: chat_ids,
          watched_chats: chat_ids.map do |chat_id|
            chat = chats_by_id[chat_id]&.first
            {
              td_chat_id: chat_id,
              title: chat&.title,
              chat_type: chat&.chat_type,
              synced_at: chat&.synced_at
            }
          end
        }
      end

      def render_invalid_state(error)
        render json: { error: error.message }, status: :unprocessable_entity
      end

      def render_bad_request(error)
        render json: { error: error.message }, status: :bad_request
      end

      def render_unprocessable(error)
        render json: { error: error.message }, status: :unprocessable_entity
      end

      def render_internal_error(error)
        Rails.logger.error(
          "Telegram sessions API error request_id=#{request.request_id} " \
          "path=#{request.path} error_class=#{error.class} error=#{error.message}"
        )
        Rails.logger.error(error.backtrace&.first(10)&.join("\n")) if error.backtrace.present?
        render json: { error: error.message, request_id: request.request_id }, status: :internal_server_error
      end
    end
  end
end
