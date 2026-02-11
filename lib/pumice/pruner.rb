# frozen_string_literal: true

module Pumice
  class PruningConflictError < StandardError; end

  # Prunes records from tables based on global configuration.
  # Runs as a standalone phase before sanitization to reduce dataset size.
  #
  # Configuration:
  #   Pumice.configure do |config|
  #     config.pruning = {
  #       older_than: 90.days,          # OR newer_than: 30.days
  #       column: :created_at,
  #       only: %w[ifl_voice_logs debug_logs],  # OR
  #       except: %w[users messages],
  #       on_conflict: :warn            # :warn, :raise, or :rollback
  #     }
  #   end
  class Pruner
    attr_reader :stats

    def initialize
      @stats = { total: 0, tables: {} }
    end

    def run
      return @stats unless Pumice.pruning_enabled?

      pruning_config = Pumice.config.pruning
      column = pruning_config[:column]
      direction, age = resolve_direction(pruning_config)
      cutoff = resolve_cutoff(age)

      log_header(direction, age)
      check_conflicts!(pruning_config)

      tables_to_prune.each do |table_name|
        count = ActiveRecord::Base.transaction(requires_new: true) do
          prune_table(table_name, column, cutoff, direction)
        end
        @stats[:tables][table_name] = count if count > 0
        @stats[:total] += count
      end

      log_footer

      @stats
    end

    private

    def resolve_direction(config)
      if config[:older_than]
        [:older_than, config[:older_than]]
      else
        [:newer_than, config[:newer_than]]
      end
    end

    def resolve_cutoff(age)
      case age
      when ActiveSupport::Duration then age.ago
      when DateTime, Time, Date then age
      when String then DateTime.parse(age)
      else
        raise ArgumentError, "pruning age must be a Duration, DateTime, or date string, got #{age.class}"
      end
    end

    def tables_to_prune
      ActiveRecord::Base.connection.tables.select do |table|
        Pumice.prune_table?(table)
      end
    end

    def prune_table(table_name, column, cutoff, direction)
      model = table_name.classify.constantize

      unless model.column_names.include?(column.to_s)
        return 0
      end

      scope = if direction == :older_than
                model.where(model.arel_table[column].lt(cutoff))
              else
                model.where(model.arel_table[column].gteq(cutoff))
              end

      if Pumice.dry_run?
        count = scope.count
        Pumice::Logger.log_progress("  #{table_name}: would prune #{count} records") if count > 0
        return 0
      end

      count = scope.delete_all
      Pumice::Logger.log_progress("  #{table_name}: pruned #{count} records") if count > 0
      count
    rescue NameError
      0
    rescue ActiveRecord::StatementInvalid
      # Table doesn't exist in database (model constant exists but table was dropped/never created)
      0
    rescue ActiveRecord::InvalidForeignKey
      Pumice::Logger.log_progress("  #{table_name}: skipped (has foreign key dependencies)")
      0
    end

    def check_conflicts!(pruning_config)
      conflicts = detect_conflicts
      return if conflicts.empty?

      on_conflict = pruning_config[:on_conflict]

      conflicts.each do |table_name, sanitizer_class|
        message = "Global pruning and #{sanitizer_class.name} both declare pruning for '#{table_name}'. " \
                  "The global pruner runs first, then the sanitizer's prune runs on survivors."

        case on_conflict
        when :raise
          raise PruningConflictError, message
        when :rollback
          raise ActiveRecord::Rollback, message
        else
          Pumice::Logger.output.warning("CONFLICT: #{message}")
        end
      end
    end

    def detect_conflicts
      prunable_tables = tables_to_prune
      conflicts = {}

      Pumice.sanitizers.each do |sanitizer|
        next unless sanitizer.prune_operation

        begin
          table = sanitizer.model_class.table_name
          conflicts[table] = sanitizer if prunable_tables.include?(table)
        rescue StandardError
          next
        end
      end

      conflicts
    end

    def log_header(direction, age)
      label = direction == :older_than ? 'older' : 'newer'
      Pumice::Logger.output.blank
      Pumice::Logger.output.line('Global Pruning', emoji: '✂️')
      Pumice::Logger.output.line("  Removing records #{label} than #{format_duration(age)}")
      Pumice::Logger.output.line("  #{Pumice.dry_run? ? '[DRY RUN]' : '[LIVE]'}")
    end

    def log_footer
      if @stats[:total] > 0 || @stats[:tables].any?
        Pumice::Logger.output.success("Pruning complete: #{@stats[:total]} records from #{@stats[:tables].size} table(s)")
      else
        Pumice::Logger.output.line("  No records matched pruning criteria")
      end
    end

    def format_duration(duration)
      return duration.to_s unless duration.is_a?(ActiveSupport::Duration)

      days = (duration / 1.day).to_i
      if days >= 365
        "#{days / 365} year(s)"
      elsif days >= 30
        "#{days / 30} month(s)"
      else
        "#{days} day(s)"
      end
    end
  end
end
