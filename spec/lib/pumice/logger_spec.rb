# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Logger do
  let(:io) { StringIO.new }
  let(:mock_output) { Pumice::Output.new(io: io) }

  before do
    described_class.output = mock_output
    described_class.initialize_stats
  end

  after do
    described_class.output = nil
  end

  def written
    io.string
  end

  describe '.output' do
    it 'returns assigned output' do
      expect(described_class.output).to eq(mock_output)
    end

    it 'creates default Output when not set' do
      described_class.output = nil

      expect(described_class.output).to be_a(Pumice::Output)
    end
  end

  describe '.initialize_stats' do
    it 'resets stats to initial state' do
      described_class.log_record(:sanitized)
      described_class.initialize_stats

      described_class.summary

      expect(written).to include('Total records processed: 0')
    end
  end

  describe '.log_start' do
    it 'outputs sanitizer name' do
      described_class.log_start('UserSanitizer')

      expect(written).to include('UserSanitizer')
    end

    context 'when dry run' do
      before { allow(Pumice).to receive(:dry_run?).and_return(true) }

      it 'indicates dry run mode' do
        described_class.log_start('Test')

        expect(written).to include('DRY RUN')
      end
    end

    context 'when live' do
      before { allow(Pumice).to receive(:dry_run?).and_return(false) }

      it 'indicates live mode' do
        described_class.log_start('Test')

        expect(written).to include('LIVE')
      end
    end
  end

  describe '.log_progress' do
    context 'when verbose' do
      before { allow(Pumice).to receive(:verbose?).and_return(true) }

      it 'outputs message' do
        described_class.log_progress('Processing step')

        expect(written).to include('Processing step')
      end
    end

    context 'when not verbose' do
      before { allow(Pumice).to receive(:verbose?).and_return(false) }

      it 'suppresses output' do
        described_class.log_progress('Processing step')

        expect(written).to be_empty
      end
    end
  end

  describe '.log_record' do
    before { allow(Pumice).to receive(:verbose?).and_return(true) }

    it 'increments total records for any action' do
      described_class.log_record(:sanitized)
      described_class.log_record(:skipped)
      described_class.log_record(:error, 'oops')

      described_class.summary

      expect(written).to include('Total records processed: 3')
    end

    describe ':sanitized action' do
      it 'increments sanitized count' do
        described_class.log_record(:sanitized, 'ID 1')

        described_class.summary

        expect(written).to include('Sanitized: 1')
      end
    end

    describe ':would_sanitize action' do
      it 'increments would_sanitize count' do
        allow(Pumice).to receive(:dry_run?).and_return(true)

        described_class.log_record(:would_sanitize, 'ID 1 — email, name')

        described_class.summary

        expect(written).to include('Would sanitize: 1 records')
      end

      it 'outputs details in verbose mode' do
        described_class.log_record(:would_sanitize, 'ID 1 — email, name')

        expect(written).to include('~ ID 1 — email, name')
      end
    end

    describe ':skipped action' do
      it 'increments skipped count' do
        described_class.log_record(:skipped, 'ID 1')

        described_class.summary

        expect(written).to include('Skipped: 1')
      end
    end

    describe ':error action' do
      it 'increments error count' do
        described_class.log_record(:error, 'Something broke')

        described_class.summary

        expect(written).to include('Errors: 1')
      end

      it 'captures error details for summary' do
        described_class.log_record(:error, 'Something broke')

        described_class.summary

        expect(written).to include('Something broke')
      end
    end

    it 'initializes stats if needed' do
      # Reset to simulate uninitialized state
      described_class.instance_variable_set(:@stats, nil)

      described_class.log_record(:sanitized)
      described_class.summary

      expect(written).to include('Sanitized: 1')
    end
  end

  describe '.log_complete' do
    it 'outputs completion message with count' do
      described_class.log_complete('UserSanitizer', 42)

      expect(written).to include('Complete')
      expect(written).to include('42')
    end

    context 'when dry run' do
      before { allow(Pumice).to receive(:dry_run?).and_return(true) }

      it 'outputs would-affect message' do
        described_class.log_complete('UserSanitizer', 42)

        expect(written).to include('Would affect: 42 records')
        expect(written).not_to include('Complete')
      end
    end
  end

  describe '.log_error' do
    let(:error) { StandardError.new('Test error message') }

    before do
      error.set_backtrace(['line1', 'line2'])
      allow(Rails.logger).to receive(:error)
    end

    it 'outputs error message' do
      described_class.log_error('UserSanitizer', error)

      expect(written).to include('Test error message')
    end

    it 'logs to Rails logger' do
      described_class.log_error('UserSanitizer', error)

      expect(Rails.logger).to have_received(:error).at_least(:twice)
    end
  end

  describe '.summary' do
    it 'outputs nothing when stats not initialized' do
      described_class.instance_variable_set(:@stats, nil)

      described_class.summary

      expect(written).to be_empty
    end

    it 'outputs summary statistics' do
      described_class.log_record(:sanitized)
      described_class.log_record(:skipped)

      described_class.summary

      expect(written).to include('Sanitization Summary')
      expect(written).to include('Total records processed:')
      expect(written).to include('Sanitized:')
      expect(written).to include('Skipped:')
      expect(written).to include('Errors:')
      expect(written).to include('Duration:')
    end

    context 'when dry run' do
      before { allow(Pumice).to receive(:dry_run?).and_return(true) }

      it 'indicates dry run mode' do
        described_class.summary

        expect(written).to include('DRY RUN (no changes were made)')
      end

      it 'shows would-sanitize count instead of sanitized/skipped' do
        described_class.log_record(:would_sanitize, 'ID 1')
        described_class.log_record(:would_sanitize, 'ID 2')

        described_class.summary

        expect(written).to include('Would sanitize: 2 records')
        expect(written).not_to include('Sanitized:')
        expect(written).not_to include('Skipped:')
      end
    end

    it 'lists errors when present' do
      described_class.log_record(:error, 'First error')
      described_class.log_record(:error, 'Second error')

      described_class.summary

      expect(written).to include('Errors encountered:')
      expect(written).to include('First error')
      expect(written).to include('Second error')
    end
  end
end
