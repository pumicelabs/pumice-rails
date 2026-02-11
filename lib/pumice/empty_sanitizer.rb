# frozen_string_literal: true

module Pumice
  # Null object pattern - safe to call without nil checks.
  # Returns original values unchanged when no sanitizer is defined for a model.
  # Does not inherit from Sanitizer to avoid auto-registration.
  class EmptySanitizer
    class << self
      def scrubbed_columns
        []
      end

      def scrubbed_column?(_name)
        false
      end

      def sanitize(_record, _attr_name = nil, raw_value: nil)
        raw_value
      end

      def scrubbed
        {}
      end

      def kept
        []
      end

      def model_class
        nil
      end

      def friendly_name
        'empty'
      end
    end
  end
end
