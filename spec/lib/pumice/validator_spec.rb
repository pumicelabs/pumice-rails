# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Validator do
  before do
    Pumice.reset!
    Pumice.configure do |config|
      config.sensitive_email_model = 'User'
      config.sensitive_email_column = 'email'
      config.sensitive_email_domains = %w[gmail.com]
      config.sensitive_token_columns = []
      config.sensitive_external_id_columns = []
    end
  end

  describe Pumice::Validator::Result do
    describe '#passed?' do
      it 'returns true when errors empty' do
        result = described_class.new(errors: [], checks: [])

        expect(result.passed?).to be true
      end

      it 'returns false when errors present' do
        result = described_class.new(errors: ['Found real email'], checks: [])

        expect(result.passed?).to be false
      end
    end
  end

  describe Pumice::Validator::Check do
    it 'exposes name attribute' do
      check = described_class.new(name: 'test', count: 5, passed: true)

      expect(check.name).to eq('test')
    end

    it 'exposes count attribute' do
      check = described_class.new(name: 'test', count: 5, passed: true)

      expect(check.count).to eq(5)
    end

    it 'exposes passed attribute' do
      check = described_class.new(name: 'test', count: 5, passed: true)

      expect(check.passed).to be true
    end
  end

  describe '#initialize' do
    it 'accepts custom email_domains' do
      validator = described_class.new(email_domains: %w[custom.com])

      # Indirectly test by running validation - if custom domain is used,
      # it would check for emails ending in @custom.com
      allow(User).to receive(:where).and_return(double(count: 0))
      allow(User).to receive(:column_names).and_return([])

      validator.run

      expect(User).to have_received(:where).with("email LIKE ?", "%@custom.com")
    end

    it 'uses config domains when not provided' do
      validator = described_class.new

      allow(User).to receive(:where).and_return(double(count: 0))
      allow(User).to receive(:column_names).and_return([])

      validator.run

      expect(User).to have_received(:where).with("email LIKE ?", "%@gmail.com")
    end
  end

  describe '#run' do
    let(:validator) { described_class.new }

    before do
      allow(User).to receive(:column_names).and_return([])
    end

    it 'returns a Result' do
      allow(User).to receive(:where).and_return(double(count: 0))

      result = validator.run

      expect(result).to be_a(Pumice::Validator::Result)
    end

    it 'includes checks in result' do
      allow(User).to receive(:where).and_return(double(count: 0))

      result = validator.run

      expect(result.checks).to be_an(Array)
      expect(result.checks).not_to be_empty
    end

    context 'real email domain check' do
      it 'passes when no real emails found' do
        allow(User).to receive(:where).and_return(double(count: 0))

        result = validator.run
        check = result.checks.find { |c| c.name == 'real_email_domains' }

        expect(check.passed).to be true
      end

      it 'fails when real emails found' do
        allow(User).to receive(:where)
          .with("email LIKE ?", "%@gmail.com")
          .and_return(double(count: 5))
        allow(User).to receive(:where)
          .with("email LIKE ?", "%@example.test")
          .and_return(double(count: 0))

        result = validator.run
        check = result.checks.find { |c| c.name == 'real_email_domains' }

        expect(check.passed).to be false
      end

      it 'adds error when real emails found' do
        allow(User).to receive(:where)
          .with("email LIKE ?", "%@gmail.com")
          .and_return(double(count: 5))
        allow(User).to receive(:where)
          .with("email LIKE ?", "%@example.test")
          .and_return(double(count: 0))

        result = validator.run

        expect(result.errors).to include(a_string_matching(/gmail\.com/))
      end
    end

    context 'test email check' do
      it 'passes when test emails present' do
        allow(User).to receive(:where)
          .with("email LIKE ?", "%@gmail.com")
          .and_return(double(count: 0))
        allow(User).to receive(:where)
          .with("email LIKE ?", "%@example.test")
          .and_return(double(count: 100))

        result = validator.run
        check = result.checks.find { |c| c.name == 'test_emails' }

        expect(check.passed).to be true
      end

      it 'fails when no test emails' do
        allow(User).to receive(:where).and_return(double(count: 0))

        result = validator.run
        check = result.checks.find { |c| c.name == 'test_emails' }

        expect(check.passed).to be false
      end
    end

    # Token column validation requires mocking User.where(...).not(...).count
    # to simulate checking for non-null values in sensitive columns.
    context 'token column checks' do
      before do
        Pumice.config.sensitive_token_columns = %w[reset_token]
        allow(User).to receive(:where).and_return(double(count: 0))
      end

      it 'skips columns not on model' do
        allow(User).to receive(:column_names).and_return(%w[id email])

        result = validator.run

        check_names = result.checks.map(&:name)
        expect(check_names).not_to include('reset_token')
      end

      it 'checks columns that exist on model' do
        allow(User).to receive(:column_names).and_return(%w[id email reset_token])

        where_double = double('where', count: 0)
        allow(User).to receive(:where).and_return(where_double)
        allow(where_double).to receive(:not).and_return(double(count: 0))

        result = validator.run

        check_names = result.checks.map(&:name)
        expect(check_names).to include('reset_token')
      end
    end

    context 'external ID column checks' do
      before do
        Pumice.config.sensitive_external_id_columns = %w[clever_id]
        allow(User).to receive(:where).and_return(double(count: 0))
      end

      it 'skips columns not on model' do
        allow(User).to receive(:column_names).and_return(%w[id email])

        result = validator.run

        check_names = result.checks.map(&:name)
        expect(check_names).not_to include('clever_id')
      end
    end
  end
end
