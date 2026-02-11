# frozen_string_literal: true

require_relative "lib/pumice/version"

Gem::Specification.new do |spec|
  spec.name          = "pumice"
  spec.version       = Pumice::VERSION
  spec.authors       = ["Chapter One NFP", "Adam Cuppy"]
  spec.email         = ["dev@chapterone.org"]
  spec.summary       = "Database PII sanitization for Rails"
  spec.description   = "Declarative sanitizer DSL for scrubbing, pruning, and " \
                        "safely exporting PII-free database copies."
  spec.homepage      = "https://github.com/innovationsforlearning/pumice"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails",  ">= 6.0"
  spec.add_dependency "faker",  ">= 3.0"
  spec.add_dependency "bcrypt", ">= 3.1"
end
