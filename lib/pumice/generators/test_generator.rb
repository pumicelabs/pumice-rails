# frozen_string_literal: true

require 'rails/generators/named_base'
require_relative 'column_classification'

module Pumice
  module Generators
    class TestGenerator < Rails::Generators::NamedBase
      include ColumnClassification

      source_root File.expand_path('templates', __dir__)

      desc 'Generates a Pumice sanitizer spec for the given model'

      def create_test_file
        template 'sanitizer_spec.rb.erb', File.join('spec/sanitizers', class_path, "#{file_name}_sanitizer_spec.rb")
      end
    end
  end
end
