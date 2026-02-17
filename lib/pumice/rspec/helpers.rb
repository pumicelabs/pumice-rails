# frozen_string_literal: true

module Pumice
  module RSpec
    module SanitizerHelpers
      # Enable soft scrubbing for a block with optional viewer context.
      #
      #   with_soft_scrubbing(viewer: admin, if: ->(r, v) { !v.admin? }) do
      #     expect(user.email).to eq('real@gmail.com')
      #   end
      def with_soft_scrubbing(viewer: nil, if: nil, unless: nil, &block)
        if_cond = binding.local_variable_get(:if)
        unless_cond = binding.local_variable_get(:unless)
        original = save_scrubbing_config(if_cond, unless_cond)
        Pumice.with_soft_scrubbing_context(viewer, &block)
      ensure
        restore_scrubbing_config(original)
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

      private

      def save_scrubbing_config(if_cond, unless_cond)
        original = Pumice.config.instance_variable_get(:@soft_scrubbing)
        config_hash = {}
        config_hash[:if] = if_cond if if_cond
        config_hash[:unless] = unless_cond if unless_cond
        Pumice.configure { |c| c.soft_scrubbing = config_hash }
        original
      end

      def restore_scrubbing_config(original)
        Pumice.config.instance_variable_set(:@soft_scrubbing, original)
        Pumice::SoftScrubbing::Policy.reset!
      end
    end
  end
end
