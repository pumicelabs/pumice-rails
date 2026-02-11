# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::DumpGenerator do
  describe Pumice::DumpGenerator::Result do
    describe '#size_mb' do
      it 'converts bytes to megabytes' do
        result = described_class.new(size_bytes: 1024 * 1024, success: true)

        expect(result.size_mb).to eq(1.0)
      end

      it 'rounds to 2 decimal places' do
        result = described_class.new(size_bytes: 1536 * 1024, success: true)

        expect(result.size_mb).to eq(1.5)
      end

      it 'handles zero bytes' do
        result = described_class.new(size_bytes: 0, success: false)

        expect(result.size_mb).to eq(0.0)
      end
    end

    describe '#success?' do
      it 'returns true when success is true' do
        result = described_class.new(success: true, size_bytes: 0)

        expect(result.success?).to be true
      end

      it 'returns false when success is false' do
        result = described_class.new(success: false, size_bytes: 0)

        expect(result.success?).to be false
      end
    end

    describe '#large?' do
      it 'returns true when size exceeds 500 MB' do
        result = described_class.new(size_bytes: 501 * 1024 * 1024, success: true)

        expect(result.large?).to be true
      end

      it 'returns false when size is under 500 MB' do
        result = described_class.new(size_bytes: 499 * 1024 * 1024, success: true)

        expect(result.large?).to be false
      end

      it 'returns false when size is exactly 500 MB' do
        result = described_class.new(size_bytes: 500 * 1024 * 1024, success: true)

        expect(result.large?).to be false
      end
    end
  end

  describe '#initialize' do
    it 'uses Rails tmp directory by default' do
      generator = described_class.new

      expect(generator.output_dir).to eq(Rails.root.join('tmp'))
    end

    it 'accepts custom output_dir' do
      generator = described_class.new(output_dir: '/custom/path')

      expect(generator.output_dir).to eq('/custom/path')
    end

    it 'uses current database config by default' do
      generator = described_class.new

      expect(generator.db_config).to be_a(Hash)
      expect(generator.db_config[:database]).to be_present
    end

    it 'accepts custom db_config' do
      custom_config = { host: 'localhost', database: 'test_db', username: 'user' }
      generator = described_class.new(db_config: custom_config)

      expect(generator.db_config).to eq(custom_config)
    end
  end

  describe '#output_filename' do
    it 'includes current date in YYYY-MM-DD format' do
      generator = described_class.new
      today = Date.current.strftime('%Y-%m-%d')

      expect(generator.output_filename).to eq("scrubbed-#{today}.sql")
    end

    it 'matches expected format pattern' do
      generator = described_class.new

      expect(generator.output_filename).to match(/^scrubbed-\d{4}-\d{2}-\d{2}\.sql$/)
    end

    it 'uses SQL extension' do
      generator = described_class.new

      expect(generator.output_filename).to end_with('.sql')
    end
  end

  describe '#generate' do
    let(:output_dir) { Rails.root.join('tmp', 'test_dumps') }
    let(:db_config) { { host: 'localhost', database: 'test', username: 'user', password: 'secret' } }
    let(:generator) { described_class.new(output_dir: output_dir, db_config: db_config) }

    before do
      FileUtils.mkdir_p(output_dir)
    end

    after do
      FileUtils.rm_rf(output_dir)
    end

    context 'when pg_dump succeeds' do
      let(:output_file) { File.join(output_dir, 'test.sql') }
      let(:gzipped_file) { "#{output_file}.gz" }

      before do
        # Create a fake dump file that will be "gzipped"
        File.write(output_file, 'fake sql content')
        # Simulate gzip creating the .gz file
        allow(generator).to receive(:system).and_return(true)
        File.write(gzipped_file, 'compressed content')
      end

      after do
        FileUtils.rm_f(output_file)
        FileUtils.rm_f(gzipped_file)
      end

      it 'returns successful result' do
        result = generator.generate(output_file: output_file)

        expect(result.success?).to be true
      end

      it 'returns path to gzipped file' do
        result = generator.generate(output_file: output_file)

        expect(result.path).to eq(gzipped_file)
      end

      it 'returns file size' do
        result = generator.generate(output_file: output_file)

        expect(result.size_bytes).to eq(File.size(gzipped_file))
      end
    end

    context 'when pg_dump fails' do
      before do
        allow(generator).to receive(:system).and_return(false)
      end

      it 'returns unsuccessful result' do
        result = generator.generate

        expect(result.success?).to be false
      end

      it 'returns nil path' do
        result = generator.generate

        expect(result.path).to be_nil
      end

      it 'returns zero size' do
        result = generator.generate

        expect(result.size_bytes).to eq(0)
      end
    end

    context 'when gzipped file does not exist' do
      before do
        # pg_dump succeeds but gzip fails
        call_count = 0
        allow(generator).to receive(:system) do
          call_count += 1
          call_count == 1 # pg_dump succeeds, gzip "fails" (no file created)
        end
      end

      it 'returns unsuccessful result' do
        result = generator.generate

        expect(result.success?).to be false
      end
    end
  end

  describe 'security: password handling' do
    let(:db_config) { { host: 'localhost', database: 'test', password: 'supersecret' } }
    let(:generator) { described_class.new(db_config: db_config) }

    it 'passes password via environment variable, not command line' do
      env_captured = nil
      args_captured = nil

      allow(generator).to receive(:system) do |env, *args|
        env_captured = env
        args_captured = args
        false # Return false to skip gzip
      end

      generator.generate

      expect(env_captured['PGPASSWORD']).to eq('supersecret')
      expect(args_captured.join(' ')).not_to include('supersecret')
    end

    it 'does not set PGPASSWORD when no password configured' do
      generator_no_pw = described_class.new(db_config: { database: 'test' })
      env_captured = nil

      allow(generator_no_pw).to receive(:system) do |env, *args|
        env_captured = env
        false
      end

      generator_no_pw.generate

      expect(env_captured).not_to have_key('PGPASSWORD')
    end
  end
end
