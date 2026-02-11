# frozen_string_literal: true

module Pumice
  class Analyzer
    def initialize(limit: 20, schema: 'public', tables: nil)
      @limit = limit
      @schema = schema
      @tables = Array(tables || Pumice.config.sensitive_tables).map(&:to_s)
    end

    def table_sizes
      @sizes ||= fetch_table_sizes
    end

    def total_bytes
      @total ||= table_sizes.sum { |s| s.bytes.to_i }
    end

    def row_counts
      @row_counts ||= fetch_row_counts
    end

    private

    TableSize = Struct.new(:name, :size, :bytes, keyword_init: true)
    RowCount  = Struct.new(:table, :count, keyword_init: true)

    def fetch_table_sizes
      conn = ActiveRecord::Base.connection
      quoted_schema = conn.quote(@schema)

      sql = <<-SQL
        SELECT
          tablename,
          pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
          pg_total_relation_size(schemaname||'.'||tablename) AS bytes
        FROM pg_tables
        WHERE schemaname = #{quoted_schema}
        ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
        LIMIT #{@limit.to_i};
      SQL

      conn.execute(sql).map do |row|
        TableSize.new(
          name: row['tablename'],
          size: row['size'],
          bytes: row['bytes'].to_i
        )
      end
    end

    def fetch_row_counts
      @tables.filter_map do |table|
        count = fetch_row_count(table)
        RowCount.new(table: table, count: count) if count
      end
    end

    def fetch_row_count(table_name)
      conn = ActiveRecord::Base.connection
      quoted_table = conn.quote_table_name(table_name)
      conn.execute("SELECT COUNT(*) FROM #{quoted_table}").first['count'].to_i
    rescue StandardError
      nil
    end
  end
end
