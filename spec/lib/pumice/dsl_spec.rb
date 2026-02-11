# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::DSL do
  before { Pumice.reset! }

  # Create a fresh sanitizer class for each test to avoid state leakage
  def create_sanitizer(&block)
    Class.new(Pumice::Sanitizer) do
      class_eval(&block) if block
    end
  end

  describe 'scrub' do
    it 'registers a column with a block' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:email) { 'fake@example.com' }
      end

      expect(sanitizer.scrubbed).to have_key(:email)
      expect(sanitizer.scrubbed[:email]).to be_a(Proc)
    end

    it 'allows multiple scrub declarations' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:email) { 'fake@example.com' }
        scrub(:first_name) { 'John' }
        scrub(:last_name) { 'Doe' }
      end

      expect(sanitizer.scrubbed.keys).to contain_exactly(:email, :first_name, :last_name)
    end
  end

  describe 'keep' do
    it 'marks columns as safe to keep unchanged' do
      sanitizer = create_sanitizer do
        sanitizes :user
        keep :status, :roles
      end

      expect(sanitizer.kept).to contain_exactly(:status, :roles)
    end

    it 'accumulates across multiple keep calls' do
      sanitizer = create_sanitizer do
        sanitizes :user
        keep :status
        keep :roles, :archived
      end

      expect(sanitizer.kept).to contain_exactly(:status, :roles, :archived)
    end

    it 'converts column names to symbols' do
      sanitizer = create_sanitizer do
        sanitizes :user
        keep 'status', :roles
      end

      expect(sanitizer.kept).to all(be_a(Symbol))
    end
  end

  describe 'sanitizes' do
    it 'binds to a model by inferring class from symbol' do
      sanitizer = create_sanitizer do
        sanitizes :user
      end

      expect(sanitizer.model_class).to eq(User)
    end

    it 'accepts explicit class_name as string' do
      sanitizer = create_sanitizer do
        sanitizes :account, class_name: 'User'
      end

      expect(sanitizer.model_class).to eq(User)
    end

    it 'accepts explicit class_name as constant' do
      sanitizer = create_sanitizer do
        sanitizes :account, class_name: User
      end

      expect(sanitizer.model_class).to eq(User)
    end
  end

  describe 'model_class' do
    it 'infers model from sanitizer class name' do
      # UserSanitizer -> User
      stub_const('UserSanitizer', create_sanitizer)

      expect(UserSanitizer.model_class).to eq(User)
    end

    it 'raises when model cannot be inferred' do
      # Create a named class that doesn't match any model
      # Note: Can't use 'RandomSanitizer' because Ruby has a built-in Random class
      stub_const('XyzzyNonexistentSanitizer', create_sanitizer)

      expect { XyzzyNonexistentSanitizer.model_class }.to raise_error(/Could not infer model/)
    end
  end

  describe 'friendly_name' do
    it 'can be set explicitly' do
      sanitizer = create_sanitizer do
        friendly_name 'custom_name'
      end

      expect(sanitizer.friendly_name).to eq('custom_name')
    end

    it 'infers from class name when not set' do
      stub_const('UserSanitizer', create_sanitizer)

      expect(UserSanitizer.friendly_name).to eq('users')
    end

    it 'handles multi-word class names' do
      stub_const('TutorSessionFeedbackSanitizer', create_sanitizer)

      expect(TutorSessionFeedbackSanitizer.friendly_name).to eq('tutor_session_feedbacks')
    end

    it 'converts symbols to strings' do
      sanitizer = create_sanitizer do
        friendly_name :custom
      end

      expect(sanitizer.friendly_name).to eq('custom')
    end
  end

  describe 'column analysis' do
    let(:sanitizer) do
      create_sanitizer do
        sanitizes :user
        scrub(:email) { 'fake@example.com' }
        scrub(:first_name) { 'John' }
        keep :status, :roles
      end
    end

    describe 'scrubbed_columns' do
      it 'returns string names of scrubbed columns' do
        expect(sanitizer.scrubbed_columns).to contain_exactly('email', 'first_name')
      end
    end

    describe 'scrubbed_column?' do
      it 'returns true for scrubbed columns' do
        expect(sanitizer.scrubbed_column?(:email)).to be true
        expect(sanitizer.scrubbed_column?('email')).to be true
      end

      it 'returns false for kept columns' do
        expect(sanitizer.scrubbed_column?(:status)).to be false
      end

      it 'returns false for unknown columns' do
        expect(sanitizer.scrubbed_column?(:unknown)).to be false
      end
    end

    describe 'kept_columns' do
      it 'returns string names of kept columns' do
        expect(sanitizer.kept_columns).to contain_exactly('status', 'roles')
      end
    end

    describe 'defined_columns' do
      it 'combines scrubbed and kept columns' do
        expect(sanitizer.defined_columns).to contain_exactly(
          'email', 'first_name', 'status', 'roles'
        )
      end
    end

    describe 'undefined_columns' do
      it 'returns columns not declared via scrub or keep' do
        undefined = sanitizer.undefined_columns

        # Should exclude: defined columns (email, first_name, status, roles)
        # Should exclude: protected columns (id, created_at, updated_at)
        expect(undefined).not_to include('email', 'first_name', 'status', 'roles')
        expect(undefined).not_to include('id', 'created_at', 'updated_at')

        # Should include other User columns
        expect(undefined).to include('last_name')
      end
    end

    describe 'stale_columns' do
      it 'returns columns defined but not in model' do
        sanitizer = create_sanitizer do
          sanitizes :user
          scrub(:nonexistent_column) { 'value' }
          keep :another_fake_column
        end

        expect(sanitizer.stale_columns).to include('nonexistent_column', 'another_fake_column')
      end

      it 'returns empty array when all columns exist' do
        sanitizer = create_sanitizer do
          sanitizes :user
          scrub(:email) { 'fake@example.com' }
          keep :roles  # Use an actual User column
        end

        expect(sanitizer.stale_columns).to be_empty
      end
    end
  end

  describe 'lint!' do
    it 'returns empty array when fully covered' do
      sanitizer = create_sanitizer do
        sanitizes :user
        keep_undefined_columns!
      end

      expect(sanitizer.lint!).to be_empty
    end

    it 'reports undefined columns' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:email) { 'test@example.com' }
        # Missing many columns
      end

      issues = sanitizer.lint!
      expect(issues.first).to include('undefined columns')
    end

    it 'reports stale columns' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:nonexistent) { 'value' }
        keep_undefined_columns!
      end

      issues = sanitizer.lint!
      expect(issues.first).to include('stale columns')
    end

    it 'handles model that does not exist' do
      # Create a named class that will try to infer a nonexistent model
      # Don't call sanitizes - let model_class inference fail during lint!
      stub_const('NonexistentModelSanitizer', create_sanitizer)

      issues = NonexistentModelSanitizer.lint!
      expect(issues.first).to include("doesn't exist")
    end
  end

  describe 'keep_undefined_columns!' do
    it 'marks all undefined columns as kept' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:email) { 'test@example.com' }
        keep_undefined_columns!
      end

      expect(sanitizer.undefined_columns).to be_empty
    end

    it 'raises when disabled in config' do
      Pumice.config.allow_keep_undefined_columns = false

      sanitizer = create_sanitizer do
        sanitizes :user
      end

      expect { sanitizer.keep_undefined_columns! }.to raise_error(/disabled/)
    end
  end

  describe 'PROTECTED_COLUMNS' do
    it 'excludes id, created_at, updated_at from undefined' do
      sanitizer = create_sanitizer do
        sanitizes :user
        keep_undefined_columns!
      end

      # These should never appear in undefined_columns
      expect(sanitizer.kept_columns).not_to include('id', 'created_at', 'updated_at')
    end
  end

  describe 'prune' do
    it 'stores a prune operation with a scope block' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:email) { 'fake@example.com' }
        prune { where(created_at: ..1.year.ago) }
      end

      expect(sanitizer.prune_operation).to be_a(Hash)
      expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
    end

    it 'raises ArgumentError without a block' do
      expect {
        create_sanitizer do
          sanitizes :user
          prune
        end
      }.to raise_error(ArgumentError, 'prune requires a block')
    end

    it 'does not set a bulk_operation' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:email) { 'fake@example.com' }
        prune { where(created_at: ..1.year.ago) }
      end

      expect(sanitizer.bulk_operation).to be_nil
    end

    it 'is independent from bulk operations' do
      sanitizer = create_sanitizer do
        sanitizes :user
        scrub(:email) { 'fake@example.com' }
        prune { where(created_at: ..1.year.ago) }
      end

      expect(sanitizer.prune_operation).not_to be_nil
      expect(sanitizer.bulk_operation).to be_nil
      expect(sanitizer.scrubbed).to have_key(:email)
    end

    describe 'prune_older_than' do
      it 'sets a prune operation from a duration' do
        sanitizer = create_sanitizer do
          sanitizes :user
          scrub(:email) { 'fake@example.com' }
          prune_older_than 1.year
        end

        expect(sanitizer.prune_operation).to be_a(Hash)
        expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
      end

      it 'accepts a DateTime' do
        sanitizer = create_sanitizer do
          sanitizes :user
          prune_older_than DateTime.new(2024, 1, 1)
        end

        expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
      end

      it 'accepts a date string' do
        sanitizer = create_sanitizer do
          sanitizes :user
          prune_older_than '2024-01-01'
        end

        expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
      end

      it 'accepts a custom column' do
        sanitizer = create_sanitizer do
          sanitizes :user
          prune_older_than 90.days, column: :updated_at
        end

        expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
      end

      it 'raises for invalid age type' do
        expect {
          create_sanitizer do
            sanitizes :user
            prune_older_than 42
          end
        }.to raise_error(ArgumentError, /Duration/)
      end
    end

    describe 'prune_newer_than' do
      it 'sets a prune operation from a duration' do
        sanitizer = create_sanitizer do
          sanitizes :user
          scrub(:email) { 'fake@example.com' }
          prune_newer_than 30.days
        end

        expect(sanitizer.prune_operation).to be_a(Hash)
        expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
      end

      it 'accepts a date string' do
        sanitizer = create_sanitizer do
          sanitizes :user
          prune_newer_than '2025-06-01'
        end

        expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
      end

      it 'accepts a custom column' do
        sanitizer = create_sanitizer do
          sanitizes :user
          prune_newer_than 7.days, column: :updated_at
        end

        expect(sanitizer.prune_operation[:scope]).to be_a(Proc)
      end
    end
  end

  describe 'bulk operations' do
    describe 'truncate!' do
      it 'sets a truncate bulk operation' do
        sanitizer = create_sanitizer do
          sanitizes :user
          truncate!
        end

        expect(sanitizer.bulk_operation[:type]).to eq(:truncate)
      end
    end

    describe 'delete_all' do
      it 'sets a delete bulk operation' do
        sanitizer = create_sanitizer do
          sanitizes :user
          delete_all
        end

        expect(sanitizer.bulk_operation[:type]).to eq(:delete)
      end

      it 'accepts a scope block' do
        sanitizer = create_sanitizer do
          sanitizes :user
          delete_all { where(status: 'archived') }
        end

        expect(sanitizer.bulk_operation[:scope]).to be_a(Proc)
      end
    end

    describe 'destroy_all' do
      it 'sets a destroy bulk operation' do
        sanitizer = create_sanitizer do
          sanitizes :user
          destroy_all
        end

        expect(sanitizer.bulk_operation[:type]).to eq(:destroy)
      end
    end
  end

  describe 'instance method_missing DSL' do
    let(:user) { create(:user, first_name: 'John', last_name: 'Doe', email: 'john@example.com') }
    let(:sanitizer_class) do
      create_sanitizer do
        sanitizes :user
        scrub(:first_name) { 'Fake' }
        scrub(:last_name) { first_name }  # References scrubbed first_name
        scrub(:email) { "#{raw_first_name}@example.com" }  # References raw first_name
      end
    end

    describe 'referencing other scrubbed attributes' do
      it 'allows bare attribute names to return scrubbed values' do
        result = sanitizer_class.sanitize(user)
        expect(result[:last_name]).to eq('Fake')  # Uses scrubbed first_name
      end

      it 'supports respond_to? for scrubbed attributes' do
        instance = sanitizer_class.new(user)
        expect(instance).to respond_to(:first_name)
      end
    end

    describe 'raw_* attribute access' do
      it 'allows raw_* methods to access original database values' do
        result = sanitizer_class.sanitize(user)
        expect(result[:email]).to eq('John@example.com')  # Uses raw first_name
      end

      it 'supports respond_to? for raw_* attributes' do
        instance = sanitizer_class.new(user)
        expect(instance).to respond_to(:raw_first_name)
      end
    end

    describe 'raw(:name) explicit accessor' do
      let(:raw_sanitizer_class) do
        create_sanitizer do
          sanitizes :user
          scrub(:first_name) { 'Fake' }
          scrub(:email) { "#{raw(:first_name)}@example.com" }
        end
      end

      it 'reads original database values' do
        result = raw_sanitizer_class.sanitize(user)
        expect(result[:email]).to eq('John@example.com')
      end
    end

    describe 'record delegation' do
      it 'delegates other method calls to the record' do
        sanitizer_class_with_id = create_sanitizer do
          sanitizes :user
          scrub(:email) { "user#{id}@example.com" }
        end

        result = sanitizer_class_with_id.sanitize(user)
        expect(result[:email]).to eq("user#{user.id}@example.com")
      end
    end

    describe 'method not found' do
      it 'raises NameError for undefined methods' do
        sanitizer_class_with_undefined = create_sanitizer do
          sanitizes :user
          scrub(:email) { nonexistent_method }
        end

        expect { sanitizer_class_with_undefined.sanitize(user) }.to raise_error(NameError)
      end
    end
  end
end
