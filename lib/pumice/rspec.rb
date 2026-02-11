# frozen_string_literal: true

require 'pumice'

module Pumice
  module RSpec
    module SanitizerHelpers
      # Enable soft scrubbing for a block with optional viewer context.
      #
      #   with_soft_scrubbing(viewer: admin, scrub_if: ->(r, v) { !v.admin? }) do
      #     expect(user.email).to eq('real@gmail.com')
      #   end
      def with_soft_scrubbing(viewer: nil, scrub_if: nil, scrub_unless: nil, &block)
        original = Pumice.config.instance_variable_get(:@soft_scrubbing)
        config_hash = {}
        config_hash[:if] = scrub_if if scrub_if
        config_hash[:unless] = scrub_unless if scrub_unless
        Pumice.configure { |c| c.soft_scrubbing = config_hash }
        Pumice.with_soft_scrubbing_context(viewer, &block)
      ensure
        Pumice.config.instance_variable_set(:@soft_scrubbing, original)
        Pumice::SoftScrubbing::Policy.reset!
      end

      # Disable soft scrubbing for a block.
      #
      #   without_soft_scrubbing do
      #     expect(user.email).to eq('real@gmail.com')
      #   end
      def without_soft_scrubbing
        original = Pumice.config.instance_variable_get(:@soft_scrubbing)
        Pumice.config.instance_variable_set(:@soft_scrubbing, false)
        Pumice::SoftScrubbing::Policy.reset!
        yield
      ensure
        Pumice.config.instance_variable_set(:@soft_scrubbing, original)
        Pumice::SoftScrubbing::Policy.reset!
      end
    end
  end
end

RSpec.configure do |config|
  # Auto-tag specs in spec/sanitizers/ as type: :sanitizer
  config.define_derived_metadata(file_path: %r{/spec/sanitizers/}) do |metadata|
    metadata[:type] ||= :sanitizer
  end

  # Reset Pumice state before each sanitizer spec
  config.before(:each, type: :sanitizer) do
    Pumice.reset!
  end

  # Auto-lint: verify column coverage once per describe group.
  # Runs for any type: :sanitizer spec where described_class is a Pumice::Sanitizer.
  # Opt out with: RSpec.describe MySanitizer, type: :sanitizer, lint: false do
  config.before(:context, type: :sanitizer) do
    next unless described_class.is_a?(Class) && described_class < Pumice::Sanitizer
    next if self.class.metadata[:lint] == false

    Pumice.reset!
    issues = described_class.lint!
    if issues.any?
      raise Pumice::UndefinedAttributeError,
        "#{described_class.name} has incomplete column coverage:\n  #{issues.join("\n  ")}"
    end
  end

  # Include helpers for sanitizer specs
  config.include Pumice::RSpec::SanitizerHelpers, type: :sanitizer
end

RSpec::Matchers.define :have_scrubbed do |attr_name|
  match do |sanitizer_class|
    sanitizer_class.scrubbed_column?(attr_name)
  end

  failure_message do |sanitizer_class|
    "expected #{sanitizer_class.name} to scrub :#{attr_name}, " \
      "but it does not.\nScrubbed columns: #{sanitizer_class.scrubbed_columns.join(', ')}"
  end

  failure_message_when_negated do |sanitizer_class|
    "expected #{sanitizer_class.name} not to scrub :#{attr_name}, but it does"
  end
end

RSpec::Matchers.define :have_kept do |attr_name|
  match do |sanitizer_class|
    sanitizer_class.kept_columns.include?(attr_name.to_s)
  end

  failure_message do |sanitizer_class|
    "expected #{sanitizer_class.name} to keep :#{attr_name}, " \
      "but it does not.\nKept columns: #{sanitizer_class.kept_columns.join(', ')}"
  end

  failure_message_when_negated do |sanitizer_class|
    "expected #{sanitizer_class.name} not to keep :#{attr_name}, but it does"
  end
end
