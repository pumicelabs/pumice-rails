# frozen_string_literal: true

module Pumice
  class Validator
    Result = Struct.new(:errors, :checks, keyword_init: true) do
      def passed?
        errors.empty?
      end
    end

    Check = Struct.new(:name, :count, :passed, keyword_init: true)

    def initialize(email_domains: nil)
      @email_domains = Array(email_domains || Pumice.config.sensitive_email_domains)
    end

    def run
      errors = []
      checks = []

      # Check for real email domains
      email_check = check_real_emails
      errors.concat(email_check[:errors])
      checks << email_check[:check]

      # Check for test emails
      checks << check_test_emails

      # Check for cleared tokens
      token_checks = check_cleared_tokens
      errors.concat(token_checks[:errors])
      checks.concat(token_checks[:checks])

      # Check for cleared external IDs
      external_checks = check_external_ids
      errors.concat(external_checks[:errors])
      checks.concat(external_checks[:checks])

      Result.new(errors: errors, checks: checks)
    end

    private

    def email_model
      @email_model ||= Pumice.config.sensitive_email_model.constantize
    end

    def email_column
      @email_column ||= Pumice.config.sensitive_email_column
    end

    def check_real_emails
      errors = []

      @email_domains.each do |domain|
        count = email_model.where("#{email_column} LIKE ?", "%@#{domain}").count
        errors << "Found #{count} emails with real domain #{domain}" if count > 0
      end

      {
        errors: errors,
        check: Check.new(name: 'real_email_domains', count: errors.size, passed: errors.empty?)
      }
    end

    def check_test_emails
      count = email_model.where("#{email_column} LIKE ?", "%@example.test").count
      Check.new(name: 'test_emails', count: count, passed: count > 0)
    end

    def check_cleared_tokens
      errors = []
      checks = []

      token_columns = Pumice.config.sensitive_token_columns

      token_columns.each do |column|
        next unless email_model.column_names.include?(column.to_s)

        count = email_model.where.not(column => nil).count
        if count > 0
          errors << "Found #{count} users with #{column}"
        end
        checks << Check.new(name: column.to_s, count: count, passed: count == 0)
      end

      { errors: errors, checks: checks }
    end

    def check_external_ids
      errors = []
      checks = []

      external_id_columns = Pumice.config.sensitive_external_id_columns

      external_id_columns.each do |column|
        next unless email_model.column_names.include?(column.to_s)

        count = email_model.where.not(column => nil).count
        if count > 0
          errors << "Found #{count} users with #{column} (should be cleared)"
        end
        checks << Check.new(name: column.to_s, count: count, passed: count == 0)
      end

      { errors: errors, checks: checks }
    end
  end
end
