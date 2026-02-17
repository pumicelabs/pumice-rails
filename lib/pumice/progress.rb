# frozen_string_literal: true

require 'ruby-progressbar'

module Pumice
  class Progress
    def initialize(title:, total:, output: $stdout)
      @enabled = total > 0 && !Pumice.verbose? && output.respond_to?(:tty?) && output.tty?
      return unless @enabled

      @bar = ProgressBar.create(
        title: title,
        total: total,
        format: "  %t: |%B| %c/%C %E",
        output: output
      )
    end

    def increment
      @bar&.increment if @enabled
    end

    def finish
      @bar&.finish if @enabled
    end

    # Block-based API for iterating a collection with progress.
    #
    #   Pumice::Progress.each(sanitizers, title: "Sanitizers") do |s|
    #     s.scrub_all!
    #   end
    #
    # Pass total: for enumerators that don't respond to #size (e.g. find_each):
    #
    #   Pumice::Progress.each(scope.find_each, title: "Model", total: scope.count) do |record|
    #     record.update!(...)
    #   end
    #
    def self.each(collection, title:, total: collection.size, output: $stdout)
      count = 0
      progress = new(title: title, total: total, output: output)
      collection.each do |item|
        yield item
        count += 1
        progress.increment
      end
      progress.finish
      count
    end
  end
end
