# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::SafeScrubber do
  before { Pumice.reset! }

  let(:source_url) { 'postgresql://readonly:pass@source-host:5432/prod_db' }
  let(:target_url) { 'postgresql://admin:pass@target-host:5432/scrubbed_db' }

  describe '#initialize' do
    it 'uses provided URLs' do
      scrubber = described_class.new(source_url: source_url, target_url: target_url)

      expect(scrubber.source_url).to eq(source_url)
      expect(scrubber.target_url).to eq(target_url)
    end

    it 'falls back to resolved config source_database_url' do
      Pumice.config.source_database_url = 'postgresql://config@host:5432/config_db'

      scrubber = described_class.new(target_url: target_url)

      expect(scrubber.source_url).to eq('postgresql://config@host:5432/config_db')
    end

    it 'falls back to ENV DATABASE_URL' do
      original = ENV['DATABASE_URL']
      ENV['DATABASE_URL'] = 'postgresql://env@host:5432/env_db'

      scrubber = described_class.new(target_url: target_url)

      expect(scrubber.source_url).to eq('postgresql://env@host:5432/env_db')
    ensure
      ENV['DATABASE_URL'] = original
    end
  end

  describe 'validate_configuration!' do
    it 'raises when source_url is blank' do
      scrubber = described_class.new(source_url: '', target_url: target_url)

      expect { scrubber.run }
        .to raise_error(Pumice::ConfigurationError, /source_database_url is required/)
    end

    it 'raises when target_url is blank' do
      scrubber = described_class.new(source_url: source_url, target_url: '')

      expect { scrubber.run }
        .to raise_error(Pumice::ConfigurationError, /target_database_url is required/)
    end

    it 'raises when source and target are the same' do
      same_url = 'postgresql://user:pass@host:5432/mydb'
      scrubber = described_class.new(source_url: same_url, target_url: same_url)

      expect { scrubber.run }
        .to raise_error(Pumice::ConfigurationError, /source and target cannot be the same/)
    end

    it 'raises when target matches DATABASE_URL' do
      db_url = 'postgresql://admin:pass@prod:5432/main_db'
      original = ENV['DATABASE_URL']
      ENV['DATABASE_URL'] = db_url

      scrubber = described_class.new(source_url: source_url, target_url: db_url)

      expect { scrubber.run }
        .to raise_error(Pumice::ConfigurationError, /target cannot be the primary DATABASE_URL/)
    ensure
      ENV['DATABASE_URL'] = original
    end
  end

  describe 'confirm_target!' do
    let(:scrubber) { described_class.new(source_url: source_url, target_url: target_url, confirm: confirm) }

    before do
      # Stub source write access check to avoid actual DB connection
      allow(scrubber).to receive(:source_has_write_access?).and_return(false)
    end

    context 'when confirm: true' do
      let(:confirm) { true }

      it 'auto-confirms without prompting' do
        allow(scrubber).to receive(:create_target_database)
        allow(scrubber).to receive(:copy_database)
        allow(scrubber).to receive(:run_sanitizers)
        allow(scrubber).to receive(:run_verification)

        expect { scrubber.run }.not_to raise_error
      end
    end

    context 'when confirm: false' do
      let(:confirm) { false }

      it 'raises ConfigurationError requiring confirmation' do
        expect { scrubber.run }
          .to raise_error(Pumice::ConfigurationError, /Confirmation required/)
      end
    end
  end

  describe 'anonymize_url' do
    it 'strips credentials from URLs' do
      scrubber = described_class.new(source_url: source_url, target_url: target_url, confirm: true)

      # Access via the output object — anonymized URLs appear in log_header
      allow(scrubber).to receive(:source_has_write_access?).and_return(false)
      allow(scrubber).to receive(:create_target_database)
      allow(scrubber).to receive(:copy_database)
      allow(scrubber).to receive(:run_sanitizers)
      allow(scrubber).to receive(:run_verification)

      output = scrubber.output
      allow(output).to receive(:line)
      allow(output).to receive(:header)
      allow(output).to receive(:blank)
      allow(output).to receive(:divider)
      allow(output).to receive(:success)

      scrubber.run

      # Verify the logged source URL does not contain credentials
      logged_lines = []
      expect(output).to have_received(:line).at_least(:once) do |msg, **_opts|
        logged_lines << msg if msg.is_a?(String)
      end

      source_line = logged_lines.find { |l| l.include?('Source:') }
      expect(source_line).not_to include('readonly')
      expect(source_line).not_to include('pass')
    end
  end

  describe 'urls_match?' do
    let(:scrubber) { described_class.new(source_url: source_url, target_url: target_url) }

    it 'matches URLs with same host, port, and database' do
      url1 = 'postgresql://user1:pass1@host:5432/db'
      url2 = 'postgresql://user2:pass2@host:5432/db'

      expect(scrubber.send(:urls_match?, url1, url2)).to be true
    end

    it 'does not match URLs with different databases' do
      url1 = 'postgresql://user@host:5432/db1'
      url2 = 'postgresql://user@host:5432/db2'

      expect(scrubber.send(:urls_match?, url1, url2)).to be false
    end

    it 'does not match URLs with different hosts' do
      url1 = 'postgresql://user@host1:5432/db'
      url2 = 'postgresql://user@host2:5432/db'

      expect(scrubber.send(:urls_match?, url1, url2)).to be false
    end

    it 'defaults port to 5432 when not specified' do
      url1 = 'postgresql://user@host/db'
      url2 = 'postgresql://user@host:5432/db'

      expect(scrubber.send(:urls_match?, url1, url2)).to be true
    end

    it 'returns false for blank URLs' do
      expect(scrubber.send(:urls_match?, '', source_url)).to be false
      expect(scrubber.send(:urls_match?, nil, source_url)).to be false
    end

    it 'returns false for invalid URLs' do
      expect(scrubber.send(:urls_match?, 'not a url', source_url)).to be false
    end
  end

  describe 'extract_db_name' do
    let(:scrubber) { described_class.new(source_url: source_url, target_url: target_url) }

    it 'extracts database name from URL' do
      expect(scrubber.send(:extract_db_name, 'postgresql://user@host:5432/my_database')).to eq('my_database')
    end

    it 'returns (unknown) for invalid URL' do
      expect(scrubber.send(:extract_db_name, 'not a url')).to eq('(unknown)')
    end
  end

  describe 'error class hierarchy' do
    it 'SafeScrubberError inherits from StandardError' do
      expect(Pumice::SafeScrubberError.superclass).to eq(StandardError)
    end

    it 'ConfigurationError inherits from SafeScrubberError' do
      expect(Pumice::ConfigurationError.superclass).to eq(Pumice::SafeScrubberError)
    end

    it 'SourceWriteAccessError inherits from SafeScrubberError' do
      expect(Pumice::SourceWriteAccessError.superclass).to eq(Pumice::SafeScrubberError)
    end
  end
end
