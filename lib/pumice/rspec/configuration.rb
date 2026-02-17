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
