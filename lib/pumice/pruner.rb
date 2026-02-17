# frozen_string_literal: true

module Pumice
  # Prunes records from tables based on global configuration.
  # Runs as a standalone phase before sanitization to reduce dataset size.
  #
  # Tables where a sanitizer defines its own `prune` are skipped —
  # the sanitizer-level prune overrides global pruning for that table.
  #
  # Configuration:
  #   Pumice.configure do |config|
  #     config.pruning = {
  #       older_than: 90.days,          # OR newer_than: 30.days
  #       column: :created_at,
  #       only: %w[ifl_voice_logs debug_logs],  # OR
  #       except: %w[users messages],
  #     }
  #   end
  class Pruner
    Stats  = Struct.new(:total, :tables, keyword_init: true)

    attr_reader :config, :stats, :logger

    def initialize
      @config = Pumice.config.pruning
      @stats  = Stats.new(total: 0, tables: {})
      @logger = Pumice::Logger
    end

    def run
      return stats unless Pumice.pruning_enabled?

      pruning_config = Pumice.config.pruning
      column = pruning_config[:column]
      direction, age = resolve_direction(pruning_config)
      cutoff = resolve_cutoff(age)

      log_header(direction, age)

      Pumice::Progress.each(tables_to_prune, title: "Pruning") do |table_name|
        count = ActiveRecord::Base.transaction(requires_new: true) do
          prune_table(table_name, column, cutoff, direction)
        end
        stats.tables[table_name] = count if count > 0
        stats.total += count
      end

      log_footer

      stats
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
      overridden = sanitizer_pruned_tables

      ActiveRecord::Base.connection.tables.select do |table|
        next false unless Pumice.prune_table?(table)

        if overridden.include?(table)
          Pumice::Logger.log_progress("  #{table}: skipped (sanitizer defines its own prune)")
          next false
        end

        true
      end
    end

    def sanitizer_pruned_tables
      Pumice.sanitizers.each_with_object(Set.new) do |sanitizer, set|
        next unless sanitizer.prune_operation

        begin
          set << sanitizer.model_class.table_name
        rescue StandardError
          next
        end
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
        return count
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

    def log_header(direction, age)
      label = direction == :older_than ? 'older' : 'newer'
      Pumice::Logger.output.blank
      Pumice::Logger.output.line('Global Pruning', emoji: '✂️')
      Pumice::Logger.output.line("  Removing records #{label} than #{format_duration(age)}")
      Pumice::Logger.output.line("  #{Pumice.dry_run? ? '[DRY RUN]' : '[LIVE]'}")
    end

    def log_footer
      if stats.total > 0 || stats.tables.any?
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
