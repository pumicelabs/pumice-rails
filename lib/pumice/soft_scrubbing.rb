# frozen_string_literal: true

module Pumice
  module SoftScrubbing
    extend ActiveSupport::Concern

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
      #
      #   def admin?
      #     ADMIN_EMAILS.include?(raw(:email))
      #   end
      def raw(attr_name)
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

    # Call this once at boot to enable the feature
    def self.init!
      return if @initialized

      ActiveRecord::Base.prepend(AttributeInterceptor)
      @initialized = true

      # Eager-load sanitizers using Rails' reloader
      Rails.application.reloader.to_prepare do
        Pumice::SoftScrubbing.eager_load_sanitizers!
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
        relative_path = Pathname.new(file).relative_path_from(sanitizer_paths)
        const_name = relative_path.to_s.delete_suffix('.rb').camelize

        begin
          const_name.constantize
        rescue NameError => e
          Rails.logger.warn("[Pumice] Could not load sanitizer #{const_name}: #{e.message}")
        end
      end
    end
  end
end
