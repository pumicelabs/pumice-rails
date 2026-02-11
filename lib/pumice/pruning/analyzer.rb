# frozen_string_literal: true

module Pumice
  module Pruning
    class Analyzer
      # Universal patterns for identifying log/activity/audit tables
      DEFAULT_TABLE_PATTERNS = %w[
        log
        event
        activity
        session
        history
        audit
        track
        analytic
      ].freeze

      Candidate = Struct.new(
        :table,
        :size,
        :size_bytes,
        :row_count,
        :oldest_date,
        :newest_date,
        :old_record_count,
        :old_record_ratio,
        :is_log_table,
        :has_dependencies,
        keyword_init: true
      ) do
        def confidence_level
          return :high if is_log_table && old_record_ratio > 0.5 && !has_dependencies
          return :medium if (is_log_table || old_record_ratio > 0.7) && !has_dependencies
          :low
        end

        def potential_savings
          (size_bytes * old_record_ratio).to_i
        end
      end

      Result = Struct.new(
        :high_confidence,
        :medium_confidence,
        :low_confidence,
        keyword_init: true
      ) do
        def all_candidates
          high_confidence + medium_confidence + low_confidence
        end

        def total_savings
          high_confidence.sum(&:potential_savings)
        end

        def recommended_tables
          high_confidence.map(&:table)
        end
      end

      attr_reader :retention_days, :min_table_size, :min_row_count

      def initialize(retention_days: nil, min_table_size: nil, min_row_count: nil)
        # Use provided values or fall back to config defaults
        config_defaults = if Pumice.config.pruning_configured?
                            {
                              retention_days: (Pumice.config.pruning[:older_than] / 1.day).to_i,
                              min_table_size: Pumice.config.pruning[:analyzer][:min_table_size],
                              min_row_count: Pumice.config.pruning[:analyzer][:min_row_count]
                            }
                          else
                            {
                              retention_days: 90,
                              min_table_size: 10_000_000,
                              min_row_count: 1000
                            }
                          end

        @retention_days = retention_days || config_defaults[:retention_days]
        @min_table_size = min_table_size || config_defaults[:min_table_size]
        @min_row_count = min_row_count || config_defaults[:min_row_count]
      end

      def analyze
        candidates = find_candidates
        categorize_candidates(candidates)
      end

      private

      def find_candidates
        tables = get_tables_with_timestamps
        candidates = []

        tables.each do |table_name, size_pretty, size_bytes|
          next if size_bytes < min_table_size

          begin
            stats = analyze_table(table_name)
            next unless stats[:row_count] > min_row_count

            candidates << Candidate.new(
              table: table_name,
              size: size_pretty,
              size_bytes: size_bytes,
              **stats
            )
          rescue StandardError => e
            # Skip tables that error during analysis
            Pumice::Logger.log_progress("Skipping #{table_name}: #{e.message}") if Pumice.verbose?
          end
        end

        candidates.sort_by { |c| -c.size_bytes }
      end

      def get_tables_with_timestamps
        ActiveRecord::Base.connection.execute(<<~SQL).values
          SELECT
            t.tablename,
            pg_size_pretty(pg_total_relation_size('public.' || t.tablename)) as size,
            pg_total_relation_size('public.' || t.tablename) as size_bytes
          FROM pg_tables t
          JOIN information_schema.columns c
            ON c.table_name = t.tablename
            AND c.table_schema = t.schemaname
            AND c.column_name = 'created_at'
          WHERE t.schemaname = 'public'
          ORDER BY pg_total_relation_size('public.' || t.tablename) DESC
          LIMIT 50
        SQL
      end

      def analyze_table(table_name)
        conn = ActiveRecord::Base.connection
        quoted_table = conn.quote_table_name(table_name)
        quoted_days = retention_days.to_i

        # Get row count and date range
        result = conn.execute(<<~SQL).first
          SELECT
            COUNT(*) as row_count,
            MIN(created_at) as oldest_date,
            MAX(created_at) as newest_date,
            COUNT(*) FILTER (WHERE created_at < NOW() - INTERVAL '#{quoted_days} days') as old_record_count
          FROM #{quoted_table}
        SQL

        row_count = result['row_count'].to_i
        old_record_count = result['old_record_count'].to_i
        old_record_ratio = row_count > 0 ? old_record_count.to_f / row_count : 0

        {
          row_count: row_count,
          oldest_date: result['oldest_date'],
          newest_date: result['newest_date'],
          old_record_count: old_record_count,
          old_record_ratio: old_record_ratio,
          is_log_table: log_table?(table_name),
          has_dependencies: has_dependencies?(table_name)
        }
      end

      def log_table?(table_name)
        # Check if table name suggests it's a log/activity/event table
        patterns = DEFAULT_TABLE_PATTERNS.dup

        # Add domain-specific patterns from configuration if pruning is configured
        if Pumice.config.pruning.is_a?(Hash)
          patterns += Pumice.config.pruning[:analyzer][:table_patterns]
        end

        patterns.any? { |pattern| table_name.include?(pattern) }
      end

      def has_dependencies?(table_name)
        conn = ActiveRecord::Base.connection
        quoted_name = conn.quote(table_name)

        # Check if other tables reference this table (foreign keys pointing TO this table)
        result = conn.execute(<<~SQL)
          SELECT COUNT(*) as ref_count
          FROM information_schema.table_constraints tc
          JOIN information_schema.constraint_column_usage ccu
            ON tc.constraint_name = ccu.constraint_name
          WHERE tc.constraint_type = 'FOREIGN KEY'
            AND ccu.table_name = #{quoted_name}
            AND tc.table_schema = 'public'
        SQL

        result.first['ref_count'].to_i > 0
      end

      def categorize_candidates(candidates)
        high = candidates.select { |c| c.confidence_level == :high }
        medium = candidates.select { |c| c.confidence_level == :medium }
        low = candidates.select { |c| c.confidence_level == :low }

        Result.new(
          high_confidence: high,
          medium_confidence: medium,
          low_confidence: low
        )
      end
    end
  end
end
