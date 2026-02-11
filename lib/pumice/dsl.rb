# frozen_string_literal: true

module Pumice
  # DSL methods for defining sanitizer behavior.
  # Extended by Sanitizer subclasses to provide scrub/keep declarations.
  module DSL
    PROTECTED_COLUMNS = %w[id created_at updated_at].freeze

    # Explicitly declare the model this sanitizer handles.
    # Uses pluralized form (like has_many):
    #   sanitizes :users                       # infers User
    #   sanitizes :admin_users, class_name: 'Admin::User'  # namespaced model
    #   sanitizes :users, class_name: User     # explicit constant
    def sanitizes(model_name, class_name: model_name.to_s.classify)
      @model_class = if class_name.is_a?(String)
                       class_name.constantize
                     else
                       class_name
                     end
    end

    def model_class
      @model_class ||= infer_model_class
    end

    # Override the auto-derived friendly name for rake tasks
    # Example: friendly_name 'legacy_users' in LegacyUserDataSanitizer
    def friendly_name(name = nil)
      if name
        @friendly_name = name.to_s
      else
        @friendly_name || infer_friendly_name
      end
    end

    # Define a scrubbing rule for a column
    def scrub(name, &block)
      @scrubbed ||= {}
      @scrubbed[name] = block
    end

    # Mark columns as safe to keep unchanged (not PII)
    def keep(*names)
      @kept ||= []
      @kept.concat(names.map(&:to_sym))
    end

    # UNSAFE: Keep all columns not explicitly declared via scrub or keep.
    # Bypasses PII review - use only for development/testing.
    # Disable with: Pumice.configure { |c| c.allow_keep_undefined_columns = false }
    def keep_undefined_columns!
      unless Pumice.allow_keep_undefined_columns?
        raise "keep_undefined_columns! is disabled. " \
              "This method bypasses PII review and should not be used in production."
      end

      @kept ||= []
      @kept.concat(undefined_columns.map(&:to_sym))
    end

    # Prune Operation
    # Removes matching records BEFORE record-by-record scrubbing.
    # Use when you want to delete old/irrelevant records AND scrub the survivors.
    #
    # Unlike bulk operations (truncate!, delete_all, destroy_all) which are terminal,
    # prune is a pre-step: it deletes matching records, then scrubbing continues
    # on the remaining records.
    #
    # Examples:
    #   prune { where(created_at: ..1.year.ago) }  # Delete old, scrub the rest
    #   prune { where(status: 'archived') }        # Delete archived, scrub active
    def prune(&scope)
      raise ArgumentError, 'prune requires a block' unless scope

      @prune_operation = { scope: scope }
    end

    # Convenience: prune records older than the given age.
    # Accepts a duration (1.year), DateTime, or date string ("2024-01-01").
    #
    # Examples:
    #   prune_older_than 1.year
    #   prune_older_than 90.days
    #   prune_older_than DateTime.new(2024, 1, 1)
    #   prune_older_than "2024-01-01"
    def prune_older_than(age, column: :created_at)
      cutoff = resolve_prune_cutoff(age)
      prune { where(column => ...cutoff) }
    end

    # Convenience: prune records newer than the given age.
    # Accepts a duration (1.year), DateTime, or date string ("2024-01-01").
    #
    # Examples:
    #   prune_newer_than 1.year
    #   prune_newer_than 30.days
    #   prune_newer_than "2025-06-01"
    def prune_newer_than(age, column: :created_at)
      cutoff = resolve_prune_cutoff(age)
      prune { where(column => cutoff..) }
    end

    def prune_operation
      @prune_operation
    end

    # Bulk Operations (Terminal)
    # These replace record-by-record sanitization with fast bulk SQL operations.
    # No scrubbing runs after a bulk operation.
    # Use for audit logs, sessions, and other high-volume tables.

    # TRUNCATE TABLE - fastest, resets auto-increment, no conditions
    # Examples:
    #   truncate!
    #   truncate!(verify: true)  # verifies count.zero? after truncation
    def truncate!(verify: false)
      @bulk_operation = { type: :truncate }
      self.verify if verify
    end

    # DELETE with optional scope - fast, no callbacks/associations
    # Examples:
    #   delete_all                                    # deletes all records
    #   delete_all { where(item_type: 'User') }       # deletes matching records
    #   delete_all(verify: true) { where(...) }       # verifies scope.none? after deletion
    def delete_all(verify: false, &scope)
      @bulk_operation = { type: :delete, scope: scope }
      self.verify if verify
    end

    # DESTROY with optional scope - runs callbacks, handles associations
    # Examples:
    #   destroy_all                                   # destroys all records
    #   destroy_all { where(attachable_id: nil) }     # destroys orphaned records
    #   destroy_all(verify: true) { where(...) }      # verifies scope.none? after destruction
    def destroy_all(verify: false, &scope)
      @bulk_operation = { type: :destroy, scope: scope }
      self.verify if verify
    end

    def bulk_operation
      @bulk_operation
    end

    # Verification
    # Define post-sanitization checks to confirm the operation succeeded.

    # Verify after all records are processed (bulk or record-by-record)
    # Block executes in model scope and should return truthy for success.
    # Examples:
    #   verify                                          # uses default for bulk ops
    #   verify { where(item_type: SENSITIVE_TYPES).none? }
    #   verify "No sensitive data should remain" do
    #     where(pii_column: true).count.zero?
    #   end
    def verify(message = nil, &block)
      @verification = if block
                        { message: message, block: block }
                      else
                        { message: message, use_default: true }
                      end
    end

    # Verify each record after sanitization (record-by-record only)
    # Block receives the sanitized record and should return truthy for success.
    # Examples:
    #   verify_each { |record| !record.email.include?('@gmail.com') }
    #   verify_each "Record should not contain real email" do |record|
    #     record.email.end_with?('@example.com')
    #   end
    def verify_each(message = nil, &block)
      raise ArgumentError, 'verify_each requires a block' unless block

      @record_verification = { message: message, block: block }
    end

    def verification
      @verification
    end

    def record_verification
      @record_verification
    end

    def scrubbed
      @scrubbed ||= {}
    end

    def kept
      @kept ||= []
    end

    def scrubbed_columns
      scrubbed.keys.map(&:to_s)
    end

    def scrubbed_column?(name)
      scrubbed_columns.include?(name.to_s)
    end

    def kept_columns
      kept.map(&:to_s)
    end

    def defined_columns
      scrubbed_columns + kept_columns
    end

    def undefined_columns
      model_class.column_names - defined_columns - PROTECTED_COLUMNS
    end

    def stale_columns
      defined_columns - model_class.column_names
    end

    def lint!
      issues = []

      # Bulk operations are terminal — no scrubbing happens, so column coverage is irrelevant
      if undefined_columns.any? && !bulk_operation
        issues << "#{name} (#{model_class.name}) has undefined columns: #{undefined_columns.join(', ')}"
      end

      if stale_columns.any?
        issues << "#{name} (#{model_class.name}) has stale columns (removed from model): #{stale_columns.join(', ')}"
      end

      if bulk_operation && (scrubbed.any? || kept.any?)
        ignored = (scrubbed_columns + kept_columns).join(', ')
        issues << "#{name} uses a terminal bulk operation (#{bulk_operation[:type]}) but also declares scrub/keep columns (#{ignored}). These will be ignored."
      end

      issues
    rescue NameError, RuntimeError => e
      ["#{name} references a model that doesn't exist: #{e.message}"]
    end

    private

    def infer_model_class
      # e.g. UserSanitizer -> User, StudentSanitizer -> Student
      model_name = name.delete_suffix('Sanitizer')
      model_name.constantize
    rescue NameError
      raise "Could not infer model for #{name}. Use `sanitizes :model_names` to specify explicitly."
    end

    def infer_friendly_name
      name.delete_suffix('Sanitizer').underscore.pluralize
    end

    def resolve_prune_cutoff(age)
      case age
      when ActiveSupport::Duration
        age.ago
      when DateTime, Time, Date
        age
      when String
        DateTime.parse(age)
      else
        raise ArgumentError,
          "prune cutoff must be a Duration (1.year), DateTime, or date string, got #{age.class}"
      end
    end
  end
end
