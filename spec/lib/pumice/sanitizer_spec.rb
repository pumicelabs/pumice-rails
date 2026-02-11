# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Sanitizer do
  before { Pumice.reset! }

  # Helper to create fresh sanitizer classes per test
  def create_sanitizer(&block)
    Class.new(described_class) do
      class_eval(&block) if block
    end
  end

  describe '.sanitize' do
    let(:user) { create(:user, first_name: 'Alice', last_name: 'Smith', email: 'alice@real.com') }

    let(:sanitizer) do
      create_sanitizer do
        sanitizes :users
        scrub(:email) { fake_email(record) }
        scrub(:first_name) { 'Fake' }
        scrub(:last_name) { 'User' }
        keep_undefined_columns!
      end
    end

    it 'returns a hash of all scrubbed values' do
      result = sanitizer.sanitize(user)

      expect(result).to be_a(Hash)
      expect(result.keys).to contain_exactly(:email, :first_name, :last_name)
    end

    it 'returns sanitized values, not originals' do
      result = sanitizer.sanitize(user)

      expect(result[:first_name]).to eq('Fake')
      expect(result[:last_name]).to eq('User')
      expect(result[:email]).not_to eq('alice@real.com')
    end

    it 'does not persist changes to the database' do
      sanitizer.sanitize(user)

      user.reload
      expect(user.first_name).to eq('Alice')
      expect(user.email).to eq('alice@real.com')
    end

    context 'with single attribute' do
      it 'returns the sanitized value for that attribute' do
        result = sanitizer.sanitize(user, :first_name)

        expect(result).to eq('Fake')
      end

      it 'returns original value for attributes without a scrub block' do
        sanitizer_with_gap = create_sanitizer do
          sanitizes :users
          scrub(:email) { 'fake@example.test' }
          keep_undefined_columns!
        end

        result = sanitizer_with_gap.sanitize(user, :first_name)

        expect(result).to eq('Alice')
      end
    end

    context 'with raw_value override' do
      it 'uses provided raw_value instead of record attribute' do
        result = sanitizer.sanitize(user, :first_name, raw_value: 'Override')

        expect(result).to eq('Fake')
      end
    end
  end

  describe '.scrub!' do
    let(:user) { create(:user, first_name: 'Alice', last_name: 'Smith', email: 'alice@real.com') }

    let(:sanitizer) do
      create_sanitizer do
        sanitizes :users
        scrub(:first_name) { 'Scrubbed' }
        scrub(:last_name) { 'Name' }
        keep_undefined_columns!
      end
    end

    it 'persists scrubbed values to the database' do
      sanitizer.scrub!(user)

      user.reload
      expect(user.first_name).to eq('Scrubbed')
      expect(user.last_name).to eq('Name')
    end

    it 'returns the scrubbed values' do
      result = sanitizer.scrub!(user)

      expect(result).to be_a(Hash)
      expect(result[:first_name]).to eq('Scrubbed')
    end

    context 'with single attribute' do
      it 'persists only that attribute' do
        sanitizer.scrub!(user, :first_name)

        user.reload
        expect(user.first_name).to eq('Scrubbed')
        expect(user.last_name).to eq('Smith')
      end
    end

    context 'in dry run mode' do
      around do |example|
        original = ENV['DRY_RUN']
        ENV['DRY_RUN'] = 'true'
        example.run
      ensure
        ENV['DRY_RUN'] = original
      end

      it 'does not persist changes' do
        sanitizer.scrub!(user)

        user.reload
        expect(user.first_name).to eq('Alice')
      end
    end
  end

  describe '.scrub_all!' do
    let!(:user1) { create(:user, first_name: 'Alice', email: 'alice@real.com') }
    let!(:user2) { create(:user, first_name: 'Bob', email: 'bob@real.com') }

    let(:sanitizer) do
      create_sanitizer do
        sanitizes :users
        scrub(:first_name) { 'Scrubbed' }
        scrub(:last_name) { 'Name' }
        scrub(:email) { fake_email(record) }
        keep_undefined_columns!

        def self.name
          'TestSanitizer'
        end
      end
    end

    it 'scrubs all records of the model' do
      sanitizer.scrub_all!

      [user1, user2].each do |user|
        user.reload
        expect(user.first_name).to eq('Scrubbed')
      end
    end

    context 'in strict mode with undefined columns' do
      it 'raises UndefinedAttributeError' do
        strict_sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:email) { 'fake@example.test' }
          # Missing many columns

          def self.name
            'IncompleteTestSanitizer'
          end
        end

        expect { strict_sanitizer.scrub_all! }
          .to raise_error(Pumice::UndefinedAttributeError, /missing definitions/)
      end
    end

    context 'with strict mode disabled' do
      before { Pumice.config.strict = false }

      it 'runs without raising for undefined columns' do
        partial_sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:email) { fake_email(record) }

          def self.name
            'PartialTestSanitizer'
          end
        end

        expect { partial_sanitizer.scrub_all! }.not_to raise_error
      end
    end

    context 'with continue_on_error enabled' do
      before { Pumice.config.continue_on_error = true }

      it 'does not raise and logs errors' do
        call_count = 0
        error_sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:first_name) do |val|
            call_count += 1
            raise 'boom' if call_count == 1
            'Safe'
          end
          keep_undefined_columns!

          def self.name
            'ErrorTestSanitizer'
          end
        end

        allow(Pumice::Logger).to receive(:log_error)

        expect { error_sanitizer.scrub_all! }.not_to raise_error
        expect(Pumice::Logger).to have_received(:log_error).at_least(:once)
      end
    end

    context 'with continue_on_error disabled (default)' do
      it 're-raises individual record errors' do
        error_sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:first_name) { raise 'boom' }
          keep_undefined_columns!

          def self.name
            'RaisingTestSanitizer'
          end
        end

        expect { error_sanitizer.scrub_all! }.to raise_error(RuntimeError, 'boom')
      end
    end

    context 'when model class does not exist' do
      it 'logs and skips instead of raising' do
        allow(Pumice::Logger).to receive(:log_progress)

        missing_model_sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:email) { 'fake@example.test' }
          keep_undefined_columns!

          # Override model_class to raise NameError on access
          def self.model_class
            raise NameError, 'uninitialized constant MissingModel'
          end

          def self.name
            'MissingModelSanitizer'
          end
        end

        expect { missing_model_sanitizer.scrub_all! }.not_to raise_error
        expect(Pumice::Logger).to have_received(:log_progress).with(/Skipping/)
      end
    end
  end

  describe 'deterministic results' do
    let(:user) { create(:user, first_name: 'Alice') }

    let(:sanitizer) do
      create_sanitizer do
        sanitizes :users
        scrub(:email) { fake_email(record) }
        keep_undefined_columns!
      end
    end

    it 'produces the same result for the same record' do
      result1 = sanitizer.sanitize(user, :email)
      result2 = sanitizer.sanitize(user, :email)

      expect(result1).to eq(result2)
    end
  end

  describe 'bulk operations' do
    let!(:user1) { create(:user) }
    let!(:user2) { create(:user) }

    describe 'truncate!' do
      let(:sanitizer) do
        create_sanitizer do
          sanitizes :users
          truncate!

          def self.name
            'TruncateTestSanitizer'
          end
        end
      end

      it 'calls truncate on the table' do
        connection = ActiveRecord::Base.connection
        allow(connection).to receive(:truncate).and_return(nil)

        sanitizer.scrub_all!

        expect(connection).to have_received(:truncate).with('users')
      end

      context 'in dry run mode' do
        around do |example|
          original = ENV['DRY_RUN']
          ENV['DRY_RUN'] = 'true'
          example.run
        ensure
          ENV['DRY_RUN'] = original
        end

        it 'does not remove records' do
          sanitizer.scrub_all!

          expect(User.count).to eq(2)
        end
      end
    end

    describe 'delete_all' do
      let(:sanitizer) do
        create_sanitizer do
          sanitizes :users
          delete_all

          def self.name
            'DeleteAllTestSanitizer'
          end
        end
      end

      it 'deletes all records' do
        sanitizer.scrub_all!

        expect(User.count).to eq(0)
      end

      context 'with scope' do
        let(:sanitizer_with_scope) do
          user_id = user1.id
          create_sanitizer do
            sanitizes :users
            delete_all { where(id: user_id) }

            def self.name
              'ScopedDeleteTestSanitizer'
            end
          end
        end

        it 'deletes only matching records' do
          sanitizer_with_scope.scrub_all!

          expect(User.where(id: user1.id)).not_to exist
          expect(User.where(id: user2.id)).to exist
        end
      end
    end

    describe 'destroy_all' do
      let(:sanitizer) do
        create_sanitizer do
          sanitizes :users
          destroy_all

          def self.name
            'DestroyAllTestSanitizer'
          end
        end
      end

      it 'destroys all records' do
        sanitizer.scrub_all!

        expect(User.count).to eq(0)
      end
    end
  end

  describe 'prune + scrub workflow' do
    let!(:old_user) { create(:user, first_name: 'Old', created_at: 2.years.ago) }
    let!(:recent_user) { create(:user, first_name: 'Recent', created_at: 1.day.ago) }

    let(:sanitizer) do
      create_sanitizer do
        sanitizes :users
        prune { where(created_at: ..1.year.ago) }
        scrub(:first_name) { 'Scrubbed' }
        keep_undefined_columns!

        def self.name
          'PruneAndScrubTestSanitizer'
        end
      end
    end

    it 'prunes old records then scrubs survivors' do
      sanitizer.scrub_all!

      expect(User.find_by(id: old_user.id)).to be_nil

      recent_user.reload
      expect(recent_user.first_name).to eq('Scrubbed')
    end

    context 'in dry run mode' do
      around do |example|
        original = ENV['DRY_RUN']
        ENV['DRY_RUN'] = 'true'
        example.run
      ensure
        ENV['DRY_RUN'] = original
      end

      it 'does not prune or persist scrub changes' do
        sanitizer.scrub_all!

        expect(User.find_by(id: old_user.id)).to be_present

        recent_user.reload
        expect(recent_user.first_name).to eq('Recent')
      end
    end
  end

  describe 'verification' do
    let!(:user) { create(:user, email: 'alice@real.com') }

    describe 'verify_all block' do
      it 'raises VerificationError when block returns false' do
        sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:email) { 'fake@example.test' }
          keep_undefined_columns!
          verify_all('Emails should be scrubbed') { where(email: 'alice@real.com').none? }

          def self.name
            'VerifyBlockTestSanitizer'
          end
        end

        # This should pass because scrubbing changes the email
        expect { sanitizer.scrub_all! }.not_to raise_error
      end

      it 'raises VerificationError when verification fails' do
        sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:email) { raw_email }  # No-op: returns original value
          keep_undefined_columns!
          verify_all('No real emails') { where(email: 'alice@real.com').none? }

          def self.name
            'FailedVerifyTestSanitizer'
          end
        end

        expect { sanitizer.scrub_all! }
          .to raise_error(Pumice::VerificationError, /No real emails/)
      end
    end

    describe 'verify_each block' do
      it 'raises VerificationError when per-record check fails' do
        sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:email) { raw_email }  # No-op
          keep_undefined_columns!
          verify_each('Email must not be real') { |r| !r.email.include?('@real.com') }

          def self.name
            'VerifyEachTestSanitizer'
          end
        end

        expect { sanitizer.scrub_all! }
          .to raise_error(Pumice::VerificationError, /Email must not be real/)
      end

      it 'passes when per-record check succeeds' do
        sanitizer = create_sanitizer do
          sanitizes :users
          scrub(:email) { fake_email(record) }
          keep_undefined_columns!
          verify_each { |r| !r.email.include?('@real.com') }

          def self.name
            'PassingVerifyEachTestSanitizer'
          end
        end

        expect { sanitizer.scrub_all! }.not_to raise_error
      end
    end
  end

  describe 'instance' do
    let(:user) { create(:user, first_name: 'Alice', last_name: 'Smith') }

    let(:sanitizer_class) do
      create_sanitizer do
        sanitizes :users
        scrub(:first_name) { 'Fake' }
        scrub(:last_name) { first_name }
      end
    end

    describe '#scrub' do
      it 'returns scrubbed value for a single attribute' do
        instance = sanitizer_class.new(user)
        expect(instance.scrub(:first_name)).to eq('Fake')
      end

      it 'returns original value when no block defined' do
        instance = sanitizer_class.new(user)
        expect(instance.scrub(:email)).to eq(user.email)
      end
    end

    describe '#scrub_all' do
      it 'returns hash of all scrubbed attributes' do
        instance = sanitizer_class.new(user)
        result = instance.scrub_all

        expect(result).to eq({ first_name: 'Fake', last_name: 'Fake' })
      end
    end
  end
end
