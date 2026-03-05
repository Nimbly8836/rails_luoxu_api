# frozen_string_literal: true

if defined?(Rails::Server) || ENV["TELEGRAM_RUNTIME_BOOT"] == "1"
  Rails.application.config.after_initialize do
    Telegram::Runtime.boot!
  end
end
