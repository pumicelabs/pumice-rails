# frozen_string_literal: true

module Pumice
  module SoftScrubbing
    # Policy determines when soft scrubbing applies to a record.
    #
    # TRANSITIONAL: This module currently uses a binary on/off policy check.
    # Future versions will support:
    #   - Per-attribute policies (SSN vs email have different rules)
    #   - Role-graduated scrubbing (admin/manager/user see different levels)
    #   - Viewer context passed to scrub blocks for conditional masking
    #
    # See lib/pumice/README.md for the roadmap.
    module Policy
      extend self

      THREAD_KEY = :pumice_soft_scrub_context
      CONTEXT_SET_KEY = :pumice_soft_scrub_context_set

      def context=(context)
        Thread.current[THREAD_KEY] = context
        Thread.current[CONTEXT_SET_KEY] = true
      end

      def current(record = nil)
        resolve(Thread.current[THREAD_KEY], record)
      end

      # Returns true if context has been explicitly set for this request/thread.
      # Used to distinguish "no logged-in user" from "not in a request context".
      def context_set?
        Thread.current[CONTEXT_SET_KEY] == true
      end

      def with_context(context)
        previous = Thread.current[THREAD_KEY]
        previous_set = Thread.current[CONTEXT_SET_KEY]
        self.context = context
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
        Thread.current[CONTEXT_SET_KEY] = previous_set
      end

      # Temporarily disable soft scrubbing for a block.
      # Used during authentication/session management to skip policy checks.
      def without_context
        previous = Thread.current[THREAD_KEY]
        previous_set = Thread.current[CONTEXT_SET_KEY]
        Thread.current[THREAD_KEY] = nil
        Thread.current[CONTEXT_SET_KEY] = nil
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
        Thread.current[CONTEXT_SET_KEY] = previous_set
      end

      def enabled_for?(record)
        return false unless Pumice.soft_scrubbing?
        return false unless context_set?  # Skip during boot/initialization

        viewer = current(record)
        Pumice.config.soft_scrubbing[:policy].call(record, viewer)
      end

      def reset!
        Thread.current[THREAD_KEY] = nil
        Thread.current[CONTEXT_SET_KEY] = nil
      end

      private

      def resolve(raw_context, record)
        config_context = Pumice.soft_scrubbing? ? Pumice.config.soft_scrubbing[:context] : nil
        value = raw_context.nil? ? config_context : raw_context

        case value
        when Proc
          value.arity.zero? ? value.call : value.call(record)
        when Symbol, String
          resolve_symbol(value.to_sym, record)
        when nil
          nil
        else
          value
        end
      end

      def resolve_symbol(method_name, record)
        if record&.respond_to?(method_name)
          record.public_send(method_name)
        elsif Pumice.respond_to?(method_name)
          Pumice.public_send(method_name)
        elsif defined?(Current) && Current.respond_to?(method_name)
          Current.public_send(method_name)
        elsif Thread.current.key?(method_name)
          Thread.current[method_name]
        else
          nil
        end
      end
    end
  end
end
