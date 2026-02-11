# frozen_string_literal: true

module Pumice
  class UndefinedAttributeError < StandardError; end
  class VerificationError < StandardError; end

  class Sanitizer
    extend Pumice::DSL
    include Pumice::Helpers

    class << self
      def inherited(subclass)
        super
        Pumice.register(subclass)
      end

      # Non-destructive sanitization - returns values without persisting
      # sanitize(record)              → returns hash of all sanitized values
      # sanitize(record, :attr)       → returns single sanitized value
      def sanitize(record, attr_name = nil, raw_value: nil)
        with_seed_for(record) do
          instance = new(record)
          attr_name ? instance.scrub(attr_name, raw_value) : instance.scrub_all
        end
      end

      # Destructive scrubbing - persists to database
      # scrub!(record)             → persists all scrubbed values
      # scrub!(record, :attr)      → persists single scrubbed value
      def scrub!(record, attr_name = nil)
        result = sanitize(record, attr_name)
        persist(record, attr_name, result)
        result
      end

      # Batch operation - sanitize all records of this model
      # If a bulk operation (truncate!, delete_all, destroy_all) is defined,
      # it runs instead of record-by-record sanitization.
      # If a prune operation is defined, matching records are deleted first,
      # then remaining records are scrubbed one-by-one.
      def scrub_all!
        validate_coverage! if Pumice.strict? && !bulk_operation

        logger.initialize_stats
        logger.log_start(name)

        count = if bulk_operation
                  run_bulk_operation
                else
                  pruned = prune_operation ? run_prune : 0
                  scrubbed_count = run_record_sanitization
                  pruned + scrubbed_count
                end

        run_verification unless Pumice.dry_run?

        logger.log_complete(name, count)
      rescue NameError => e
        logger.log_progress("Skipping #{name} (model not found)")
      end

      private

      def run_bulk_operation
        op = bulk_operation

        if Pumice.dry_run?
          logger.log_progress("[DRY RUN] Would execute #{op[:type]} operation")
          return 0
        end

        case op[:type]
        when :truncate
          run_truncate
        when :delete
          run_delete(op[:scope])
        when :destroy
          run_destroy(op[:scope])
        end
      end

      def run_truncate
        table = model_class.table_name
        count = model_class.count
        ActiveRecord::Base.connection.truncate(table)
        logger.log_progress("Truncated #{table}")
        count
      end

      def run_delete(scope_block)
        scope = scope_block ? model_class.instance_exec(&scope_block) : model_class.all
        count = scope.delete_all
        logger.log_progress("Deleted #{count} records")
        count
      end

      def run_destroy(scope_block)
        scope = scope_block ? model_class.instance_exec(&scope_block) : model_class.all
        count = scope.destroy_all.count
        logger.log_progress("Destroyed #{count} records")
        count
      end

      def run_prune
        scope_block = prune_operation[:scope]
        scope = model_class.instance_exec(&scope_block)

        if Pumice.dry_run?
          count = scope.count
          logger.log_progress("[DRY RUN] Would prune #{count} records")
          return 0
        end

        count = scope.delete_all
        logger.log_progress("Pruned #{count} records")
        count
      end

      def run_record_sanitization
        count = 0
        model_class.find_each do |record|
          scrub!(record)
          run_record_verification(record) unless Pumice.dry_run?
          count += 1
        rescue => e
          logger.log_error(name, e)
          raise unless Pumice.config.continue_on_error
        end
        count
      end

      def run_record_verification(record)
        return unless record_verification

        block = record_verification[:block]
        message = record_verification[:message]

        # Reload record to get persisted values
        record.reload

        result = block.call(record)

        unless result
          error_message = message || "Record verification failed for #{name} (ID: #{record.id})"
          logger.log_progress("VERIFICATION FAILED: #{error_message}")
          raise VerificationError, error_message
        end
      end

      def run_verification
        return unless verification

        if verification[:block]
          execute_verification(verification[:block], verification[:message])
        elsif verification[:use_default]
          execute_default_verification(verification[:message])
        end
      end

      def execute_verification(block, message)
        result = model_class.instance_exec(&block)

        unless result
          error_message = message || "Verification failed for #{name}"
          logger.log_progress("VERIFICATION FAILED: #{error_message}")
          raise VerificationError, error_message
        end

        logger.log_progress("Verification passed")
      end

      def execute_default_verification(message)
        unless bulk_operation
          raise ArgumentError,
            "#{name}: verify without a block requires a bulk operation (truncate!, delete_all, destroy_all)"
        end

        default_block = Pumice.config.default_verification.call(model_class, bulk_operation)

        # For scoped operations, the default policy returns the scope block.
        # We execute it and check .none? to verify records are gone.
        scope_or_result = model_class.instance_exec(&default_block)

        # If the result is an ActiveRecord relation, check .none?
        # Otherwise treat it as a boolean result
        result = if scope_or_result.respond_to?(:none?)
                   scope_or_result.none?
                 else
                   scope_or_result
                 end

        unless result
          error_message = message || "Verification failed for #{name}"
          logger.log_progress("VERIFICATION FAILED: #{error_message}")
          raise VerificationError, error_message
        end

        logger.log_progress("Verification passed")
      end

      def persist(record, attr_name, result)
        if attr_name
          persist_attribute(record, attr_name, result)
        else
          persist_record(record, result)
        end
      end

      def persist_record(record, data)
        if Pumice.dry_run?
          logger.log_record(:skipped, "ID #{record.id} (dry run)")
        else
          record.update_columns(data)
          logger.log_record(:sanitized, "ID #{record.id}")
        end
      end

      def persist_attribute(record, attr_name, value)
        if Pumice.dry_run?
          logger.log_record(:skipped, "ID #{record.id}.#{attr_name} (dry run)")
        else
          record.update_column(attr_name, value)
          logger.log_record(:sanitized, "ID #{record.id}.#{attr_name}")
        end
      end

      def with_seed_for(record)
        previous = Faker::Config.random
        Faker::Config.random = Random.new(record&.id || record.object_id)
        yield
      ensure
        Faker::Config.random = previous
      end

      def validate_coverage!
        return if undefined_columns.empty?

        raise UndefinedAttributeError,
          "#{name} is missing definitions for: #{undefined_columns.join(', ')}. " \
          "Add scrub(:column) { value } for each, or set Pumice.configure { |c| c.strict = false }"
      end

      def logger
        Pumice::Logger
      end
    end

    attr_reader :record

    def initialize(record)
      @record = record
    end

    def scrub(attr_name, raw_value = nil)
      raw_value ||= record.send(attr_name)
      block = self.class.scrubbed[attr_name.to_sym]
      return raw_value unless block

      instance_exec(raw_value, &block)
    end

    def scrub_all
      self.class.scrubbed.keys.each_with_object({}) do |attr_name, hash|
        hash[attr_name] = scrub(attr_name)
      end
    end

    # Read an original database value, bypassing scrubbing.
    #
    #   scrub(:email) { "#{raw(:first_name)}.#{raw(:last_name)}@example.test" }
    def raw(attr_name)
      record.public_send(attr_name)
    end

    # Provides a clean DSL for referencing attributes within scrub blocks:
    # - Bare attribute names return scrubbed values: `name` → scrub(:name)
    # - raw_* methods return original database values: `raw_name` → raw(:name)
    def method_missing(method_name, *args, &block)
      if raw_attribute_method?(method_name)
        return raw(extract_raw_attribute_name(method_name))
      end

      if self.class.scrubbed_column?(method_name)
        return scrub(method_name)
      end

      if record.respond_to?(method_name)
        return record.public_send(method_name, *args, &block)
      end

      super
    end

    def respond_to_missing?(method_name, include_private = false)
      raw_attribute_method?(method_name) ||
        self.class.scrubbed_column?(method_name) ||
        record.respond_to?(method_name, include_private) ||
        super
    end

    private

    def raw_attribute_method?(method_name)
      method_name.to_s.start_with?('raw_') &&
        record.respond_to?(extract_raw_attribute_name(method_name))
    end

    def extract_raw_attribute_name(method_name)
      method_name.to_s.delete_prefix('raw_').to_sym
    end
  end
end
