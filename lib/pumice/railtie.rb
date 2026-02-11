# frozen_string_literal: true

module Pumice
  class Railtie < Rails::Railtie
    # Load the generator when Rails loads generators
    generators do
      require_relative 'generators/sanitizer_generator'
    end
  end
end
