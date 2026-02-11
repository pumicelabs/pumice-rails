# frozen_string_literal: true

require_relative 'pumice/version'

module Pumice; end

require_relative 'pumice/engine'
require_relative 'pumice/configuration'
require_relative 'pumice/output'
require_relative 'pumice/helpers'
require_relative 'pumice/logger'
require_relative 'pumice/dsl'
require_relative 'pumice/sanitizer'
require_relative 'pumice/empty_sanitizer'
require_relative 'pumice/soft_scrubbing'
require_relative 'pumice/analyzer'
require_relative 'pumice/validator'
require_relative 'pumice/runner'
require_relative 'pumice/dump_generator'
require_relative 'pumice/pruner'
require_relative 'pumice/pruning/analyzer'
require_relative 'pumice/safe_scrubber'
require_relative 'pumice/railtie' if defined?(Rails::Railtie)
