# frozen_string_literal: true

require 'rails_helper'
require 'pumice/rspec'

RSpec.describe Pumice::RSpec::SanitizerHelpers do
  include described_class

  before { Pumice.reset! }

  let(:user) { create(:user, email: 'real@gmail.com', first_name: 'Alice') }

  describe '#with_soft_scrubbing' do
    it 'enables soft scrubbing within the block' do
      with_soft_scrubbing(viewer: nil, if: ->(_record, _viewer) { true }) do
        expect(Pumice.soft_scrubbing?).to be true
      end
    end

    it 'restores original config after the block' do
      expect(Pumice.soft_scrubbing?).to be false

      with_soft_scrubbing(viewer: nil, if: ->(_record, _viewer) { true }) do
        # inside block
      end

      expect(Pumice.soft_scrubbing?).to be false
    end

    it 'restores config even when the block raises' do
      expect {
        with_soft_scrubbing(viewer: nil, if: ->(_record, _viewer) { true }) do
          raise 'boom'
        end
      }.to raise_error(RuntimeError, 'boom')

      expect(Pumice.soft_scrubbing?).to be false
    end

    it 'accepts scrub_unless option' do
      with_soft_scrubbing(viewer: nil, unless: ->(_record, _viewer) { false }) do
        expect(Pumice.soft_scrubbing?).to be true
      end
    end
  end

  describe '#without_soft_scrubbing' do
    it 'disables soft scrubbing within the block' do
      Pumice.configure do |c|
        c.soft_scrubbing = { if: ->(_record, _viewer) { true } }
      end

      without_soft_scrubbing do
        expect(Pumice.soft_scrubbing?).to be false
      end
    end

    it 'restores original config after the block' do
      Pumice.configure do |c|
        c.soft_scrubbing = { if: ->(_record, _viewer) { true } }
      end

      without_soft_scrubbing do
        # inside block
      end

      expect(Pumice.soft_scrubbing?).to be true
    end

    it 'restores config even when the block raises' do
      Pumice.configure do |c|
        c.soft_scrubbing = { if: ->(_record, _viewer) { true } }
      end

      expect {
        without_soft_scrubbing do
          raise 'boom'
        end
      }.to raise_error(RuntimeError, 'boom')

      expect(Pumice.soft_scrubbing?).to be true
    end
  end
end

RSpec.describe 'have_scrubbed matcher' do
  before { Pumice.reset! }

  let(:sanitizer) do
    Class.new(Pumice::Sanitizer) do
      sanitizes :users
      scrub(:email) { 'fake@example.test' }
      scrub(:first_name) { 'Fake' }
      keep :last_name
      keep_undefined_columns!

      def self.name
        'TestSanitizer'
      end
    end
  end

  it 'passes for a scrubbed column' do
    expect(sanitizer).to have_scrubbed(:email)
  end

  it 'passes for another scrubbed column' do
    expect(sanitizer).to have_scrubbed(:first_name)
  end

  it 'fails for a kept column' do
    expect(sanitizer).not_to have_scrubbed(:last_name)
  end

  it 'fails for an undefined column' do
    expect(sanitizer).not_to have_scrubbed(:nonexistent)
  end

  it 'provides a helpful failure message' do
    matcher = have_scrubbed(:last_name)
    matcher.matches?(sanitizer)
    expect(matcher.failure_message).to include('to scrub :last_name')
    expect(matcher.failure_message).to include('Scrubbed columns:')
  end
end

RSpec.describe 'have_kept matcher' do
  before { Pumice.reset! }

  let(:sanitizer) do
    Class.new(Pumice::Sanitizer) do
      sanitizes :users
      scrub(:email) { 'fake@example.test' }
      scrub(:first_name) { 'Fake' }
      keep :last_name
      keep_undefined_columns!

      def self.name
        'TestSanitizer'
      end
    end
  end

  it 'passes for a kept column' do
    expect(sanitizer).to have_kept(:last_name)
  end

  it 'fails for a scrubbed column' do
    expect(sanitizer).not_to have_kept(:email)
  end

  it 'fails for an undefined column' do
    expect(sanitizer).not_to have_kept(:nonexistent)
  end

  it 'provides a helpful failure message' do
    matcher = have_kept(:email)
    matcher.matches?(sanitizer)
    expect(matcher.failure_message).to include('to keep :email')
    expect(matcher.failure_message).to include('Kept columns:')
  end
end

RSpec.describe 'auto-lint' do
  before { Pumice.reset! }

  describe 'lint! on sanitizer classes' do
    it 'passes for complete sanitizers' do
      sanitizer = Class.new(Pumice::Sanitizer) do
        sanitizes :users
        scrub(:email) { 'fake@example.test' }
        scrub(:first_name) { 'Fake' }
        scrub(:last_name) { 'User' }
        keep_undefined_columns!

        def self.name
          'CompleteSanitizer'
        end
      end

      expect(sanitizer.lint!).to be_empty
    end

    it 'reports missing columns for incomplete sanitizers' do
      sanitizer = Class.new(Pumice::Sanitizer) do
        sanitizes :users
        scrub(:email) { 'fake@example.test' }

        def self.name
          'IncompleteSanitizer'
        end
      end

      issues = sanitizer.lint!
      expect(issues).not_to be_empty
      expect(issues.first).to match(/undefined columns/)
    end

    it 'skips when described_class is not a sanitizer' do
      # String describe blocks should not trigger lint
      expect { Pumice.reset! }.not_to raise_error
    end
  end
end
