# frozen_string_literal: true

module Pumice
  class Engine < ::Rails::Engine
    rake_tasks do
      load File.expand_path("../../tasks/db_scrub.rake", __dir__)
    end
  end
end
