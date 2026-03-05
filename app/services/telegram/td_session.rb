# frozen_string_literal: true

module Telegram
  class TdSession
    class InvalidStateError < StandardError; end

    attr_reader :id

    def initialize(account:)
      raise "TD gem is not configured" unless defined?(TD)

      @account_id = account.id
      @id = account.uuid
      @mutex = Mutex.new
      @state = :initializing
      @me = nil
      @last_error = nil
      @disposed = false

      @client = TD::Client.new(**client_config(account))
      subscribe_updates
      @client.connect
    end

    def submit_phone(phone_number:)
      raise_if_disposed!
      ensure_state!(:wait_phone_number)
      @client.set_authentication_phone_number(phone_number:, settings: nil).wait
      persist_account(phone_number:)
      snapshot
    rescue StandardError => e
      capture_error(e)
      raise
    end

    def wait_for_initial_state(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        current = @mutex.synchronize { @state }
        return current unless current == :initializing
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(0.05)
      end

      @mutex.synchronize { @state }
    end

    def submit_code(code:)
      raise_if_disposed!
      ensure_state!(:wait_code)
      @client.check_authentication_code(code:).wait
      snapshot
    rescue StandardError => e
      capture_error(e)
      raise
    end

    def submit_password(password:)
      raise_if_disposed!
      ensure_state!(:wait_password)
      @client.check_authentication_password(password:).wait
      snapshot
    rescue StandardError => e
      capture_error(e)
      raise
    end

    def snapshot
      @mutex.synchronize do
        {
          session_id: id,
          state: @state,
          me: serialize_user(@me),
          error: @last_error
        }
      end
    end

    def dispose
      should_dispose = @mutex.synchronize do
        next false if @disposed

        @disposed = true
        true
      end

      if should_dispose
        @client.dispose
        persist_account(state: "closed", last_state_at: Time.current)
      end
    end

    private

    def subscribe_updates
      @client.on(TD::Types::Update::AuthorizationState) do |update|
        state = map_auth_state(update.authorization_state)
        next if state.nil?

        @mutex.synchronize { @state = state }
        persist_account(
          state: state.to_s,
          last_state_at: Time.current,
          connected_at: (state == :ready ? Time.current : nil),
          last_error: nil
        )
        fetch_me if state == :ready
      end
    end

    def map_auth_state(auth_state)
      case auth_state
      when TD::Types::AuthorizationState::WaitPhoneNumber then :wait_phone_number
      when TD::Types::AuthorizationState::WaitCode then :wait_code
      when TD::Types::AuthorizationState::WaitPassword then :wait_password
      when TD::Types::AuthorizationState::Ready then :ready
      when TD::Types::AuthorizationState::Closed then :closed
      else
        nil
      end
    end

    def fetch_me
      @client.get_me.then { |user| @mutex.synchronize { @me = user } }
        .rescue { |err| @mutex.synchronize { @last_error = err.to_s } }
        .wait
      persist_me
    rescue StandardError => e
      @mutex.synchronize { @last_error = e.message }
      capture_error(e)
    end

    def ensure_state!(expected_state)
      current = @mutex.synchronize { @state }
      return if current == expected_state

      raise InvalidStateError, "Current state is #{current}, expected #{expected_state}"
    end

    def raise_if_disposed!
      disposed = @mutex.synchronize { @disposed }
      raise InvalidStateError, "Session is disposed" if disposed
    end

    def serialize_user(user)
      return nil if user.nil?

      {
        id: user.id,
        first_name: user.first_name,
        last_name: user.last_name,
        username: user.usernames&.editable_username,
        phone_number: user.phone_number
      }
    end

    def client_config(account)
      config = {
        use_test_dc: account.use_test_dc,
        database_directory: account.database_directory,
        files_directory: account.files_directory
      }

      encryption_key = ENV["TDLIB_DATABASE_ENCRYPTION_KEY"].presence
      config[:database_encryption_key] = encryption_key if encryption_key
      config
    end

    def persist_me
      payload = serialize_user(@me)
      return unless payload

      persist_account(
        td_user_id: payload[:id],
        first_name: payload[:first_name],
        last_name: payload[:last_name],
        username: payload[:username],
        phone_number: payload[:phone_number],
        me_payload: payload,
        last_error: nil
      )
    end

    def capture_error(error)
      @mutex.synchronize { @last_error = error.message }
      persist_account(last_error: error.message)
    end

    def persist_account(attrs)
      TelegramAccount.where(id: @account_id).update_all(attrs.merge(updated_at: Time.current))
    end
  end
end
