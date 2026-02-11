# frozen_string_literal: true

module Pumice
  module Logger
    extend self

    def output
      @output ||= Output.new
    end

    def output=(out)
      @output = out
    end

    def initialize_stats
      @stats = {
        started_at: Time.current,
        total_records: 0,
        sanitized_records: 0,
        skipped_records: 0,
        errors: []
      }
    end

    def log_start(sanitizer_name)
      output.blank
      output.line(sanitizer_name, emoji: '🧹')
      output.line("  #{Pumice.dry_run? ? '[DRY RUN]' : '[LIVE]'}")
    end

    def log_progress(message)
      output.line("  → #{message}") if Pumice.verbose?
    end

    def log_record(action, details = nil)
      initialize_stats if @stats.nil?

      case action
      when :sanitized
        @stats[:sanitized_records] += 1
        output.line("    ✓ #{details}") if details && Pumice.verbose?
      when :skipped
        @stats[:skipped_records] += 1
        output.line("    ⊘ #{details}") if details && Pumice.verbose?
      when :error
        @stats[:errors] << details
        output.line("    ✗ ERROR: #{details}") if Pumice.verbose?
      end

      @stats[:total_records] += 1
    end

    def log_complete(sanitizer_name, count)
      duration = Time.current - @stats[:started_at]
      output.success("Complete: #{count} records in #{duration.round(2)}s")
    end

    def log_error(sanitizer_name, error)
      output.error("Error in #{sanitizer_name}: #{error.message}")
      Rails.logger.error("Pumice::#{sanitizer_name} failed: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))
    end

    def summary
      return if @stats.nil?

      duration = Time.current - @stats[:started_at]

      output.blank
      output.divider
      output.line('Sanitization Summary', emoji: '📊')
      output.divider
      output.line("Total records processed: #{@stats[:total_records]}")
      output.line("Sanitized: #{@stats[:sanitized_records]}")
      output.line("Skipped: #{@stats[:skipped_records]}")
      output.line("Errors: #{@stats[:errors].size}")
      output.line("Duration: #{duration.round(2)}s")
      output.line("Mode: #{Pumice.dry_run? ? 'DRY RUN (no changes made)' : 'LIVE'}")

      if @stats[:errors].any?
        output.blank
        output.line('Errors encountered:')
        @stats[:errors].each { |error| output.bullet(error) }
      end

      output.divider
      output.blank
    end
  end
end
