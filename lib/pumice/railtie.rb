# frozen_string_literal: true

module Pumice
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/db_scrub.rake", __dir__)
    end

    generators do
      require_relative 'generators/sanitizer_generator'
    end
  end
end
