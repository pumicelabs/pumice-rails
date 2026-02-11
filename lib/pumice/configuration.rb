# frozen_string_literal: true

require_relative 'soft_scrubbing/policy'

module Pumice
  class Configuration
    attr_accessor :verbose, :strict, :continue_on_error,
                  :allow_keep_undefined_columns, :sensitive_tables, :sensitive_email_domains,
                  :sensitive_email_model, :sensitive_email_column, :default_verification,
                  # Validator configuration
                  :sensitive_token_columns,      # Token columns to verify are cleared (e.g., Devise tokens)
                  :sensitive_external_id_columns, # External ID columns to verify are cleared
                  # Safe scrub configuration
                  :source_database_url,   # Source database (read-only, never modified)
                  :target_database_url,   # Target database (scrubbed copy)
                  :export_path,           # Optional: path to export the scrubbed dump
                  :export_format,         # Export format: :custom (pg_dump -Fc) or :plain (SQL)
                  :require_readonly_source, # Enforce read-only source credentials (default: false, warns only)
                  # Pruning configuration
                  :pruning               # Delete old records before sanitization (see pruning_config)

    attr_writer :soft_scrubbing

    # Default verification policy for bulk operations.
    # Used when `verify` is called without a block.
    # Receives (model_class, bulk_operation) and returns a verification proc.
    # The bulk_operation hash contains :type (:truncate, :delete, :destroy) and :scope (optional block).
    DEFAULT_VERIFICATION_POLICY = lambda do |_model_class, bulk_operation|
      case bulk_operation[:type]
      when :truncate
        -> { count.zero? }
      when :delete, :destroy
        if bulk_operation[:scope]
          # Re-run the scope and check .none?
          bulk_operation[:scope]
        else
          -> { count.zero? }
        end
      end
    end

    def initialize
      @verbose = false
      @strict = true
      @continue_on_error = false
      @soft_scrubbing = false  # Disabled by default; set to hash to enable
      @allow_keep_undefined_columns = true
      @sensitive_tables = []
      @sensitive_email_domains = []
      @sensitive_email_model = 'User'
      @sensitive_email_column = 'email'
      @default_verification = DEFAULT_VERIFICATION_POLICY
      # Validator defaults (Devise-compatible)
      @sensitive_token_columns = %w[reset_password_token confirmation_token]
      @sensitive_external_id_columns = []
      # Safe scrub defaults
      @source_database_url = nil
      @target_database_url = nil
      @export_path = nil
      @export_format = :custom
      @require_readonly_source = false  # Warn by default, set true to enforce
      # Pruning defaults
      @pruning = false  # Disabled by default; set to hash to enable
    end

    # Returns true if soft_scrubbing config is set
    def soft_scrubbing_configured?
      @soft_scrubbing.is_a?(Hash)
    end

    # Returns normalized soft_scrubbing configuration
    # Overrides attr_writer getter to return normalized config
    def soft_scrubbing
      return nil unless soft_scrubbing_configured?

      {
        context: @soft_scrubbing.fetch(:context, nil),
        policy: resolve_soft_scrubbing_policy
      }
    end

    private

    # Resolves the policy from if:/unless: options
    # if: and unless: are mutually exclusive (if: takes precedence)
    def resolve_soft_scrubbing_policy
      if_condition = @soft_scrubbing[:if]
      unless_condition = @soft_scrubbing[:unless]

      if if_condition
        if_condition
      elsif unless_condition
        # Invert the unless condition
        ->(record, viewer) { !unless_condition.call(record, viewer) }
      else
        # Default: always scrub
        ->(_record, _viewer) { true }
      end
    end

    public

    # Returns true if pruning config is set (not checking ENV)
    def pruning_configured?
      @pruning.is_a?(Hash)
    end

    # Returns normalized pruning configuration
    # Overrides attr_accessor getter to return normalized config
    def pruning
      return nil unless Pumice.pruning_enabled?

      validate_pruning_config!

      {
        older_than: @pruning[:older_than],
        newer_than: @pruning[:newer_than],
        column: @pruning.fetch(:column, :created_at).to_sym,
        only: @pruning.fetch(:only, []).map(&:to_s),
        except: @pruning.fetch(:except, []).map(&:to_s),
        on_conflict: @pruning.fetch(:on_conflict, :warn).to_sym,
        analyzer: normalize_analyzer_config(@pruning.fetch(:analyzer, {}))
      }
    end

    private

    def validate_pruning_config!
      has_older = @pruning.key?(:older_than)
      has_newer = @pruning.key?(:newer_than)

      if has_older && has_newer
        raise ArgumentError,
          "Pruning config cannot specify both older_than and newer_than. " \
          "Use one or the other."
      end

      unless has_older || has_newer
        raise ArgumentError,
          "Pruning config requires either older_than: or newer_than: to specify " \
          "which records to prune."
      end

      on_conflict = @pruning.fetch(:on_conflict, :warn).to_sym
      unless %i[warn raise rollback].include?(on_conflict)
        raise ArgumentError,
          "Pruning on_conflict must be :warn, :raise, or :rollback, got #{on_conflict.inspect}"
      end
    end

    def normalize_analyzer_config(analyzer_config)
      {
        table_patterns: Array(analyzer_config.fetch(:table_patterns, [])).map(&:to_s),
        min_table_size: analyzer_config.fetch(:min_table_size, 10_000_000),  # 10 MB
        min_row_count: analyzer_config.fetch(:min_row_count, 1000)
      }
    end

    def database_url_from_rails_config
      config_hash = ActiveRecord::Base.connection_db_config.configuration_hash

      # Staging/production: config already has a url key
      return config_hash[:url] if config_hash[:url].present?

      # Development/test: build from components
      build_database_url(config_hash)
    end

    def build_database_url(config_hash)
      return nil unless config_hash[:adapter] == 'postgresql'

      host     = config_hash[:host] || 'localhost'
      port     = config_hash[:port] || 5432
      database = config_hash[:database]
      username = config_hash[:username]
      password = config_hash[:password]

      return nil if database.blank?

      userinfo = if username.present? && password.present?
                   "#{URI.encode_www_form_component(username)}:#{URI.encode_www_form_component(password)}@"
                 elsif username.present?
                   "#{URI.encode_www_form_component(username)}@"
                 else
                   ''
                 end

      "postgresql://#{userinfo}#{host}:#{port}/#{database}"
    end

    public

    # Resolves source_database_url, handling the :auto sentinel.
    # Returns a concrete URL string or nil.
    def resolved_source_database_url
      case @source_database_url
      when :auto then database_url_from_rails_config
      when String then @source_database_url
      end
    end

    def sensitive_tables=(value)
      @sensitive_tables = normalize_collection(value)
    end

    def sensitive_email_domains=(value)
      @sensitive_email_domains = normalize_collection(value)
    end

    def add_sensitive_tables(value)
      @sensitive_tables |= normalize_collection(value)
    end

    def add_sensitive_email_domains(value)
      @sensitive_email_domains |= normalize_collection(value)
    end

    private

    def normalize_collection(value)
      Array(value).flatten.compact.map(&:to_s)
    end
  end

  def self.config
    @config ||= Configuration.new
  end

  def self.configure
    yield(config)
    Pumice::SoftScrubbing.init! if config.soft_scrubbing_configured?
  end

  def self.dry_run?
    ENV['DRY_RUN'] == 'true'
  end

  def self.verbose?
    config.verbose
  end

  def self.strict?
    config.strict
  end

  def self.soft_scrubbing?
    config.soft_scrubbing_configured?
  end

  def self.allow_keep_undefined_columns?
    config.allow_keep_undefined_columns
  end

  def self.soft_scrubbing_context=(context)
    SoftScrubbing::Policy.context = context
  end

  def self.soft_scrubbing_context
    SoftScrubbing::Policy.current
  end

  def self.with_soft_scrubbing_context(context, &block)
    SoftScrubbing::Policy.with_context(context, &block)
  end

  def self.soft_scrubbing_enabled_for?(record)
    SoftScrubbing::Policy.enabled_for?(record)
  end

  # Returns true if pruning is configured and not disabled by ENV
  # Set PRUNE=false to disable pruning without changing config
  def self.pruning_enabled?
    return false if ENV['PRUNE'] == 'false'

    config.pruning_configured?
  end

  # Returns true if the given table should be pruned
  def self.prune_table?(table_name)
    return false unless pruning_enabled?

    pruning_config = config.pruning
    table = table_name.to_s

    if pruning_config[:only].present?
      pruning_config[:only].include?(table)
    elsif pruning_config[:except].present?
      !pruning_config[:except].include?(table)
    else
      true # Prune all tables if no filter specified
    end
  end

  def self.sanitizer_for(model_class)
    @sanitizer_map ||= {}
    @sanitizer_map[model_class] ||= sanitizers.find do |s|
      s.model_class == model_class
    rescue StandardError
      nil
    end

    @sanitizer_map[model_class] || Pumice::EmptySanitizer
  end

  def self.lint!
    issues = []

    sanitizers.each do |sanitizer|
      issues.concat(sanitizer.lint!)
    end

    if issues.any?
      puts "\n🔍 Pumice Lint Errors:\n"
      issues.each { |issue| puts "  ❌ #{issue}" }
      puts "\n"
    else
      puts "\n✅ Pumice: All sanitizers have complete coverage\n"
    end

    issues
  end

  def self.sanitizers
    @sanitizers ||= []
  end

  def self.register(sanitizer)
    sanitizers << sanitizer unless sanitizers.include?(sanitizer)
  end

  def self.reset!
    @sanitizers = []
    @sanitizer_map = {}
    @config = nil
    SoftScrubbing::Policy.reset!
  end
end
