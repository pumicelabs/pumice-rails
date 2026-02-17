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
