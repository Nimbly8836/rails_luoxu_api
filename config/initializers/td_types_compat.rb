# frozen_string_literal: true

return unless defined?(TD::Types)

module TD
  module Types
    # Fallback type for updates that current tdlib-schema can't fully parse.
    class Unsupported < Base
      attribute :original_type, TD::Types::String
      attribute :raw, TD::Types::Hash
    end

    class << self
      alias_method :wrap_without_compat, :wrap

      def wrap(object)
        case object
        when Array
          object.map { |o| wrap(o) }
        when Hash
          safe_wrap_hash(object)
        else
          object
        end
      rescue StandardError
        object
      end

      private

      def safe_wrap_hash(hash)
        obj = hash.dup
        type = obj.delete("@type")

        obj.each do |key, val|
          obj[key] = wrap(val) if val.is_a?(Array) || val.is_a?(Hash)
        end

        return obj unless type

        klass_name = LOOKUP_TABLE[type]
        return TD::Types::Unsupported.new(original_type: type, raw: obj) unless klass_name

        klass = const_get(klass_name)
        klass.new(obj)
      rescue Dry::Struct::Error
        patched = patch_known_missing_fields(type, obj)
        begin
          klass.new(patched)
        rescue StandardError
          TD::Types::Unsupported.new(original_type: type, raw: patched)
        end
      rescue ArgumentError
        TD::Types::Unsupported.new(original_type: type, raw: obj)
      end

      def patch_known_missing_fields(type, obj)
        case type
        when "user"
          obj.merge("is_verified" => false)
        when "updateChatAction"
          obj.merge("message_thread_id" => 0)
        else
          obj
        end
      end
    end
  end
end
