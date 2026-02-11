# frozen_string_literal: true

require 'shellwords'

module Pumice
  class DumpGenerator
    class Result < Struct.new(:path, :size_bytes, :success, keyword_init: true)
      def size_mb
        (size_bytes / 1024.0 / 1024.0).round(2)
      end

      def success?
        success
      end

      def large?
        size_mb > 500
      end
    end

    attr_reader :output_dir, :output_file, :db_config

    def initialize(output_dir: nil, db_config: nil)
      @output_dir = output_dir || Rails.root.join('tmp')
      @db_config  = db_config  || ActiveRecord::Base.connection_db_config.configuration_hash
    end

    def generate(output_file: nil)
      output_file ||= build_output_path

      success = run_pg_dump(output_file)
      gzipped_path = "#{output_file}.gz"

      if success && File.exist?(gzipped_path)
        Result.new(
          path: gzipped_path,
          size_bytes: File.size(gzipped_path),
          success: true
        )
      else
        Result.new(path: nil, size_bytes: 0, success: false)
      end
    end

    def output_filename
      "scrubbed-#{Time.current.strftime('%Y-%m-%d')}.sql"
    end

    private

    def build_output_path
      File.join(@output_dir, output_filename)
    end

    def run_pg_dump(output_file)
      env = {}
      env['PGPASSWORD'] = db_config[:password] if db_config[:password]

      args = build_pg_dump_args(db_config, output_file)
      success = system(env, *args)

      return false unless success

      # Gzip the output file
      system('gzip', '-f', output_file)
    end

    def build_pg_dump_args(config, output_file)
      args = ['pg_dump']
      args.push('-h', config[:host]) if config[:host]
      args.push('-p', config[:port].to_s) if config[:port]
      args.push('-U', config[:username]) if config[:username]
      args.push('-d', config[:database])
      args.push('-F', 'p')

      # Optionally exclude post-data section (indexes, triggers, constraints)
      # This saves ~12GB but requires rebuilding indexes after import.
      # Set EXCLUDE_INDEXES=true to exclude them (faster import, requires post-processing)
      if ENV['EXCLUDE_INDEXES'] == 'true'
        args.push('--section=pre-data')
        args.push('--section=data')
        Pumice::Logger.log_progress("Excluding post-data section (indexes, triggers, constraints)")
      end

      # Exclude materialized view data by default (can be rebuilt after import)
      # Set EXCLUDE_MATVIEWS=false to include them
      unless ENV['EXCLUDE_MATVIEWS'] == 'false'
        matviews = get_materialized_views(config)
        matviews.each do |matview|
          args.push('--exclude-table-data', "public.#{matview}")
        end
        Pumice::Logger.log_progress("Excluding #{matviews.size} materialized views from dump (data can be rebuilt)")
      end

      args.push('-f', output_file)
      args
    end

    def get_materialized_views(config)
      conn_args = []
      conn_args.push('-h', config[:host]) if config[:host]
      conn_args.push('-p', config[:port].to_s) if config[:port]
      conn_args.push('-U', config[:username]) if config[:username]
      conn_args.push('-d', config[:database])
      conn_args.push('-t')
      conn_args.push('-c', "SELECT matviewname FROM pg_matviews WHERE schemaname = 'public'")

      env = {}
      env['PGPASSWORD'] = config[:password] if config[:password]

      output = `#{env.map { |k, v| "#{k}=#{v}" }.join(' ')} psql #{conn_args.join(' ')}`
      output.split("\n").map(&:strip).reject(&:empty?)
    end
  end
end
