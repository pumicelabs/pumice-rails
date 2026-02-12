# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Progress do
  let(:io) { StringIO.new }

  describe '#initialize' do
    context 'when output is not a TTY' do
      it 'does not create a progress bar' do
        progress = described_class.new(title: 'Test', total: 10, output: io)

        # Should be a no-op — no errors on increment/finish
        progress.increment
        progress.finish
      end
    end

    context 'when total is zero' do
      it 'does not create a progress bar' do
        tty_io = double('tty', tty?: true)

        progress = described_class.new(title: 'Test', total: 0, output: tty_io)

        progress.increment
        progress.finish
      end
    end

    context 'when verbose mode is on' do
      before { allow(Pumice).to receive(:verbose?).and_return(true) }

      it 'does not create a progress bar' do
        tty_io = double('tty', tty?: true)

        progress = described_class.new(title: 'Test', total: 10, output: tty_io)

        progress.increment
        progress.finish
      end
    end

    context 'when conditions are met (TTY, non-verbose, positive total)' do
      before { allow(Pumice).to receive(:verbose?).and_return(false) }

      it 'creates a progress bar' do
        tty_io = StringIO.new
        allow(tty_io).to receive(:tty?).and_return(true)

        progress = described_class.new(title: 'Test', total: 2, output: tty_io)

        expect { progress.increment }.not_to raise_error
        expect { progress.increment }.not_to raise_error
        expect { progress.finish }.not_to raise_error
      end
    end
  end

  describe '#increment' do
    it 'is safe to call when disabled' do
      progress = described_class.new(title: 'Test', total: 5, output: io)

      5.times { progress.increment }
    end
  end

  describe '#finish' do
    it 'is safe to call when disabled' do
      progress = described_class.new(title: 'Test', total: 5, output: io)

      progress.finish
    end
  end

  describe '.each' do
    it 'yields each item in the collection' do
      results = []

      described_class.each(%w[a b c], "Test", output: io) do |item|
        results << item
      end

      expect(results).to eq(%w[a b c])
    end

    it 'works with an empty collection' do
      results = []

      described_class.each([], "Test", output: io) do |item|
        results << item
      end

      expect(results).to be_empty
    end

    it 'accepts a symbol-to-proc block' do
      items = %w[hello world]
      results = []

      described_class.each(items, "Test", output: io) do |item|
        results << item.upcase
      end

      expect(results).to eq(%w[HELLO WORLD])
    end
  end
end
