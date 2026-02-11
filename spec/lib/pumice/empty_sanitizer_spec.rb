# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::EmptySanitizer do
  before { Pumice.reset! }

  describe 'null object pattern' do
    it 'is not auto-registered in sanitizers list' do
      expect(Pumice.sanitizers).not_to include(described_class)
    end

    it 'is returned by sanitizer_for when no sanitizer exists' do
      # Use a model that doesn't have a dedicated sanitizer
      stub_const('UnknownModel', Class.new)

      sanitizer = Pumice.sanitizer_for(UnknownModel)

      expect(sanitizer).to eq(described_class)
    end
  end

  describe '.scrubbed_column?' do
    it 'always returns false' do
      expect(described_class.scrubbed_column?(:email)).to be false
      expect(described_class.scrubbed_column?(:any_column)).to be false
      expect(described_class.scrubbed_column?('password')).to be false
    end
  end

  describe '.sanitize' do
    it 'returns raw_value unchanged' do
      expect(described_class.sanitize(nil, :email, raw_value: 'test@example.com')).to eq('test@example.com')
      expect(described_class.sanitize(nil, :name, raw_value: 'John')).to eq('John')
      expect(described_class.sanitize(nil, :count, raw_value: 42)).to eq(42)
    end

    it 'returns nil when no raw_value provided' do
      expect(described_class.sanitize(nil, :email)).to be_nil
    end

    it 'ignores record and attr_name arguments' do
      record = double('record')
      result = described_class.sanitize(record, :email, raw_value: 'original')

      expect(result).to eq('original')
    end
  end

  describe '.scrubbed_columns' do
    it 'returns empty array' do
      expect(described_class.scrubbed_columns).to eq([])
    end
  end

  describe '.scrubbed' do
    it 'returns empty hash' do
      expect(described_class.scrubbed).to eq({})
    end
  end

  describe '.kept' do
    it 'returns empty array' do
      expect(described_class.kept).to eq([])
    end
  end

  describe '.model_class' do
    it 'returns nil' do
      expect(described_class.model_class).to be_nil
    end
  end

  describe '.friendly_name' do
    it 'returns empty' do
      expect(described_class.friendly_name).to eq('empty')
    end
  end

  describe 'Null Object contract' do
    it 'implements Sanitizer interface for safe polymorphic use' do
      # Verify EmptySanitizer responds to the same methods as a real sanitizer
      sanitizer_methods = %i[scrubbed_column? sanitize scrubbed_columns scrubbed kept model_class friendly_name]

      sanitizer_methods.each do |method|
        expect(described_class).to respond_to(method),
          "EmptySanitizer should respond to #{method}"
      end
    end

    it 'executes common sanitizer operations without raising errors' do
      # Simulate common usage patterns
      expect { described_class.scrubbed_column?(:email) }.not_to raise_error
      expect { described_class.sanitize(nil, :email, raw_value: 'x') }.not_to raise_error
      expect { described_class.scrubbed.keys }.not_to raise_error
      expect { described_class.kept.length }.not_to raise_error
    end
  end
end
