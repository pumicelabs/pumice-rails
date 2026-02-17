module Pumice
  module RSpec
    module SanitizerHelpers
      # Enable soft scrubbing for a block with optional viewer context.
      #
      #   with_soft_scrubbing(viewer: admin, if: ->(r, v) { !v.admin? }) do
      #     expect(user.email).to eq('real@gmail.com')
      #   end
      def with_soft_scrubbing(viewer: nil, if: nil, unless: nil, &block)
        original = Pumice.config.instance_variable_get(:@soft_scrubbing)
        config_hash = {}
        config_hash[:if] = binding.local_variable_get(:if) if binding.local_variable_get(:if)
        config_hash[:unless] = binding.local_variable_get(:unless) if binding.local_variable_get(:unless)
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
