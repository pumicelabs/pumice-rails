# frozen_string_literal: true

require 'rails/generators/named_base'

module Pumice
  module Generators
    class SanitizerGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      desc 'Generates a Pumice sanitizer with smart defaults for the given model'

      class_option :test, type: :boolean, default: true, desc: 'Generate sanitizer spec'
      class_option :defaults, type: :boolean, default: false, desc: 'Pre-fill scrub blocks with smart defaults'

      def create_sanitizer_file
        template 'sanitizer.rb.erb', File.join('app/sanitizers', class_path, "#{file_name}_sanitizer.rb")
      end

      def create_test_file
        return unless options[:test] && File.directory?(Rails.root.join('spec'))

        template 'sanitizer_spec.rb.erb', File.join('spec/sanitizers', class_path, "#{file_name}_sanitizer_spec.rb")
      end

      private

      def plural_file_name
        file_name.pluralize
      end

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
        name = column.name
        type = column.type

        # String/text columns that likely contain PII
        return false unless %i[string text].include?(type)

        pii_patterns = %w[
          name email phone address city state zip country
          street first_name last_name middle_name full_name
          display_name username login bio notes description
          room_number call_number ssn tax_id license
        ]

        pii_patterns.any? { |pattern| name.include?(pattern) }
      end

      def credential_column?(column)
        name = column.name

        credential_patterns = %w[
          password token secret key api_key access_token
          refresh_token encrypted clever_id google_id
          facebook_id twitter_id oauth
        ]

        credential_patterns.any? { |pattern| name.include?(pattern) }
      end

      def scrub_logic_for(column)
        name = column.name
        type = column.type
        nullable = column.null

        # Generate appropriate scrubbing logic based on column characteristics
        case
        when name.include?('email')
          nullable ? email_scrub_logic(nullable) : email_scrub_logic(nullable)
        when name.include?('phone') || name.include?('call_number')
          phone_scrub_logic(nullable)
        when name.include?('first_name')
          "{ Faker::Name.first_name }"
        when name.include?('last_name')
          "{ Faker::Name.last_name }"
        when name.match?(/\b(name|display_name|full_name)\b/)
          "{ Faker::Name.name }"
        when name.include?('address') || name.include?('street')
          "{ Faker::Address.street_address }"
        when name.include?('city')
          "{ Faker::Address.city }"
        when name.include?('state')
          "{ Faker::Address.state_abbr }"
        when name.include?('zip')
          "{ Faker::Address.zip }"
        when name.include?('username') || name.include?('login')
          '{ "user_#{record.id}" }'
        when name.include?('bio') || name.include?('description')
          "{ |value| match_length(value, use: :paragraph) }"
        when name.include?('notes')
          "{ |value| match_length(value, use: :paragraph) }"
        when type == :text
          "{ |value| match_length(value, use: :paragraph) }"
        when type == :string
          "{ Faker::Lorem.word }"
        else
          "{ |value| match_length(value) }"
        end
      end

      def email_scrub_logic(nullable)
        if nullable
          '{ |value| value.present? ? fake_email(record) : nil }'
        else
          '{ fake_email(record) }'
        end
      end

      def phone_scrub_logic(nullable)
        if nullable
          '{ |value| value.present? ? fake_phone : nil }'
        else
          '{ fake_phone }'
        end
      end

      def has_pii_columns?
        pii_columns.any?
      end

      def has_credential_columns?
        credential_columns.any?
      end

      def defaults?
        options[:defaults]
      end

      def has_keep_columns?
        keep_columns.any?
      end
    end
  end
end
