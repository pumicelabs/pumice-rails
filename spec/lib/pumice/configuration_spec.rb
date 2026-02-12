# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice do
  before { Pumice.reset! }

  # Helper for ENV manipulation without external gems
  def with_env(vars)
    original = vars.keys.each_with_object({}) { |k, h| h[k] = ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end

  describe 'Configuration' do
    describe '.config' do
      it 'returns a Configuration instance' do
        expect(Pumice.config).to be_a(Pumice::Configuration)
      end

      it 'memoizes the instance' do
        expect(Pumice.config).to be(Pumice.config)
      end
    end

    describe '.configure' do
      it 'yields the config object' do
        yielded = nil
        Pumice.configure { |c| yielded = c }

        expect(yielded).to be(Pumice.config)
      end

      it 'allows setting configuration values', :aggregate_failures do
        Pumice.configure do |config|
          config.verbose = true
          config.strict = false
        end

        expect(Pumice.config.verbose).to be true
        expect(Pumice.config.strict).to be false
      end
    end

    describe 'default values' do
      subject(:config) { Pumice::Configuration.new }

      it 'sets sensible defaults', :aggregate_failures do
        expect(config.verbose).to be false
        expect(config.strict).to be true
        expect(config.continue_on_error).to be false
        expect(config.soft_scrubbing_configured?).to be false
        expect(config.soft_scrubbing).to be_nil  # returns nil when disabled
        expect(config.allow_keep_undefined_columns).to be true
      end

      it 'initializes collections as empty', :aggregate_failures do
        expect(config.sensitive_tables).to eq([])
        expect(config.sensitive_email_domains).to eq([])
      end

      it 'sets email validation defaults', :aggregate_failures do
        expect(config.sensitive_email_model).to eq('User')
        expect(config.sensitive_email_column).to eq('email')
      end

      it 'provides default soft_scrubbing options when enabled' do
        config.soft_scrubbing = {}
        expect(config.soft_scrubbing[:context]).to be_nil
        expect(config.soft_scrubbing[:policy].call(nil, nil)).to be true  # default: always scrub
      end

      it 'supports if: option for scrub condition' do
        config.soft_scrubbing = { if: ->(r, v) { v.nil? } }
        expect(config.soft_scrubbing[:policy].call(nil, nil)).to be true
        expect(config.soft_scrubbing[:policy].call(nil, 'viewer')).to be false
      end

      it 'supports unless: option with inverted logic' do
        config.soft_scrubbing = { unless: ->(r, v) { v&.is_a?(String) } }
        expect(config.soft_scrubbing[:policy].call(nil, nil)).to be true      # scrub when nil
        expect(config.soft_scrubbing[:policy].call(nil, 'admin')).to be false # don't scrub strings
      end

      it 'prefers if: over unless: when both provided' do
        config.soft_scrubbing = {
          if: ->(_r, _v) { true },
          unless: ->(_r, _v) { true }
        }
        expect(config.soft_scrubbing[:policy].call(nil, nil)).to be true
      end
    end

    describe 'collection setters' do
      subject(:config) { Pumice::Configuration.new }

      it 'normalizes sensitive_tables to strings' do
        config.sensitive_tables = [:users, 'messages']

        expect(config.sensitive_tables).to eq(%w[users messages])
      end

      it 'normalizes sensitive_email_domains to strings' do
        config.sensitive_email_domains = [:gmail, 'yahoo.com']

        expect(config.sensitive_email_domains).to eq(%w[gmail yahoo.com])
      end

      it 'flattens nested arrays' do
        config.sensitive_tables = [['users'], 'messages']

        expect(config.sensitive_tables).to eq(%w[users messages])
      end

      it 'removes nil values' do
        config.sensitive_tables = ['users', nil, 'messages']

        expect(config.sensitive_tables).to eq(%w[users messages])
      end
    end

    describe 'collection adders' do
      subject(:config) { Pumice::Configuration.new }

      it 'merges without duplicates' do
        config.sensitive_tables = ['users']
        config.add_sensitive_tables(['users', 'messages'])

        expect(config.sensitive_tables).to eq(%w[users messages])
      end
    end
  end

  describe 'Predicate Methods' do
    describe '.dry_run?' do
      it 'returns false by default' do
        expect(Pumice.dry_run?).to be false
      end

      it 'returns true when DRY_RUN=true' do
        with_env('DRY_RUN' => 'true') do
          expect(Pumice.dry_run?).to be true
        end
      end

      it 'returns false for other DRY_RUN values' do
        with_env('DRY_RUN' => '1') do
          expect(Pumice.dry_run?).to be false
        end
      end
    end

    describe '.verbose?' do
      it 'delegates to config.verbose' do
        expect { Pumice.config.verbose = true }
          .to change { Pumice.verbose? }.from(false).to(true)
      end
    end

    describe '.strict?' do
      it 'delegates to config.strict' do
        expect { Pumice.config.strict = false }
          .to change { Pumice.strict? }.from(true).to(false)
      end
    end

    describe '.soft_scrubbing?' do
      it 'returns true when soft_scrubbing is configured with a hash' do
        expect { Pumice.config.soft_scrubbing = {} }
          .to change { Pumice.soft_scrubbing? }.from(false).to(true)
      end

      it 'returns false when soft_scrubbing is false' do
        Pumice.config.soft_scrubbing = {}
        expect { Pumice.config.soft_scrubbing = false }
          .to change { Pumice.soft_scrubbing? }.from(true).to(false)
      end
    end

    describe '.allow_keep_undefined_columns?' do
      it 'delegates to config.allow_keep_undefined_columns' do
        expect { Pumice.config.allow_keep_undefined_columns = false }
          .to change { Pumice.allow_keep_undefined_columns? }.from(true).to(false)
      end
    end
  end

  describe 'Sanitizer Registry' do
    let(:test_sanitizer_class) do
      Class.new(Pumice::Sanitizer) do
        sanitizes :users

        def self.name
          'InlineTestSanitizer'
        end
      end
    end

    describe '.sanitizers' do
      it 'returns an array' do
        expect(Pumice.sanitizers).to be_an(Array)
      end

      it 'auto-registers sanitizers on inheritance' do
        test_sanitizer_class # trigger registration

        expect(Pumice.sanitizers).to include(test_sanitizer_class)
      end
    end

    describe '.register' do
      it 'adds sanitizer to the registry' do
        dummy = Class.new
        Pumice.register(dummy)

        expect(Pumice.sanitizers).to include(dummy)
      end

      it 'ignores duplicates' do
        dummy = Class.new
        Pumice.register(dummy)
        Pumice.register(dummy)

        expect(Pumice.sanitizers.count(dummy)).to eq(1)
      end
    end

    describe '.sanitizer_for' do
      it 'returns the sanitizer for a model class' do
        test_sanitizer_class

        expect(Pumice.sanitizer_for(User)).to eq(test_sanitizer_class)
      end

      it 'returns EmptySanitizer when no sanitizer exists' do
        expect(Pumice.sanitizer_for(String)).to eq(Pumice::EmptySanitizer)
      end

      it 'memoizes lookups' do
        test_sanitizer_class

        first_lookup = Pumice.sanitizer_for(User)
        second_lookup = Pumice.sanitizer_for(User)

        expect(first_lookup).to be(second_lookup)
      end
    end
  end

  describe '.reset!' do
    it 'clears the sanitizers registry' do
      Pumice.register(Class.new)

      expect { Pumice.reset! }
        .to change { Pumice.sanitizers.empty? }.from(false).to(true)
    end

    it 'clears the sanitizer map cache' do
      Pumice.sanitizer_for(User) # prime cache

      Pumice.reset!

      expect(Pumice.sanitizer_for(User)).to eq(Pumice::EmptySanitizer)
    end

    it 'resets configuration to defaults', :aggregate_failures do
      Pumice.config.verbose = true
      Pumice.config.strict = false

      Pumice.reset!

      expect(Pumice.config.verbose).to be false
      expect(Pumice.config.strict).to be true
    end
  end

  describe 'Pruning Configuration' do
    describe 'pruning_configured?' do
      it 'returns false when pruning is disabled' do
        expect(Pumice.config.pruning_configured?).to be false
      end

      it 'returns true when pruning is a hash' do
        Pumice.config.pruning = { older_than: 90.days }
        expect(Pumice.config.pruning_configured?).to be true
      end
    end

    describe 'pruning validation' do
      it 'raises when both older_than and newer_than are specified' do
        Pumice.config.pruning = { older_than: 90.days, newer_than: 30.days }

        expect { Pumice.config.pruning }
          .to raise_error(ArgumentError, /cannot specify both/)
      end

      it 'raises when neither older_than nor newer_than is specified' do
        Pumice.config.pruning = { column: :created_at }

        expect { Pumice.config.pruning }
          .to raise_error(ArgumentError, /requires either older_than: or newer_than:/)
      end

      it 'accepts newer_than' do
        Pumice.config.pruning = { newer_than: 30.days }

        config = Pumice.config.pruning
        expect(config[:newer_than]).to eq(30.days)
        expect(config[:older_than]).to be_nil
      end

      it 'defaults column to :created_at' do
        Pumice.config.pruning = { older_than: 90.days }

        expect(Pumice.config.pruning[:column]).to eq(:created_at)
      end

      it 'normalizes only list to strings' do
        Pumice.config.pruning = { older_than: 90.days, only: [:users, 'logs'] }

        expect(Pumice.config.pruning[:only]).to eq(%w[users logs])
      end
    end

    describe '.pruning_enabled?' do
      it 'returns false when not configured' do
        expect(Pumice.pruning_enabled?).to be false
      end

      it 'returns true when configured' do
        Pumice.config.pruning = { older_than: 90.days }

        expect(Pumice.pruning_enabled?).to be true
      end

      it 'returns false when PRUNE=false' do
        Pumice.config.pruning = { older_than: 90.days }

        with_env('PRUNE' => 'false') do
          expect(Pumice.pruning_enabled?).to be false
        end
      end
    end
  end

  describe 'Source Database URL Resolution' do
    subject(:config) { Pumice::Configuration.new }

    describe '#resolved_source_database_url' do
      it 'returns nil when source_database_url is nil' do
        expect(config.resolved_source_database_url).to be_nil
      end

      it 'returns the string when source_database_url is a string' do
        config.source_database_url = 'postgresql://localhost:5432/mydb'

        expect(config.resolved_source_database_url).to eq('postgresql://localhost:5432/mydb')
      end

      context 'when source_database_url is :auto' do
        before { config.source_database_url = :auto }

        it 'builds URL from ActiveRecord connection config' do
          db_config = instance_double(
            ActiveRecord::DatabaseConfigurations::HashConfig,
            configuration_hash: {
              adapter: 'postgresql',
              host: 'db',
              port: 5432,
              username: 'postgres',
              database: 'app_test'
            }
          )
          allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(db_config)

          result = config.resolved_source_database_url

          expect(result).to be_a(String)
          expect(result).to start_with('postgresql://')
          expect(result).to include('app_test')
        end

        it 'returns the url key directly when present in config hash' do
          url = 'postgresql://prod-host:5432/myapp'
          db_config = instance_double(
            ActiveRecord::DatabaseConfigurations::HashConfig,
            configuration_hash: { adapter: 'postgresql', url: url }
          )
          allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(db_config)

          expect(config.resolved_source_database_url).to eq(url)
        end

        it 'handles missing password (trust auth)' do
          db_config = instance_double(
            ActiveRecord::DatabaseConfigurations::HashConfig,
            configuration_hash: {
              adapter: 'postgresql',
              host: 'db',
              port: 5432,
              username: 'postgres',
              database: 'centralstation_dev'
            }
          )
          allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(db_config)

          expect(config.resolved_source_database_url).to eq('postgresql://postgres@db:5432/centralstation_dev')
        end

        it 'includes password when present' do
          db_config = instance_double(
            ActiveRecord::DatabaseConfigurations::HashConfig,
            configuration_hash: {
              adapter: 'postgresql',
              host: 'db',
              port: 5432,
              username: 'admin',
              password: 's3cret',
              database: 'mydb'
            }
          )
          allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(db_config)

          expect(config.resolved_source_database_url).to eq('postgresql://admin:s3cret@db:5432/mydb')
        end

        it 'defaults host to localhost and port to 5432' do
          db_config = instance_double(
            ActiveRecord::DatabaseConfigurations::HashConfig,
            configuration_hash: {
              adapter: 'postgresql',
              database: 'mydb'
            }
          )
          allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(db_config)

          expect(config.resolved_source_database_url).to eq('postgresql://localhost:5432/mydb')
        end

        it 'returns nil for non-postgresql adapters' do
          db_config = instance_double(
            ActiveRecord::DatabaseConfigurations::HashConfig,
            configuration_hash: { adapter: 'mysql2', host: 'db', database: 'mydb' }
          )
          allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(db_config)

          expect(config.resolved_source_database_url).to be_nil
        end

        it 'returns nil when database is blank' do
          db_config = instance_double(
            ActiveRecord::DatabaseConfigurations::HashConfig,
            configuration_hash: { adapter: 'postgresql', host: 'db' }
          )
          allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(db_config)

          expect(config.resolved_source_database_url).to be_nil
        end
      end
    end
  end

  describe '.lint!' do
    let(:complete_sanitizer) do
      Class.new(Pumice::Sanitizer) do
        sanitizes :users
        scrub(:email) { 'test@example.com' }
        scrub(:first_name) { 'Test' }
        scrub(:last_name) { 'User' }
        keep_undefined_columns!

        def self.name
          'CompleteSanitizer'
        end
      end
    end

    before do
      Pumice.config.allow_keep_undefined_columns = true
    end

    it 'returns empty array when all sanitizers have full coverage' do
      complete_sanitizer

      expect(Pumice.lint!).to eq([])
    end
  end
end
