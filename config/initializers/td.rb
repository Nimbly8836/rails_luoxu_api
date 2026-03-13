# frozen_string_literal: true

begin
  require "tdlib-ruby"
rescue LoadError
  Rails.logger.warn("Gem 'tdlib-ruby' is not available. Run bundle install.")
end

if defined?(TD)
  safe_credential = lambda do |*path|
    Rails.application.credentials.dig(*path)
  rescue ActiveSupport::EncryptedFile::MissingKeyError,
         ActiveSupport::MessageEncryptor::InvalidMessage,
         KeyError,
         NoMethodError
    nil
  end

  api_id = ENV["TELEGRAM_API_ID"].presence || safe_credential.call(:telegram, :api_id)
  api_hash = ENV["TELEGRAM_API_HASH"].presence || safe_credential.call(:telegram, :api_hash)
  log_level = Integer(ENV.fetch("TDLIB_LOG_LEVEL", "1"))
  lib_dir = ENV["TDLIB_LIB_PATH"].presence
  lib_dir ||= begin
    detected = Rails.application.config.respond_to?(:td_lib_path) ? Rails.application.config.td_lib_path : nil
    detected.present? ? File.dirname(detected) : Rails.root.join("vendor").to_s
  end

  TD.configure do |config|
    # lib_path must always be set so TD::Api can load libtdjson even in diagnostics.
    config.lib_path = lib_dir
    config.encryption_key = ENV["TDLIB_ENCRYPTION_KEY"].presence ||
                            safe_credential.call(:telegram, :encryption_key).presence
    config.client.use_test_dc = ActiveModel::Type::Boolean.new.cast(ENV.fetch("TDLIB_USE_TEST_DC", "false"))
    config.client.database_directory = Rails.root.join("storage", "tdlib", "default", "db").to_s
    config.client.files_directory = Rails.root.join("storage", "tdlib", "default", "files").to_s
    config.client.use_file_database = true
    config.client.use_chat_info_database = true
    config.client.use_secret_chats = true
    config.client.use_message_database = true
    config.client.system_language_code = ENV.fetch("TDLIB_SYSTEM_LANGUAGE_CODE", "en")
    config.client.device_model = ENV.fetch("TDLIB_DEVICE_MODEL", "Rails Luoxu API")
    config.client.system_version = ENV.fetch("TDLIB_SYSTEM_VERSION", RUBY_PLATFORM)
    config.client.application_version = ENV.fetch("TDLIB_APP_VERSION", "1.0")

    if api_id.present? && api_hash.present?
      config.client.api_id = api_id.to_i
      config.client.api_hash = api_hash
    end
  end

  if api_id.blank? || api_hash.blank?
    Rails.logger.warn("TELEGRAM_API_ID or TELEGRAM_API_HASH is missing. Telegram auth will not work.")
  end

  TD::Api.set_log_verbosity_level(log_level)
end
