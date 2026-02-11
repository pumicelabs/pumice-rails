# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::SoftScrubbing::Policy do
  before do
    Pumice.reset!
    described_class.reset!
  end

  after { described_class.reset! }

  describe '.context=' do
    it 'stores context in thread local' do
      described_class.context = 'test_context'

      expect(Thread.current[described_class::THREAD_KEY]).to eq('test_context')
    end
  end

  describe '.current' do
    context 'with object value' do
      it 'returns the object directly' do
        viewer = Object.new
        described_class.context = viewer

        expect(described_class.current).to eq(viewer)
      end
    end

    context 'with Proc context' do
      it 'calls proc with no args when arity is zero' do
        described_class.context = -> { 'from_proc' }

        expect(described_class.current).to eq('from_proc')
      end

      it 'calls proc with record when arity is non-zero' do
        record = double('record', id: 42)
        described_class.context = ->(r) { "record_#{r.id}" }

        result = described_class.current(record)

        expect(result).to eq('record_42')
      end
    end

    context 'with Symbol context' do
      it 'resolves from record when record responds to method' do
        record = double('record', viewer: 'record_viewer')
        described_class.context = :viewer

        result = described_class.current(record)

        expect(result).to eq('record_viewer')
      end

      it 'resolves from thread local as fallback' do
        Thread.current[:custom_key] = 'thread_value'
        described_class.context = :custom_key

        result = described_class.current

        expect(result).to eq('thread_value')
      ensure
        Thread.current[:custom_key] = nil
      end

      it 'returns nil when symbol cannot be resolved' do
        described_class.context = :nonexistent_method

        result = described_class.current

        expect(result).to be_nil
      end
    end

    context 'with String context' do
      # Strings are treated as symbols and resolved
      it 'resolves from thread local' do
        Thread.current[:string_key] = 'thread_value'
        described_class.context = 'string_key'

        result = described_class.current

        expect(result).to eq('thread_value')
      ensure
        Thread.current[:string_key] = nil
      end

      it 'returns nil when string method not found' do
        described_class.context = 'nonexistent'

        result = described_class.current

        expect(result).to be_nil
      end
    end

    context 'with nil context' do
      it 'uses config soft_scrubbing context' do
        # Config context is also resolved, so use a Proc
        Pumice.config.soft_scrubbing = { context: -> { 'config_context' } }

        result = described_class.current

        expect(result).to eq('config_context')
      end
    end
  end

  describe '.with_context' do
    it 'temporarily sets context for block' do
      viewer = Object.new
      described_class.context = 'original'

      described_class.with_context(viewer) do
        expect(described_class.current).to eq(viewer)
      end

      expect(Thread.current[described_class::THREAD_KEY]).to eq('original')
    end

    it 'restores context after exception' do
      viewer = Object.new
      described_class.context = viewer

      expect do
        described_class.with_context(Object.new) { raise 'test error' }
      end.to raise_error('test error')

      expect(described_class.current).to eq(viewer)
    end
  end

  describe '.enabled_for?' do
    let(:record) { double('record') }

    context 'when soft_scrubbing disabled' do
      before { allow(Pumice).to receive(:soft_scrubbing?).and_return(false) }

      it 'returns false' do
        expect(described_class.enabled_for?(record)).to be false
      end
    end

    context 'when soft_scrubbing enabled' do
      it 'calls config policy with record and viewer' do
        viewer = Object.new
        policy_called_with = nil
        Pumice.config.soft_scrubbing = {
          if: ->(r, v) do
            policy_called_with = [r, v]
            true
          end
        }

        described_class.context = viewer
        described_class.enabled_for?(record)

        expect(policy_called_with).to eq([record, viewer])
      end

      it 'returns policy result with if: option' do
        Pumice.config.soft_scrubbing = { if: ->(_r, _v) { false } }

        expect(described_class.enabled_for?(record)).to be false
      end

      it 'returns inverted result with unless: option' do
        Pumice.config.soft_scrubbing = { unless: ->(_r, _v) { true } }

        expect(described_class.enabled_for?(record)).to be false
      end
    end
  end

  describe '.reset!' do
    it 'clears thread local context' do
      described_class.context = 'some_value'

      described_class.reset!

      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end
  end
end
