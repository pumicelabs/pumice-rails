# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Runner do
  subject(:runner) { described_class.new }

  before { Pumice.reset! }

  # Minimal sanitizer for testing registration and lookup behavior
  let(:test_sanitizer) do
    Class.new(Pumice::Sanitizer) do
      sanitizes :users
      friendly_name 'test_users'
      keep_undefined_columns!

      def self.name
        'TestUserSanitizer'
      end
    end
  end

  describe '.available' do
    it 'returns friendly names of registered sanitizers' do
      test_sanitizer

      expect(described_class.available).to include('test_users')
    end
  end

  describe '.find' do
    it 'returns sanitizer by friendly name' do
      test_sanitizer

      expect(described_class.find('test_users')).to eq(test_sanitizer)
    end

    it 'returns nil for unknown name' do
      expect(described_class.find('nonexistent')).to be_nil
    end

    it 'accepts symbol as name' do
      test_sanitizer

      expect(described_class.find(:test_users)).to eq(test_sanitizer)
    end
  end

  describe '#initialize' do
    it 'sets verbose mode in config' do
      described_class.new(verbose: true)

      expect(Pumice.config.verbose).to be true
    end

    it 'defaults verbose to false' do
      described_class.new

      expect(Pumice.config.verbose).to be false
    end
  end

  describe 'sanitizer execution' do
    before do
      test_sanitizer
      allow(Pumice::Logger).to receive(:initialize_stats)
      allow(Pumice::Logger).to receive(:summary)
      allow(test_sanitizer).to receive(:scrub_all!)
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
    end

    describe '#run_all' do
      it 'runs all available sanitizers' do
        runner.run_all

        expect(test_sanitizer).to have_received(:scrub_all!)
      end
    end

    describe '#run' do
      it 'runs specified sanitizers by name' do
        runner.run(['test_users'])

        expect(test_sanitizer).to have_received(:scrub_all!)
      end

      it 'raises for unknown sanitizer' do
        expect { runner.run(['unknown']) }
          .to raise_error(Pumice::Runner::UnknownSanitizerError, /unknown/)
      end

      it 'wraps execution in transaction' do
        runner.run(['test_users'])

        expect(ActiveRecord::Base).to have_received(:transaction)
      end

      it 'logs summary after completion' do
        runner.run(['test_users'])

        expect(Pumice::Logger).to have_received(:summary)
      end
    end
  end

  describe 'global pruning integration' do
    before do
      test_sanitizer
      allow(Pumice::Logger).to receive(:initialize_stats)
      allow(Pumice::Logger).to receive(:summary)
      allow(test_sanitizer).to receive(:scrub_all!)
      allow(ActiveRecord::Base).to receive(:transaction).and_yield
    end

    context 'when pruning is enabled' do
      let(:pruner) { instance_double(Pumice::Pruner, run: { total: 5, tables: {} }) }

      before do
        Pumice.configure do |c|
          c.pruning = { older_than: 90.days, column: :created_at, only: %w[users] }
        end
        allow(Pumice::Pruner).to receive(:new).and_return(pruner)
      end

      it 'runs global pruning before sanitizers' do
        call_order = []
        allow(pruner).to receive(:run) { call_order << :pruner; { total: 0, tables: {} } }
        allow(test_sanitizer).to receive(:scrub_all!) { call_order << :sanitizer }

        runner.run(['test_users'])

        expect(call_order).to eq(%i[pruner sanitizer])
      end

      it 'creates a Pruner and calls run' do
        runner.run(['test_users'])

        expect(Pumice::Pruner).to have_received(:new)
        expect(pruner).to have_received(:run)
      end
    end

    context 'when pruning is disabled' do
      before do
        Pumice.config.pruning = false
      end

      it 'does not create a Pruner' do
        allow(Pumice::Pruner).to receive(:new)

        runner.run(['test_users'])

        expect(Pumice::Pruner).not_to have_received(:new)
      end
    end
  end

  describe '#database_name' do
    it 'returns current database name', :aggregate_failures do
      result = runner.database_name

      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end

  describe '#mode' do
    context 'when dry run' do
      before { allow(Pumice).to receive(:dry_run?).and_return(true) }

      it 'returns DRY RUN' do
        expect(runner.mode).to eq('DRY RUN')
      end
    end

    context 'when live' do
      before { allow(Pumice).to receive(:dry_run?).and_return(false) }

      it 'returns LIVE' do
        expect(runner.mode).to eq('LIVE')
      end
    end
  end
end
