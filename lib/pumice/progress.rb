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
    #   Pumice::Progress.each(sanitizers, "Sanitizers") do |s|
    #     s.scrub_all!
    #   end
    #
    def self.each(collection, title, output: $stdout)
      progress = new(title: title, total: collection.size, output: output)
      collection.each do |item|
        yield item
        progress.increment
      end
      progress.finish
    end
  end
end
