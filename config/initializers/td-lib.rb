# frozen_string_literal: true

base_path = Rails.root.join("lib")
base_name = "libtdjson"


lib_path =
  case RUBY_PLATFORM
  when /darwin/
    base_path.join("#{base_name}.dylib")
  when /linux/
    base_path.join("#{base_name}.so")
  # when /mingw|mswin/
  #   base_path.join("windows", "#{base_name}.dll")
  else
    Rails.logger.warn "TDLib is not supported on this platform: #{RUBY_PLATFORM}"
    nil
  end


if lib_path&.exist?
  Rails.application.config.td_lib_path = lib_path.to_s
else
  Rails.logger.warn "TDLib library not found at expected path: #{lib_path}"
end
