# frozen_string_literal: true

namespace :db do
  namespace :scrub do
    desc 'Analyze database table sizes before scrubbing'
    task analyze: :environment do
      out = Pumice::Output.new
      load_sanitizers!

      result = Pumice::Analyzer.new(limit: 20)

      out.header('Database Size Analysis', emoji: '📊')

      result.table_sizes.each do |ts|
        out.table_row(ts.name, ts.size)
      end

      out.divider
      out.line("Total (top 20 tables): #{out.human_size(result.total_bytes)}")
      out.blank
      out.line('Row counts:')

      result.row_counts.each do |rc|
        out.list_item(rc.table, out.with_delimiter(rc.count))
      end
    end

    desc 'Scrub PII from database (WARNING: destructive operation)'
    task all: :environment do
      out = Pumice::Output.new
      load_sanitizers!

      runner = Pumice::Runner.new(verbose: ENV['VERBOSE'] == 'true')

      out.warning('WARNING: This will scrub PII from the current database!')
      out.line('This operation is IRREVERSIBLE.')
      out.blank
      out.line("Current database: #{runner.database_name}")
      out.prompt("\nType 'yes' to continue: ")

      unless STDIN.gets.chomp.downcase == 'yes'
        out.error('Scrubbing cancelled')
        exit
      end

      out.blank
      out.line('Starting database sanitization with Pumice...')
      out.line("Mode: #{runner.mode}")
      out.blank

      runner.run_all
    end

    desc 'List available scrubbers'
    task list: :environment do
      out = Pumice::Output.new
      load_sanitizers!

      out.header('Available Sanitizers (Pumice)')
      out.blank

      Pumice.sanitizers.each do |klass|
        out.line("  #{klass.friendly_name.ljust(18)} - #{klass.name}")
      end

      out.blank
      out.divider
      out.blank
      out.line('Usage Examples:')
      out.line("  rake 'db:scrub:only[users]'                   # Scrub just users")
      out.line("  rake 'db:scrub:only[users,student_profiles]'  # Scrub multiple")
      out.line('  rake db:scrub:all                             # Scrub everything')
      out.blank
      out.line('Options:')
      out.line('  DRY_RUN=true rake db:scrub:all                # Preview without committing')
      out.line('  VERBOSE=true rake db:scrub:all                # Show detailed progress')
      out.blank
    end

    desc 'Lint all sanitizers for coverage (checks for undefined columns)'
    task lint: :environment do
      Pumice.configure { |c| c.strict = false }

      load_sanitizers!

      issues = Pumice.lint!
      exit(issues.any? ? 1 : 0)
    end

    desc "Scrub specific tables only, e.g. rake 'db:scrub:only[users,student_profiles]'"
    task :only, [:scrubbers_list] => :environment do |_t, args|
      out = Pumice::Output.new

      load_sanitizers!

      scrubbers = parse_scrubber_args(args)

      if scrubbers.empty?
        out.error("No scrubbers specified. Usage: rake 'db:scrub:only[users,student_profiles]'")
        out.blank
        out.line('Available scrubbers:')
        Pumice.sanitizers.each { |s| out.line("  - #{s.friendly_name}") }
        exit 1
      end

      runner = Pumice::Runner.new(verbose: ENV['VERBOSE'] == 'true')

      out.warning('WARNING: This will scrub PII from selected tables!')
      out.line('This operation is IRREVERSIBLE.')
      out.blank
      out.line("Current database: #{runner.database_name}")
      out.line("Selected scrubbers: #{scrubbers.join(', ')}")
      out.prompt("\nType 'yes' to continue: ")

      unless STDIN.gets.chomp.downcase == 'yes'
        out.error('Scrubbing cancelled')
        exit
      end

      out.blank
      out.line('🧹 Starting selective database sanitization...')
      out.line("Mode: #{runner.mode}")
      out.blank

      begin
        runner.run(scrubbers)
      rescue Pumice::Runner::UnknownSanitizerError => e
        out.warning(e.message)
        exit 1
      end
    end

    desc "Dry run scrub (no changes). Usage: rake db:scrub:test or rake 'db:scrub:test[users,schools]'"
    task :test, [:scrubbers_list] => :environment do |_t, args|
      ENV['DRY_RUN'] = 'true'

      out = Pumice::Output.new
      load_sanitizers!

      scrubbers = parse_scrubber_args(args)
      runner = Pumice::Runner.new(verbose: ENV['VERBOSE'] == 'true')

      out.header('Pumice Dry Run', emoji: nil)
      out.line("Database: #{runner.database_name}")
      out.line("Mode: #{runner.mode}")

      if scrubbers.any?
        out.line("Selected: #{scrubbers.join(', ')}")
        out.blank

        begin
          runner.run(scrubbers)
        rescue Pumice::Runner::UnknownSanitizerError => e
          out.warning(e.message)
          exit 1
        end
      else
        out.line('Scope: all sanitizers')
        out.blank
        runner.run_all
      end
    end

    desc 'Validate scrubbed database for PII leaks'
    task validate: :environment do
      out = Pumice::Output.new
      load_sanitizers!
      out.header('Validating scrubbed data...', emoji: '🔍')

      result = Pumice::Validator.new.run

      result.checks.each do |check|
        out.check("#{check.name}: #{check.count}") if check.passed
      end

      out.blank
      out.divider

      if result.passed?
        out.success('Validation passed! No PII leaks detected.')
      else
        out.error("Validation failed with #{result.errors.size} error(s):")
        result.errors.each { |error| out.bullet(error) }
        exit 1
      end

      out.divider
      out.blank
    end

    desc 'Generate scrubbed database dump (source database is NOT modified)'
    task generate: :environment do
      out = Pumice::Output.new
      load_sanitizers!

      source = ENV['SOURCE_DATABASE_URL'] || Pumice.config.resolved_source_database_url || ENV['DATABASE_URL']
      export_path = ENV['EXPORT_PATH'] || Rails.root.join('tmp', "scrubbed-#{Date.today}.sql.gz").to_s

      if source.blank?
        out.error("Source database URL could not be determined.\n" \
                  "  Set SOURCE_DATABASE_URL, DATABASE_URL, or config.source_database_url = :auto")
        exit 1
      end

      # Auto-generate temp target database from source URL
      source_uri = URI.parse(source)
      source_db = source_uri.path[1..]
      temp_db = "#{source_db}_scrubbed_temp"
      target = source.sub(%r{/[^/]+$}, "/#{temp_db}")

      out.header('Generate Scrubbed Database Dump', emoji: nil)
      out.blank
      out.line('This will:')
      out.line('  1. Create a temporary database copy')
      out.line('  2. Scrub all PII from the copy')
      out.line('  3. Verify the scrubbed data')
      out.line("  4. Export to #{export_path}")
      out.line('  5. Clean up the temporary database')
      out.blank
      out.line('The source database will NOT be modified.')
      out.blank

      begin
        Pumice::SafeScrubber.new(
          source_url: source,
          target_url: target,
          export_path: export_path,
          confirm: true  # Auto-confirm since we control the temp DB
        ).run

        size_mb = (File.size(export_path) / 1024.0 / 1024.0).round(2)
        out.success("Dump generated: #{export_path} (#{size_mb} MB)")
        out.warning('WARNING: Dump size exceeds 500 MB!') if size_mb > 500

        excluded_items = []
        excluded_items << 'indexes/triggers/constraints' if ENV['EXCLUDE_INDEXES'] == 'true'
        excluded_items << 'materialized views' unless ENV['EXCLUDE_MATVIEWS'] == 'false'

        if excluded_items.any?
          out.blank
          out.line('📋 Post-Import Instructions:')
          out.line("   Excluded: #{excluded_items.join(', ')}")
          out.line('   After importing, rebuild with:')
          out.blank
          out.line('   rake db:structure:load      # Rebuild indexes and constraints') if ENV['EXCLUDE_INDEXES'] == 'true'
          out.line('   rake db:matviews:refresh    # Rebuild materialized views') unless ENV['EXCLUDE_MATVIEWS'] == 'false'
          out.blank
        end
      ensure
        # Always clean up temp database
        cleanup_temp_database(source, temp_db, out)
      end
    end
  end
end

def load_sanitizers!
  Dir[Rails.root.join('app/sanitizers/**/*_sanitizer.rb')].each do |file|
    require_dependency file
  end
end

def cleanup_temp_database(source_url, temp_db_name, out)
  admin_url = source_url.sub(%r{/[^/]+$}, '/postgres')

  original_config = ActiveRecord::Base.connection_db_config
  ActiveRecord::Base.establish_connection(admin_url)

  conn = ActiveRecord::Base.connection
  quoted_name = conn.quote(temp_db_name)

  # Terminate connections to temp database before dropping
  conn.execute(<<~SQL)
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = #{quoted_name}
      AND pid <> pg_backend_pid()
  SQL

  conn.execute("DROP DATABASE IF EXISTS #{conn.quote_table_name(temp_db_name)}")
  out.line("Cleaned up temporary database: #{temp_db_name}")
rescue StandardError => e
  out.warning("Failed to cleanup temp database '#{temp_db_name}': #{e.message}")
ensure
  ActiveRecord::Base.establish_connection(original_config)
end

def parse_scrubber_args(args)
  scrubbers = []
  scrubbers = args[:scrubbers_list].split(',').map(&:strip) if args[:scrubbers_list].present?
  scrubbers += args.extras if args.extras.any?
  scrubbers.compact.uniq
end

namespace :db do
  namespace :matviews do
    desc 'Refresh materialized views. Usage: rake db:matviews:refresh or rake "db:matviews:refresh[view1,view2]"'
    task :refresh, [:views_list] => :environment do |_t, args|
      out = Pumice::Output.new
      out.header('Refreshing Materialized Views', emoji: '🔄')
      out.blank

      # Get all available materialized views from the database
      all_matviews = ActiveRecord::Base.connection.execute(<<~SQL).values.flatten
        SELECT matviewname FROM pg_matviews WHERE schemaname = 'public' ORDER BY matviewname
      SQL

      if all_matviews.empty?
        out.warning('No materialized views found in database')
        exit 0
      end

      # Parse requested views (or use all if none specified)
      requested_views = parse_matview_args(args)
      matviews_to_refresh = requested_views.empty? ? all_matviews : requested_views

      # Validate requested views exist
      if requested_views.any?
        invalid_views = requested_views - all_matviews
        if invalid_views.any?
          out.error("Unknown materialized view(s): #{invalid_views.join(', ')}")
          out.blank
          out.line('Available views:')
          all_matviews.each { |v| out.line("  - #{v}") }
          exit 1
        end
      end

      out.line("Refreshing #{matviews_to_refresh.size} view(s)#{requested_views.any? ? ' (selected)' : ' (all)'}")
      out.blank

      failed = []
      succeeded = []

      Pumice::Progress.each(matviews_to_refresh, "Views") do |matview|
        begin
          quoted_view = ActiveRecord::Base.connection.quote_table_name(matview)
          ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW #{quoted_view}")
          succeeded << matview
        rescue StandardError => e
          out.warning("  #{matview}: Failed: #{e.message}")
          failed << { name: matview, error: e.message }
        end
      end

      out.blank
      out.divider
      out.success("Refreshed #{succeeded.size}/#{matviews_to_refresh.size} views")

      if failed.any?
        out.blank
        out.warning("#{failed.size} view(s) failed to refresh:")
        failed.each { |f| out.line("  • #{f[:name]}: #{f[:error]}") }
        exit 1
      end
    end

    desc 'List all materialized views'
    task list: :environment do
      out = Pumice::Output.new
      out.header('Materialized Views', emoji: '📊')
      out.blank

      matviews = ActiveRecord::Base.connection.execute(<<~SQL)
        SELECT
          matviewname,
          pg_size_pretty(pg_total_relation_size('public.' || matviewname)) as size
        FROM pg_matviews
        WHERE schemaname = 'public'
        ORDER BY pg_total_relation_size('public.' || matviewname) DESC
      SQL

      if matviews.values.empty?
        out.warning('No materialized views found')
        exit 0
      end

      matviews.values.each do |name, size|
        out.line("  #{name.ljust(50)} #{size}")
      end

      out.blank
      out.divider
      out.line("Total: #{matviews.values.size} views")
      out.blank
      out.line('Usage:')
      out.line('  rake db:matviews:refresh                             # Refresh all')
      out.line('  rake "db:matviews:refresh[students,tutor_sessions]"  # Refresh specific')
      out.blank
    end
  end
end

def parse_matview_args(args)
  views = []
  views = args[:views_list].split(',').map(&:strip) if args[:views_list].present?
  views += args.extras if args.extras.any?
  views.compact.uniq
end

namespace :db do
  namespace :prune do
    desc 'Analyze database tables to recommend pruning candidates'
    task analyze: :environment do
      out = Pumice::Output.new
      out.header('Database Pruning Analysis', emoji: '🔍')
      out.blank

      # Get defaults from config if pruning is configured
      config_defaults = if Pumice.config.pruning_configured?
                          pruning = Pumice.config.pruning
                          age = pruning[:older_than] || pruning[:newer_than]
                          {
                            retention_days: age.is_a?(ActiveSupport::Duration) ? (age / 1.day).to_i : 90,
                            min_size: pruning[:analyzer][:min_table_size],
                            min_rows: pruning[:analyzer][:min_row_count]
                          }
                        else
                          {
                            retention_days: 90,
                            min_size: 10_000_000,  # 10 MB
                            min_rows: 1000
                          }
                        end

      # ENV variables override config values
      retention_days = ENV['RETENTION_DAYS']&.to_i || config_defaults[:retention_days]
      min_size = ENV['MIN_SIZE']&.to_i || config_defaults[:min_size]
      min_rows = ENV['MIN_ROWS']&.to_i || config_defaults[:min_rows]

      out.line("Analyzing tables with retention: #{retention_days} days")
      out.line("Minimum table size: #{out.human_size(min_size)}")
      out.line("Minimum row count: #{min_rows}")
      out.blank

      analyzer = Pumice::Pruning::Analyzer.new(
        retention_days: retention_days,
        min_table_size: min_size,
        min_row_count: min_rows
      )

      result = analyzer.analyze

      # High confidence candidates
      if result.high_confidence.any?
        out.success("High Confidence Candidates (#{result.high_confidence.size})")
        out.line('Log tables with >50% old records and no dependencies')
        out.blank

        result.high_confidence.each do |candidate|
          out.line("  #{candidate.table.ljust(35)} #{candidate.size.rjust(10)}")
          out.line("    #{candidate.row_count} rows, #{(candidate.old_record_ratio * 100).round(1)}% older than #{retention_days} days")
          out.line("    Potential savings: #{out.human_size(candidate.potential_savings)}")
          out.blank
        end
      else
        out.line('No high confidence candidates found')
        out.blank
      end

      # Medium confidence candidates
      if result.medium_confidence.any?
        out.warning("Medium Confidence Candidates (#{result.medium_confidence.size})")
        out.line('Log tables or >70% old records, but no dependencies')
        out.blank

        result.medium_confidence.each do |candidate|
          out.line("  #{candidate.table.ljust(35)} #{candidate.size.rjust(10)}")
          out.line("    #{candidate.row_count} rows, #{(candidate.old_record_ratio * 100).round(1)}% older than #{retention_days} days")
          out.line("    Potential savings: #{out.human_size(candidate.potential_savings)}")
          out.blank
        end
      end

      # Low confidence candidates
      if result.low_confidence.any?
        out.line("Low Confidence Candidates (#{result.low_confidence.size})")
        out.line('Review carefully before pruning')
        out.blank

        result.low_confidence.each do |candidate|
          out.line("  #{candidate.table.ljust(35)} #{candidate.size.rjust(10)}")
          reasons = []
          reasons << 'has dependencies' if candidate.has_dependencies
          reasons << 'not a log table' unless candidate.is_log_table
          reasons << "only #{(candidate.old_record_ratio * 100).round(1)}% old" if candidate.old_record_ratio < 0.5
          out.line("    (#{reasons.join(', ')})")
          out.blank
        end
      end

      # Recommendations
      out.divider
      out.blank

      if result.high_confidence.any?
        out.success("Recommended Configuration:")
        out.blank
        out.line("Add to config/initializers/pumice.rb:")
        out.blank
        out.line("  config.pruning = {")
        out.line("    older_than: #{retention_days}.days,")
        out.line("    column: :created_at,")
        out.line("    only: %w[")
        result.high_confidence.each do |c|
          out.line("      #{c.table}")
        end
        out.line("    ]")
        out.line("  }")
        out.blank
        out.line("Estimated space savings: #{out.human_size(result.total_savings)}")
      else
        out.warning('No high-confidence pruning candidates found.')
        out.line('Consider adjusting RETENTION_DAYS or MIN_SIZE parameters.')
      end

      out.blank
      out.divider
      out.blank
      out.line('Options:')
      out.line('  RETENTION_DAYS=90  rake db:prune:analyze   # Analyze with 90-day retention')
      out.line('  MIN_SIZE=1000000   rake db:prune:analyze   # Minimum 1 MB tables')
      out.line('  MIN_ROWS=500       rake db:prune:analyze   # Minimum 500 rows')
      out.blank
    end
  end
end

namespace :db do
  namespace :scrub do
    desc 'Create a safe scrubbed copy of the database (source is NEVER modified)'
    task safe: :environment do
      out = Pumice::Output.new
      source = ENV['SOURCE_DATABASE_URL'] || Pumice.config.resolved_source_database_url || ENV['DATABASE_URL']
      target = ENV['TARGET_DATABASE_URL'] || Pumice.config.target_database_url || ENV['SCRUBBED_DATABASE_URL']
      export_path = ENV['EXPORT_PATH'] || Pumice.config.export_path

      out.header('Safe Database Scrub', emoji: nil)
      out.blank
      out.line('This will:')
      out.line('  1. Create a fresh copy of the source database')
      out.line('  2. Scrub all PII from the copy')
      out.line('  3. Verify the scrubbed data')
      out.line("  4. Export to #{export_path}") if export_path
      out.blank
      out.line('The source database will NOT be modified.')
      out.blank

      if source.blank?
        out.error('SOURCE_DATABASE_URL is required')
        out.line('Set via: SOURCE_DATABASE_URL=postgres://... or Pumice.config.source_database_url')
        exit 1
      end

      if target.blank?
        out.error('TARGET_DATABASE_URL is required')
        out.line('Set via: TARGET_DATABASE_URL=postgres://... or Pumice.config.target_database_url')
        exit 1
      end

      # Interactive mode: SafeScrubber will prompt for database name confirmation
      Pumice::SafeScrubber.new(
        source_url: source,
        target_url: target,
        export_path: export_path,
        confirm: nil  # Interactive prompt
      ).run
    end

    desc "Safe scrub with explicit confirmation. Usage: rake 'db:scrub:safe_confirmed[target_db_name]'"
    task :safe_confirmed, [:confirm_target] => :environment do |_t, args|
      out = Pumice::Output.new
      source = ENV['SOURCE_DATABASE_URL'] || Pumice.config.resolved_source_database_url || ENV['DATABASE_URL']
      target = ENV['TARGET_DATABASE_URL'] || Pumice.config.target_database_url || ENV['SCRUBBED_DATABASE_URL']
      export_path = ENV['EXPORT_PATH'] || Pumice.config.export_path
      confirm_value = args[:confirm_target]

      if source.blank?
        out.error('SOURCE_DATABASE_URL is required')
        exit 1
      end

      if target.blank?
        out.error('TARGET_DATABASE_URL is required')
        exit 1
      end

      # Extract the actual target database name for validation
      target_db_name = URI.parse(target).path[1..] rescue nil

      if confirm_value.blank?
        out.error('Confirmation argument required')
        out.blank
        out.line('For automated/CI execution, you must confirm by typing the target database name:')
        out.line("  rake 'db:scrub:safe_confirmed[#{target_db_name}]'")
        out.blank
        out.line('For interactive mode, use: rake db:scrub:safe')
        exit 1
      end

      if confirm_value != target_db_name
        out.error("Confirmation mismatch!")
        out.line("  Expected: #{target_db_name}")
        out.line("  Received: #{confirm_value}")
        exit 1
      end

      Pumice::SafeScrubber.new(
        source_url: source,
        target_url: target,
        export_path: export_path,
        confirm: true  # Pre-confirmed via argument
      ).run
    end
  end
end
