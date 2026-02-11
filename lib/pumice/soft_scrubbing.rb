# frozen_string_literal: true

module Pumice
  class MethodConflictError < StandardError; end

  module SoftScrubbing
    extend ActiveSupport::Concern

    # Soft scrubbing lets you return sanitized values on read without persisting
    # them. To enable:

    #   1. Toggle config.soft_scrubbing = {} (see config/initializers/sanitization.rb)
    #      → Pumice.configure automatically calls init! when enabled
    #   2. Set a viewer context: Pumice.soft_scrubbing_context = current_user
    #      (accepts a user object, Proc, or Symbol; symbols resolve against
    #      the sanitizer record, Pumice, a Current object, or thread locals)
    #      or wrap calls with Pumice.with_soft_scrubbing_context(current_user) { ... }
    #   3. Customize config.soft_scrubbing policy to decide which viewers see scrubbed
    #      data (default: scrub for everyone)
    #
    # Attributes only change when the sanitizer defines a scrub(:column) block; all
    # other attributes behave as usual.

    RECURSION_GUARD_KEY = :pumice_soft_scrub_in_progress

    # System attributes that should never be scrubbed (needed for Rails internals)
    SYSTEM_ATTRIBUTES = %w[id created_at updated_at].freeze

    module AttributeInterceptor
      def _read_attribute(attr_name)
        # Prevent infinite recursion - if we're already inside the interceptor, bail out
        return super if Thread.current[Pumice::SoftScrubbing::RECURSION_GUARD_KEY]

        # Quick check: skip if soft_scrubbing not configured
        return super unless Pumice.soft_scrubbing?

        # Skip system attributes needed for Rails/Devise internals (session serialization, etc.)
        return super if Pumice::SoftScrubbing::SYSTEM_ATTRIBUTES.include?(attr_name.to_s)

        begin
          Thread.current[Pumice::SoftScrubbing::RECURSION_GUARD_KEY] = true

          unless Pumice.soft_scrubbing_enabled_for?(self)
            return super
          end

          sanitizer = Pumice.sanitizer_for(self.class)
          return super unless sanitizer.scrubbed_column?(attr_name)

          soft_scrubbed_value(attr_name, sanitizer)
        ensure
          Thread.current[Pumice::SoftScrubbing::RECURSION_GUARD_KEY] = false
        end
      end

      # Read an attribute's raw value, bypassing soft scrubbing.
      # Use this in policy checks or methods that need the real value.
      #
      # Example:
      #   def super_duper_admin?
      #     ADMIN_EMAILS.include?(raw_attribute(:email))
      #   end
      def raw_attribute(attr_name)
        @attributes.fetch_value(attr_name.to_s)
      end

      private

      def soft_scrubbed_value(attr_name, sanitizer)
        @_soft_scrubbed_cache ||= {}
        @_soft_scrubbed_cache[attr_name] ||= begin
          raw_value = @attributes.fetch_value(attr_name.to_s)
          sanitizer.sanitize(self, attr_name, raw_value: raw_value)
        end
      end
    end

    # Module providing raw_attribute access and raw_<attr> helper generation.
    # Automatically included in ActiveRecord::Base when soft scrubbing is initialized.
    module RawAttributeHelpers
      # Generic accessor for any attribute's raw value
      def raw_attribute(attr_name)
        @attributes.fetch_value(attr_name.to_s)
      end
    end

    # Call this once at boot to enable the feature
    def self.init!
      return if @initialized

      ActiveRecord::Base.prepend(AttributeInterceptor)
      ActiveRecord::Base.include(RawAttributeHelpers)
      @initialized = true

      # Eager-load sanitizers and define raw_* methods using Rails' reloader
      Rails.application.reloader.to_prepare do
        Pumice::SoftScrubbing.eager_load_sanitizers!
        Pumice::SoftScrubbing.define_raw_attribute_methods!
      end

      Rails.logger.info("[Pumice] Soft scrubbing initialized")
    end

    def self.initialized?
      @initialized == true
    end

    # For debugging: force re-initialization (use in console only)
    def self.reinit!
      @initialized = false
      init!
    end

    def self.eager_load_sanitizers!
      sanitizer_paths = Rails.root.join('app/sanitizers')
      return unless sanitizer_paths.exist?

      Dir[sanitizer_paths.join('**/*.rb')].sort.each do |file|
        # Convert path to constant name: app/sanitizers/user_sanitizer.rb -> UserSanitizer
        relative_path = Pathname.new(file).relative_path_from(sanitizer_paths)
        const_name = relative_path.to_s.delete_suffix('.rb').camelize

        begin
          const_name.constantize
        rescue NameError => e
          Rails.logger.warn("[Pumice] Could not load sanitizer #{const_name}: #{e.message}")
        end
      end
    end

    # Define raw_<attr> methods on models for each scrubbed column.
    # This is called after sanitizers are loaded so scrub declarations are available.
    #
    # Example: UserSanitizer with scrub(:email) defines User#raw_email
    def self.define_raw_attribute_methods!
      Pumice.sanitizers.each do |sanitizer|
        model_class = sanitizer.model_class
        next unless model_class.is_a?(Class) && model_class < ActiveRecord::Base

        sanitizer.scrubbed_columns.each do |column|
          method_name = "raw_#{column}"

          if model_class.method_defined?(method_name)
            handle_raw_method_conflict(model_class, method_name)
            next
          end

          model_class.define_method(method_name) do
            @attributes.fetch_value(column.to_s)
          end
        end
      rescue NameError => e
        Rails.logger.warn("[Pumice] Could not define raw methods for #{sanitizer.name}: #{e.message}")
      end
    end

    def self.handle_raw_method_conflict(model_class, method_name)
      message = "[Pumice] #{model_class.name}##{method_name} already defined, skipping"

      case Pumice.config.on_raw_method_conflict
      when :raise
        raise MethodConflictError, "#{model_class.name}##{method_name} already defined. " \
          "Remove the existing method or set config.on_raw_method_conflict = :skip"
      when :warn
        Rails.logger.warn(message)
      end
      # :skip is silent (default)
    end
  end
end
