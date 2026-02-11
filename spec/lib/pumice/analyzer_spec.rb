# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Analyzer do
  subject(:analyzer) { described_class.new(**analyzer_options) }

  let(:analyzer_options) { {} }
  let(:connection) { ActiveRecord::Base.connection }

  # Shared helper to reduce mock setup noise
  def stub_row_count(table, count)
    allow(connection).to receive(:execute)
      .with("SELECT COUNT(*) FROM \"#{table}\"")
      .and_return([{ 'count' => count }])
  end

  describe '#table_sizes' do
    before do
      allow(connection).to receive(:execute).and_return(table_size_results)
      allow(connection).to receive(:quote).and_call_original
    end

    let(:table_size_results) do
      [
        { 'tablename' => 'large_table', 'size' => '100 MB', 'bytes' => 104857600 },
        { 'tablename' => 'medium_table', 'size' => '50 MB', 'bytes' => 52428800 },
        { 'tablename' => 'small_table', 'size' => '1 MB', 'bytes' => 1048576 }
      ]
    end

    it 'returns TableSize structs with name, size, and bytes' do
      expect(analyzer.table_sizes.first).to have_attributes(
        name: 'large_table',
        size: '100 MB',
        bytes: 104857600
      )
    end

    it 'returns all tables from query' do
      expect(analyzer.table_sizes.map(&:name)).to eq(%w[large_table medium_table small_table])
    end

    context 'with custom limit' do
      let(:analyzer_options) { { limit: 5 } }

      it 'includes limit in query' do
        analyzer.table_sizes

        expect(connection).to have_received(:execute)
          .with(a_string_matching(/LIMIT 5/))
      end
    end

    context 'with custom schema' do
      let(:analyzer_options) { { schema: 'custom_schema' } }

      before do
        allow(connection).to receive(:quote).with('custom_schema').and_return("'custom_schema'")
      end

      it 'filters by schema in query' do
        analyzer.table_sizes

        expect(connection).to have_received(:execute)
          .with(a_string_matching(/schemaname = 'custom_schema'/))
      end
    end

    context 'with empty results' do
      let(:table_size_results) { [] }

      it 'returns empty array' do
        expect(analyzer.table_sizes).to eq([])
      end
    end
  end

  describe '#total_bytes' do
    before do
      allow(connection).to receive(:execute).and_return(table_size_results)
      allow(connection).to receive(:quote).and_call_original
    end

    let(:table_size_results) do
      [
        { 'tablename' => 'table1', 'size' => '100 MB', 'bytes' => 100 },
        { 'tablename' => 'table2', 'size' => '50 MB', 'bytes' => 50 },
        { 'tablename' => 'table3', 'size' => '25 MB', 'bytes' => 25 }
      ]
    end

    it 'sums bytes from all tables' do
      expect(analyzer.total_bytes).to eq(175)
    end

    context 'with empty results' do
      let(:table_size_results) { [] }

      it 'returns zero' do
        expect(analyzer.total_bytes).to eq(0)
      end
    end

    context 'with nil bytes values' do
      let(:table_size_results) do
        [{ 'tablename' => 'table1', 'size' => '100 MB', 'bytes' => nil }]
      end

      it 'treats nil as zero' do
        expect(analyzer.total_bytes).to eq(0)
      end
    end
  end

  describe '#row_counts' do
    before do
      allow(connection).to receive(:quote_table_name) { |t| "\"#{t}\"" }
      allow(connection).to receive(:quote).and_call_original
    end

    context 'with explicit tables' do
      let(:analyzer_options) { { tables: %w[users posts] } }

      before do
        stub_row_count('users', 100)
        stub_row_count('posts', 50)
      end

      it 'returns RowCount for each table' do
        expect(analyzer.row_counts).to contain_exactly(
          have_attributes(table: 'users', count: 100),
          have_attributes(table: 'posts', count: 50)
        )
      end
    end

    context 'with symbol tables' do
      let(:analyzer_options) { { tables: [:users] } }

      before { stub_row_count('users', 100) }

      it 'converts to strings' do
        expect(analyzer.row_counts.first.table).to eq('users')
      end
    end

    context 'when table does not exist' do
      let(:analyzer_options) { { tables: %w[users nonexistent] } }

      before do
        stub_row_count('users', 100)
        allow(connection).to receive(:execute)
          .with('SELECT COUNT(*) FROM "nonexistent"')
          .and_raise(StandardError.new('relation does not exist'))
      end

      it 'skips the missing table' do
        expect(analyzer.row_counts.map(&:table)).to eq(['users'])
      end
    end

    context 'with tables from config' do
      before do
        allow(Pumice.config).to receive(:sensitive_tables).and_return(%w[configured_table])
        stub_row_count('configured_table', 42)
      end

      it 'uses configured tables when none provided' do
        expect(analyzer.row_counts.first.table).to eq('configured_table')
      end
    end
  end

  describe 'SQL injection prevention' do
    before do
      allow(connection).to receive(:execute).and_return([])
    end

    it 'quotes schema name' do
      dangerous_schema = "'; DROP TABLE users; --"
      allow(connection).to receive(:quote)
        .with(dangerous_schema)
        .and_return("'''; DROP TABLE users; --'")

      described_class.new(schema: dangerous_schema).table_sizes

      expect(connection).to have_received(:quote).with(dangerous_schema)
    end

    it 'converts limit to integer' do
      described_class.new(limit: 'DROP TABLE users;').table_sizes

      expect(connection).to have_received(:execute)
        .with(a_string_matching(/LIMIT 0/))
    end

    it 'uses quote_table_name for table names' do
      dangerous_table = 'users; DROP TABLE posts;'
      allow(connection).to receive(:quote_table_name)
        .with(dangerous_table)
        .and_return('"users; DROP TABLE posts;"')
      allow(connection).to receive(:execute)
        .with('SELECT COUNT(*) FROM "users; DROP TABLE posts;"')
        .and_raise(StandardError.new('relation does not exist'))

      described_class.new(tables: [dangerous_table]).row_counts

      expect(connection).to have_received(:quote_table_name).with(dangerous_table)
    end
  end
end
