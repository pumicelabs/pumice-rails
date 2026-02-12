# frozen_string_literal: true

module Pumice
  class Runner
    class UnknownSanitizerError < StandardError; end

    class << self
      def available
        Pumice.sanitizers.map(&:friendly_name)
      end

      def find(friendly_name)
        Pumice.sanitizers.find { |s| s.friendly_name == friendly_name.to_s }
      end
    end

    def initialize(verbose: false)
      Pumice.config.verbose = verbose
    end

    def run_all
      run(self.class.available)
    end

    def run(names)
      sanitizers = resolve_sanitizers(names)
      Pumice::Logger.initialize_stats

      ActiveRecord::Base.transaction do
        run_global_pruning
        run_sanitizers(sanitizers)
      end

      Pumice::Logger.summary
    end

    def database_name
      ActiveRecord::Base.connection_db_config.database
    end

    def mode
      Pumice.dry_run? ? 'DRY RUN' : 'LIVE'
    end

    private

    def run_global_pruning
      return unless Pumice.pruning_enabled?

      Pumice::Pruner.new.run
    end

    def run_sanitizers(sanitizers)
      Pumice::Progress.each(sanitizers, "Sanitizers", &:scrub_all!)
    end

    def resolve_sanitizers(names)
      Array(names).map do |name|
        sanitizer = self.class.find(name)
        raise UnknownSanitizerError, "Unknown sanitizer: #{name}" unless sanitizer

        sanitizer
      end
    end
  end
end
