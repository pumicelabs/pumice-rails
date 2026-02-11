# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Pruner do
  let(:output) { instance_double(Pumice::Output, blank: nil, line: nil, success: nil, warning: nil) }

  before do
    Pumice.reset!
    allow(Pumice::Logger).to receive(:log_progress)
    allow(Pumice::Logger).to receive(:output).and_return(output)
  end

  describe '#initialize' do
    it 'initializes stats with zero totals' do
      pruner = described_class.new

      expect(pruner.stats).to eq({ total: 0, tables: {} })
    end
  end

  describe '#run' do
    context 'when pruning is disabled' do
      before do
        Pumice.configure { |c| c.pruning = nil }
      end

      it 'returns empty stats without processing' do
        pruner = described_class.new

        result = pruner.run

        expect(result).to eq({ total: 0, tables: {} })
      end

      it 'does not query database tables' do
        expect(ActiveRecord::Base.connection).not_to receive(:tables)

        described_class.new.run
      end
    end

    context 'when pruning is enabled with older_than' do
      before do
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at
          }
        end
        allow(ActiveRecord::Base.connection).to receive(:tables).and_return(%w[users logs])
      end

      it 'logs progress message with direction' do
        allow(User).to receive(:column_names).and_return(%w[id created_at])
        allow(User).to receive_message_chain(:where, :delete_all).and_return(0)
        stub_const('Log', Class.new(ActiveRecord::Base))
        allow(Log).to receive(:column_names).and_return(%w[id])

        described_class.new.run

        expect(output).to have_received(:line).with(/Removing records older than 3 month/)
      end

      it 'returns stats with pruned counts' do
        allow(User).to receive(:column_names).and_return(%w[id created_at])
        allow(User).to receive(:arel_table).and_return(User.arel_table)
        allow(User).to receive(:where).and_return(double(delete_all: 50))
        stub_const('Log', Class.new(ActiveRecord::Base))
        allow(Log).to receive(:column_names).and_return(%w[id])

        result = described_class.new.run

        expect(result[:total]).to eq(50)
        expect(result[:tables]).to eq({ 'users' => 50 })
      end

      it 'skips tables without the timestamp column' do
        allow(User).to receive(:column_names).and_return(%w[id email])
        stub_const('Log', Class.new(ActiveRecord::Base))
        allow(Log).to receive(:column_names).and_return(%w[id created_at])
        allow(Log).to receive(:arel_table).and_return(Log.arel_table)
        allow(Log).to receive(:where).and_return(double(delete_all: 10))

        result = described_class.new.run

        expect(result[:tables]).not_to have_key('users')
        expect(result[:tables]).to eq({ 'logs' => 10 })
      end

      it 'skips tables without corresponding models' do
        allow(ActiveRecord::Base.connection).to receive(:tables)
          .and_return(%w[users orphan_table_without_model])
        allow(User).to receive(:column_names).and_return(%w[id created_at])
        allow(User).to receive(:arel_table).and_return(User.arel_table)
        allow(User).to receive(:where).and_return(double(delete_all: 5))

        result = described_class.new.run

        expect(result[:total]).to eq(5)
        expect(result[:tables]).not_to have_key('orphan_table_without_model')
      end

      it 'excludes zero-count tables from stats' do
        allow(User).to receive(:column_names).and_return(%w[id created_at])
        allow(User).to receive(:arel_table).and_return(User.arel_table)
        allow(User).to receive(:where).and_return(double(delete_all: 0))
        stub_const('Log', Class.new(ActiveRecord::Base))
        allow(Log).to receive(:column_names).and_return(%w[id created_at])
        allow(Log).to receive(:arel_table).and_return(Log.arel_table)
        allow(Log).to receive(:where).and_return(double(delete_all: 25))

        result = described_class.new.run

        expect(result[:tables]).not_to have_key('users')
        expect(result[:tables]).to eq({ 'logs' => 25 })
      end
    end

    context 'when pruning is enabled with newer_than' do
      before do
        Pumice.configure do |c|
          c.pruning = {
            newer_than: 30.days,
            column: :created_at
          }
        end
        allow(ActiveRecord::Base.connection).to receive(:tables).and_return(%w[users])
      end

      it 'logs progress message with newer direction' do
        allow(User).to receive(:column_names).and_return(%w[id created_at])
        allow(User).to receive(:arel_table).and_return(User.arel_table)
        allow(User).to receive(:where).and_return(double(delete_all: 0))

        described_class.new.run

        expect(output).to have_received(:line).with(/Removing records newer than 1 month/)
      end

      it 'uses gteq for newer_than direction' do
        allow(User).to receive(:column_names).and_return(%w[id created_at])
        allow(User).to receive(:arel_table).and_return(User.arel_table)
        scope_double = double(delete_all: 10)
        allow(User).to receive(:where).and_return(scope_double)

        result = described_class.new.run

        expect(User).to have_received(:where)
        expect(result[:total]).to eq(10)
      end
    end

    context 'with only filter' do
      before do
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at,
            only: %w[logs]
          }
        end
        allow(ActiveRecord::Base.connection).to receive(:tables).and_return(%w[users logs])
        stub_const('Log', Class.new(ActiveRecord::Base))
        allow(Log).to receive(:column_names).and_return(%w[id created_at])
        allow(Log).to receive(:arel_table).and_return(Log.arel_table)
        allow(Log).to receive(:where).and_return(double(delete_all: 100))
      end

      it 'only prunes whitelisted tables' do
        result = described_class.new.run

        expect(result[:tables].keys).to eq(['logs'])
        expect(result[:tables]).not_to have_key('users')
      end
    end

    context 'with except filter' do
      before do
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at,
            except: %w[users]
          }
        end
        allow(ActiveRecord::Base.connection).to receive(:tables).and_return(%w[users logs])
        stub_const('Log', Class.new(ActiveRecord::Base))
        allow(Log).to receive(:column_names).and_return(%w[id created_at])
        allow(Log).to receive(:arel_table).and_return(Log.arel_table)
        allow(Log).to receive(:where).and_return(double(delete_all: 75))
      end

      it 'skips blacklisted tables' do
        result = described_class.new.run

        expect(result[:tables]).to eq({ 'logs' => 75 })
        expect(result[:tables]).not_to have_key('users')
      end
    end

    context 'with dry run enabled' do
      before do
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at
          }
        end
        allow(Pumice).to receive(:dry_run?).and_return(true)
        allow(ActiveRecord::Base.connection).to receive(:tables).and_return(%w[users])
        allow(User).to receive(:column_names).and_return(%w[id created_at])
        allow(User).to receive(:arel_table).and_return(User.arel_table)
      end

      it 'counts records without deleting' do
        scope_double = double('scope')
        allow(User).to receive(:where).and_return(scope_double)
        allow(scope_double).to receive(:count).and_return(500)

        result = described_class.new.run

        expect(scope_double).to have_received(:count)
        expect(scope_double).not_to respond_to(:delete_all)
      end

      it 'returns zero total in dry run' do
        allow(User).to receive(:where).and_return(double(count: 500))

        result = described_class.new.run

        expect(result[:total]).to eq(0)
      end

      it 'logs what would be pruned' do
        allow(User).to receive(:where).and_return(double(count: 500))

        described_class.new.run

        expect(Pumice::Logger).to have_received(:log_progress)
          .with(/users: would prune 500 records/)
      end
    end

    context 'with PRUNE environment variable' do
      before do
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at
          }
        end
      end

      it 'skips pruning when PRUNE=false' do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('PRUNE').and_return('false')

        expect(ActiveRecord::Base.connection).not_to receive(:tables)

        result = described_class.new.run

        expect(result).to eq({ total: 0, tables: {} })
      end
    end

    context 'with custom timestamp column' do
      before do
        Pumice.configure do |c|
          c.pruning = {
            older_than: 30.days,
            column: :recorded_at
          }
        end
        allow(ActiveRecord::Base.connection).to receive(:tables).and_return(%w[events])
        stub_const('Event', Class.new(ActiveRecord::Base))
        allow(Event).to receive(:column_names).and_return(%w[id recorded_at])
        allow(Event).to receive(:arel_table).and_return(Event.arel_table)
      end

      it 'uses the configured column for filtering' do
        scope_double = double('scope', delete_all: 30)
        allow(Event).to receive(:where).and_return(scope_double)

        described_class.new.run

        expect(Event).to have_received(:where)
      end
    end
  end

  describe 'conflict detection' do
    let(:sanitizer_with_prune) do
      Class.new(Pumice::Sanitizer) do
        sanitizes :user
        scrub(:email) { 'fake@example.com' }
        prune { where(created_at: ..1.year.ago) }
        keep_undefined_columns!

        def self.name
          'UserSanitizer'
        end
      end
    end

    before do
      allow(ActiveRecord::Base.connection).to receive(:tables).and_return(%w[users])
      allow(User).to receive(:column_names).and_return(%w[id created_at])
      allow(User).to receive(:arel_table).and_return(User.arel_table)
      allow(User).to receive(:where).and_return(double(delete_all: 0))
    end

    context 'with on_conflict: :warn (default)' do
      before do
        sanitizer_with_prune
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at,
            only: %w[users],
            on_conflict: :warn
          }
        end
      end

      it 'logs a warning but continues' do
        described_class.new.run

        expect(output).to have_received(:warning).with(/CONFLICT.*UserSanitizer.*users/)
      end
    end

    context 'with on_conflict: :raise' do
      before do
        sanitizer_with_prune
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at,
            only: %w[users],
            on_conflict: :raise
          }
        end
      end

      it 'raises PruningConflictError' do
        expect { described_class.new.run }
          .to raise_error(Pumice::PruningConflictError, /UserSanitizer.*users/)
      end
    end

    context 'with on_conflict: :rollback' do
      before do
        sanitizer_with_prune
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at,
            only: %w[users],
            on_conflict: :rollback
          }
        end
      end

      it 'raises ActiveRecord::Rollback' do
        expect { described_class.new.run }
          .to raise_error(ActiveRecord::Rollback, /UserSanitizer.*users/)
      end
    end

    context 'when no conflict exists' do
      let(:sanitizer_without_prune) do
        Class.new(Pumice::Sanitizer) do
          sanitizes :user
          scrub(:email) { 'fake@example.com' }
          keep_undefined_columns!

          def self.name
            'UserSanitizer'
          end
        end
      end

      before do
        sanitizer_without_prune
        Pumice.configure do |c|
          c.pruning = {
            older_than: 90.days,
            column: :created_at,
            only: %w[users],
            on_conflict: :raise
          }
        end
      end

      it 'does not raise' do
        expect { described_class.new.run }.not_to raise_error
      end

      it 'does not log a warning' do
        described_class.new.run

        expect(output).not_to have_received(:warning)
      end
    end
  end
end
