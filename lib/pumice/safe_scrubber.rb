# frozen_string_literal: true

require 'open3'

module Pumice
  class SafeScrubberError < StandardError; end
  class ConfigurationError < SafeScrubberError; end
  class SourceWriteAccessError < SafeScrubberError; end

  class SafeScrubber
    attr_reader :source_url, :target_url, :output

    def initialize(source_url: nil, target_url: nil, export_path: nil, export_format: nil, confirm: nil, require_readonly_source: nil)
      @source_url = source_url || Pumice.config.resolved_source_database_url || ENV['DATABASE_URL']
      @target_url = target_url || Pumice.config.target_database_url || ENV['SCRUBBED_DATABASE_URL']
      @export_path = export_path || Pumice.config.export_path
      @export_format = export_format || Pumice.config.export_format || :custom
      @confirm = confirm  # nil = prompt, true = auto-confirm, false = fail without prompt
      @require_readonly_source = require_readonly_source.nil? ? Pumice.config.require_readonly_source : require_readonly_source
      @output = Pumice::Output.new
    end

    def run
      validate_configuration!
      validate_source_readonly!
      confirm_target!

      log_header
      step('Creating fresh target database') { create_target_database }
      step('Copying data from source to target') { copy_database }
      step('Pruning old records') { run_pruning } if Pumice.pruning_enabled?
      step('Running sanitizers against target') { run_sanitizers }
      step('Verifying scrubbed data') { run_verification }

      if @export_path
        step('Exporting scrubbed database') { export_database }
      end

      log_success
    end

    private

    def validate_configuration!
      raise ConfigurationError, 'source_database_url is required' if @source_url.blank?
      raise ConfigurationError, 'target_database_url is required' if @target_url.blank?

      if @source_url == @target_url
        raise ConfigurationError,
          "SAFETY ERROR: source and target cannot be the same database!\n" \
          "  Source: #{anonymize_url(@source_url)}\n" \
          "  Target: #{anonymize_url(@target_url)}"
      end

      # Prevent targeting the primary DATABASE_URL
      primary_url = ENV['DATABASE_URL']
      if primary_url.present? && urls_match?(@target_url, primary_url)
        raise ConfigurationError,
          "SAFETY ERROR: target cannot be the primary DATABASE_URL!\n" \
          "  Target must be a separate database instance.\n" \
          "  Use a different database URL for the scrubbed copy."
      end
    end

    def validate_source_readonly!
      return unless source_has_write_access?

      message = <<~MSG
        SECURITY WARNING: Source database credentials have WRITE access!

        For maximum safety, the source connection should be read-only.
        This prevents accidental modifications to your production database.

        To fix this, create a read-only database user:

          CREATE ROLE pumice_readonly WITH LOGIN PASSWORD 'your_password';
          GRANT CONNECT ON DATABASE your_db TO pumice_readonly;
          GRANT USAGE ON SCHEMA public TO pumice_readonly;
          GRANT SELECT ON ALL TABLES IN SCHEMA public TO pumice_readonly;

        Then use this user in SOURCE_DATABASE_URL:
          postgres://pumice_readonly:password@host/database
      MSG

      if @require_readonly_source
        output.error(message)
        raise SourceWriteAccessError, 'Source database has write access. Use a read-only credential.'
      else
        output.warning(message)
        output.line("Continuing anyway (require_readonly_source is disabled)...")
        output.blank
      end
    end

    def source_has_write_access?
      test_table = "_pumice_write_test_#{SecureRandom.hex(4)}"

      with_connection(@source_url) do |conn|
        conn.transaction do
          conn.execute("CREATE TEMP TABLE #{conn.quote_table_name(test_table)} (id integer)")
          raise ActiveRecord::Rollback
        end
        # If we get here without error, we have write access
        true
      end
    rescue ActiveRecord::StatementInvalid => e
      # Permission denied = read-only (good!)
      if e.message.include?('permission denied') || e.message.include?('read-only')
        false
      else
        # Some other error, assume we might have write access to be safe
        output.warning("Could not verify source read-only status: #{e.message}")
        true
      end
    end

    def confirm_target!
      target_db = extract_db_name(@target_url)
      target_host = URI.parse(@target_url).host

      case @confirm
      when true
        # Auto-confirmed (CI/background mode)
        output.line("Target confirmed: #{target_db} on #{target_host}")
      when false
        # Explicit confirmation required but not provided
        raise ConfigurationError,
          "Confirmation required. Pass confirm: true or use interactive mode.\n" \
          "  Target: #{target_db} on #{target_host}"
      else
        # Interactive prompt
        prompt_for_confirmation(target_db, target_host)
      end
    end

    def prompt_for_confirmation(target_db, target_host)
      output.blank
      output.warning("WARNING: This will DESTROY and RECREATE the target database!")
      output.blank
      output.line("  Target database: #{target_db}")
      output.line("  Target host:     #{target_host}")
      output.blank
      output.line("All existing data in '#{target_db}' will be permanently deleted.")
      output.blank
      output.prompt("Type the database name '#{target_db}' to confirm: ")

      input = STDIN.gets&.chomp

      unless input == target_db
        raise ConfigurationError, "Confirmation failed. You entered '#{input}', expected '#{target_db}'"
      end

      output.line("Confirmed.")
    end

    def log_header
      output.header('Safe Scrub Mode', emoji: nil)
      output.line('Source database will NOT be modified')
      output.blank
      output.line("Source: #{anonymize_url(@source_url)}")
      output.line("Target: #{anonymize_url(@target_url)}")
      output.line("Export: #{@export_path || '(none)'}") if @export_path
      output.blank
    end

    def log_success
      output.blank
      output.divider
      output.success("Scrubbed database ready at: #{anonymize_url(@target_url)}")
      output.line("Export file: #{@export_path}") if @export_path
    end

    def step(message)
      output.line(">> #{message}...")
      yield
      output.line("   Done")
    rescue => e
      output.error("   Failed: #{e.message}")
      raise
    end

    def create_target_database
      target_uri = URI.parse(@target_url)
      target_db_name = target_uri.path[1..]

      # Connect to postgres system database to drop/create
      admin_url = @target_url.sub(/\/[^\/]+$/, '/postgres')

      with_connection(admin_url) do |conn|
        quoted_name = conn.quote(target_db_name)
        quoted_ident = conn.quote_table_name(target_db_name)

        # Terminate existing connections to target database
        conn.execute(<<~SQL)
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = #{quoted_name}
            AND pid <> pg_backend_pid()
        SQL

        # Drop and recreate
        conn.execute("DROP DATABASE IF EXISTS #{quoted_ident}")
        conn.execute("CREATE DATABASE #{quoted_ident}")
      end
    end

    def copy_database
      source_uri = URI.parse(@source_url)
      target_uri = URI.parse(@target_url)

      source_env = {}
      source_env['PGPASSWORD'] = source_uri.password if source_uri.password

      target_env = {}
      target_env['PGPASSWORD'] = target_uri.password if target_uri.password

      dump_args = build_pg_dump_args(source_uri)
      restore_args = build_psql_args(target_uri)

      # Use Open3.pipeline to safely pipe pg_dump to psql with separate env vars
      statuses = Open3.pipeline(
        [source_env, *dump_args],
        [target_env, *restore_args]
      )

      unless statuses.all?(&:success?)
        raise SafeScrubberError, 'Database copy failed'
      end
    end

    def run_pruning
      with_connection(@target_url) do
        pruner = Pumice::Pruner.new
        stats = pruner.run
        output.line("   Removed #{stats[:total]} old records from #{stats[:tables].size} tables")
      end
    end

    def run_sanitizers
      with_connection(@target_url) do
        runner = Pumice::Runner.new(verbose: Pumice.verbose?)
        runner.run_all
      end
    end

    def run_verification
      with_connection(@target_url) do
        result = Pumice::Validator.new.run

        if result.passed?
          output.line('   Validation passed - no PII leaks detected')
        else
          output.error("   Validation failed with #{result.errors.size} error(s):")
          result.errors.each { |error| output.bullet(error) }
          raise SafeScrubberError, 'Verification failed - PII detected in scrubbed database'
        end
      end
    end

    def export_database
      uri = URI.parse(@target_url)
      env = {}
      env['PGPASSWORD'] = uri.password if uri.password

      args = build_pg_dump_args(uri, format: @export_format, output_file: @export_path)
      success = system(env, *args)
      raise SafeScrubberError, 'Export failed' unless success

      size_mb = (File.size(@export_path) / 1024.0 / 1024.0).round(2)
      output.line("   Exported #{size_mb} MB to #{@export_path}")
    end

    def with_connection(url)
      original_config = ActiveRecord::Base.connection_db_config

      begin
        ActiveRecord::Base.establish_connection(url)
        yield ActiveRecord::Base.connection
      ensure
        ActiveRecord::Base.establish_connection(original_config)
      end
    end

    def build_pg_dump_args(uri, format: :plain, output_file: nil)
      format_flag = format == :custom ? '-Fc' : '-Fp'
      db_name = uri.path[1..]

      args = ['pg_dump', format_flag]
      args.push('-h', uri.host) if uri.host
      args.push('-p', (uri.port || 5432).to_s)
      args.push('-U', uri.user) if uri.user
      args.push('-f', output_file) if output_file
      args.push(db_name)
      args
    end

    def build_psql_args(uri)
      db_name = uri.path[1..]

      args = ['psql', '-q']
      args.push('-h', uri.host) if uri.host
      args.push('-p', (uri.port || 5432).to_s)
      args.push('-U', uri.user) if uri.user
      args.push(db_name)
      args
    end

    def anonymize_url(url)
      return '(not set)' if url.blank?

      uri = URI.parse(url)
      "#{uri.scheme}://#{uri.host}:#{uri.port || 5432}/#{uri.path[1..]}"
    rescue URI::InvalidURIError
      '(invalid url)'
    end

    def extract_db_name(url)
      URI.parse(url).path[1..]
    rescue URI::InvalidURIError
      '(unknown)'
    end

    def urls_match?(url1, url2)
      return false if url1.blank? || url2.blank?

      uri1 = URI.parse(url1)
      uri2 = URI.parse(url2)

      # Compare host, port, and database name
      uri1.host == uri2.host &&
        (uri1.port || 5432) == (uri2.port || 5432) &&
        uri1.path == uri2.path
    rescue URI::InvalidURIError
      false
    end
  end
end
