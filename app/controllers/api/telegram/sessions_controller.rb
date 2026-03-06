# frozen_string_literal: true

module Api
  module Telegram
    class SessionsController < ApplicationController
      before_action :authenticate_system_user!
      before_action :find_account, only: %i[show phone code password destroy watch_targets sync_chats sync_messages]

      rescue_from ::Telegram::TdSession::InvalidStateError, with: :render_invalid_state

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

      def watch_targets
        chat_ids = Array(params.require(:chat_ids)).map(&:to_i).uniq
        profile = TelegramAccountProfile.find_or_initialize_by(telegram_account_id: @account.id)
        profile.watched_chat_ids = chat_ids
        profile.save!
        sync = ensure_session!.sync_messages_for_chats(
          chat_ids:,
          limit_per_chat: params[:message_limit],
          wait_seconds: params[:wait_seconds]
        )
        render json: account_snapshot(@account.reload).merge(message_sync: sync)
      end

      def sync_chats
        session = ensure_session!
        sync_result = session.sync_chats_now(limit: params[:limit])
        render json: account_snapshot(@account.reload).merge(sync: sync_result)
      end

      def sync_messages
        profile = TelegramAccountProfile.find_by(telegram_account_id: @account.id)
        fallback_ids = profile&.watched_chat_ids
        chat_ids = Array(params[:chat_ids] || fallback_ids).map(&:to_i).uniq
        sync = ensure_session!.sync_messages_for_chats(
          chat_ids:,
          limit_per_chat: params[:message_limit],
          wait_seconds: params[:wait_seconds]
        )
        render json: account_snapshot(@account.reload).merge(message_sync: sync, chat_ids:)
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

      def render_invalid_state(error)
        render json: { error: error.message }, status: :unprocessable_entity
      end
    end
  end
end
