# frozen_string_literal: true

require 'rails/generators/named_base'

module Pumice
  module Generators
    class TestGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      desc 'Generates a Pumice sanitizer spec for the given model'

      def create_test_file
        template 'sanitizer_spec.rb.erb', File.join('spec/sanitizers', class_path, "#{file_name}_sanitizer_spec.rb")
      end

      private

      def model_class
        @model_class ||= class_name.constantize
      rescue NameError
        raise "Model #{class_name} not found. Please ensure the model exists."
      end

      def columns
        @columns ||= model_class.columns.reject { |c| protected_column?(c.name) }
      end

      def protected_column?(name)
        %w[id created_at updated_at].include?(name)
      end

      def pii_columns
        columns.select { |c| pii_column?(c) }
      end

      def credential_columns
        columns.select { |c| credential_column?(c) }
      end

      def keep_columns
        columns.reject { |c| pii_column?(c) || credential_column?(c) }
      end

      def pii_column?(column)
        return false unless %i[string text].include?(column.type)

        pii_patterns = %w[
          name email phone address city state zip country
          street first_name last_name middle_name full_name
          display_name username login bio notes description
          room_number call_number ssn tax_id license
        ]

        pii_patterns.any? { |pattern| column.name.include?(pattern) }
      end

      def credential_column?(column)
        credential_patterns = %w[
          password token secret key api_key access_token
          refresh_token encrypted clever_id google_id
          facebook_id twitter_id oauth
        ]

        credential_patterns.any? { |pattern| column.name.include?(pattern) }
      end
    end
  end
end
