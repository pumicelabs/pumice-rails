# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::Helpers do
  # Create a simple test record for email generation
  let(:test_record) do
    user = User.new
    user.id = 42
    user
  end

  describe 'fake_email' do
    it 'generates deterministic email for same record' do
      email1 = described_class.fake_email(test_record)
      email2 = described_class.fake_email(test_record)

      expect(email1).to eq(email2)
    end

    it 'uses default domain example.test' do
      email = described_class.fake_email(test_record)

      expect(email).to end_with('@example.test')
    end

    it 'uses custom domain when provided' do
      email = described_class.fake_email(test_record, domain: 'custom.dev')

      expect(email).to end_with('@custom.dev')
    end

    it 'includes model name in email prefix' do
      email = described_class.fake_email(test_record)

      expect(email).to include('user')
    end

    it 'works with explicit unique_id' do
      email = described_class.fake_email(prefix: 'test', unique_id: 123)

      expect(email).to include('test123')
      expect(email).to end_with('@example.test')
    end

    it 'raises without record or unique_id' do
      expect { described_class.fake_email }.to raise_error(ArgumentError, /requires a unique_id/)
    end
  end

  describe 'fake_phone' do
    it 'returns 10 digits by default' do
      phone = described_class.fake_phone

      expect(phone).to match(/^\d{10}$/)
    end

    it 'returns specified number of digits' do
      phone = described_class.fake_phone(7)

      expect(phone).to match(/^\d{7}$/)
    end

    it 'strips non-numeric characters' do
      phone = described_class.fake_phone

      expect(phone).not_to match(/\D/)
    end
  end

  describe 'fake_password' do
    it 'produces BCrypt-formatted hash' do
      hash = described_class.fake_password

      expect(hash).to start_with('$2a$')
    end

    it 'accepts custom password' do
      hash = described_class.fake_password('secret')

      expect(BCrypt::Password.new(hash)).to eq('secret')
    end

    it 'respects cost parameter' do
      hash = described_class.fake_password('test', cost: 4)

      # BCrypt format: $2a$04$... (04 is the cost)
      expect(hash).to include('$04$')
    end
  end

  describe 'fake_id' do
    it 'formats with default prefix and zero padding' do
      result = described_class.fake_id(42)

      expect(result).to eq('ID000042')
    end

    it 'uses custom prefix' do
      result = described_class.fake_id(7, prefix: 'USR')

      expect(result).to eq('USR000007')
    end

    it 'handles large IDs' do
      result = described_class.fake_id(123456)

      expect(result).to eq('ID123456')
    end
  end

  describe 'match_length' do
    it 'returns nil for empty input' do
      result = described_class.match_length('')

      expect(result).to be_nil
    end

    it 'returns nil for nil input' do
      result = described_class.match_length(nil)

      expect(result).to be_nil
    end

    it 'produces output approximately matching input length' do
      input = 'This is a sample text that is about 50 characters.'
      result = described_class.match_length(input)

      # Allow some variance, but should be close
      expect(result.length).to be_within(15).of(input.length)
    end

    describe 'generators' do
      it 'uses sentence generator by default' do
        result = described_class.match_length('sample text')

        # Sentence generator produces capitalized text with period
        expect(result).to be_a(String)
      end

      it 'uses paragraph generator' do
        result = described_class.match_length('x' * 100, use: :paragraph)

        expect(result).to be_a(String)
        expect(result.length).to be > 0
      end

      it 'uses word generator' do
        result = described_class.match_length('sample', use: :word)

        expect(result).to be_a(String)
      end

      it 'uses characters generator' do
        result = described_class.match_length('test', use: :characters)

        expect(result).to be_a(String)
      end

      it 'accepts Proc as generator' do
        result = described_class.match_length('sample', use: -> { 'custom text' })

        expect(result).to eq('custom text')
      end

      it 'raises for invalid generator type' do
        expect {
          described_class.match_length('sample', use: 123)
        }.to raise_error(ArgumentError, /must be a Symbol or Proc/)
      end
    end
  end

  describe 'fake_json' do
    it 'returns nil for nil input' do
      result = described_class.fake_json(nil)

      expect(result).to be_nil
    end

    it 'preserves keys by default' do
      input = { 'name' => 'John', 'age' => 30 }
      result = described_class.fake_json(input)

      expect(result.keys).to contain_exactly('name', 'age')
    end

    describe 'preserve_keys: false' do
      it 'replaces keys with random words' do
        input = { 'name' => 'John', 'age' => 30 }
        result = described_class.fake_json(input, preserve_keys: false)

        expect(result.keys).not_to include('name', 'age')
        expect(result.size).to eq(2)
      end

      it 'preserves structure depth' do
        input = { 'user' => { 'name' => 'John', 'scores' => [1, 2, 3] } }
        result = described_class.fake_json(input, preserve_keys: false)

        nested = result.values.first
        expect(nested).to be_a(Hash)
        expect(nested.size).to eq(2)
        # One value should be an array of 3 zeroes
        array_val = nested.values.find { |v| v.is_a?(Array) }
        expect(array_val).to eq([0, 0, 0])
      end

      it 'scrubs values' do
        input = { 'name' => 'John' }
        result = described_class.fake_json(input, preserve_keys: false)

        expect(result.values.first).to be_a(String)
        expect(result.values.first).not_to eq('John')
      end

      it 'preserves array lengths' do
        input = ['one', 'two', 'three']
        result = described_class.fake_json(input, preserve_keys: false)

        expect(result).to be_an(Array)
        expect(result.length).to eq(3)
      end

      it 'preserves kept keys even when preserve_keys is false' do
        input = { 'name' => 'John', 'email' => 'john@example.com' }
        result = described_class.fake_json(input, preserve_keys: false, keep: ['email'])

        expect(result).to have_key('email')
        expect(result['email']).to eq('john@example.com')
        expect(result.keys).not_to include('name')
      end

      it 'preserves ancestor keys along the path to a kept value' do
        input = {
          'user' => {
            'profile' => {
              'email' => 'john@example.com',
              'name' => 'John'
            }
          }
        }
        result = described_class.fake_json(input, preserve_keys: false, keep: ['user.profile.email'])

        expect(result).to have_key('user')
        expect(result['user']).to have_key('profile')
        expect(result['user']['profile']).to have_key('email')
        expect(result['user']['profile']['email']).to eq('john@example.com')
        # Non-kept sibling key should be randomized
        expect(result['user']['profile'].keys).not_to include('name')
      end
    end

    it 'scrubs string values' do
      input = { 'name' => 'John Doe' }
      result = described_class.fake_json(input, preserve_keys: true)

      expect(result['name']).not_to eq('John Doe')
      expect(result['name']).to be_a(String)
    end

    it 'zeros numeric values' do
      input = { 'count' => 42 }
      result = described_class.fake_json(input, preserve_keys: true)

      expect(result['count']).to eq(0)
    end

    it 'preserves boolean values' do
      input = { 'active' => true, 'deleted' => false }
      result = described_class.fake_json(input, preserve_keys: true)

      expect(result['active']).to be true
      expect(result['deleted']).to be false
    end

    it 'handles nested structures' do
      input = { 'user' => { 'name' => 'John', 'scores' => [1, 2, 3] } }
      result = described_class.fake_json(input, preserve_keys: true)

      expect(result['user']).to be_a(Hash)
      expect(result['user']['name']).to be_a(String)
      expect(result['user']['scores']).to eq([0, 0, 0])
    end

    it 'parses JSON strings' do
      input = '{"name": "John"}'
      result = described_class.fake_json(input, preserve_keys: true)

      expect(result.keys).to contain_exactly('name')
    end

    it 'handles arrays' do
      input = ['one', 'two', 'three']
      result = described_class.fake_json(input, preserve_keys: true)

      expect(result).to be_an(Array)
      expect(result.length).to eq(3)
    end

    it 'raises for invalid JSON string' do
      expect {
        described_class.fake_json('not valid json')
      }.to raise_error(TypeError, /invalid JSON/)
    end

    it 'raises for unsupported types' do
      expect {
        described_class.fake_json(Object.new)
      }.to raise_error(TypeError, /expects Hash, Array, or JSON String/)
    end

    describe 'keep option' do
      it 'keeps specified top-level key with dot notation' do
        input = { 'name' => 'John', 'email' => 'john@example.com' }
        result = described_class.fake_json(input, preserve_keys: true, keep: ['email'])

        expect(result['name']).not_to eq('John')
        expect(result['email']).to eq('john@example.com')
      end

      it 'keeps specified top-level key with array notation' do
        input = { 'name' => 'John', 'email' => 'john@example.com' }
        result = described_class.fake_json(input, preserve_keys: true, keep: [['email']])

        expect(result['name']).not_to eq('John')
        expect(result['email']).to eq('john@example.com')
      end

      it 'keeps multiple top-level keys' do
        input = { 'name' => 'John', 'email' => 'john@example.com', 'age' => 30 }
        result = described_class.fake_json(input, preserve_keys: true, keep: ['email', 'age'])

        expect(result['name']).not_to eq('John')
        expect(result['email']).to eq('john@example.com')
        expect(result['age']).to eq(30)
      end

      it 'keeps deeply nested keys with dot notation' do
        input = {
          'user' => {
            'profile' => {
              'name' => 'John',
              'email' => 'john@example.com'
            }
          }
        }
        result = described_class.fake_json(input, preserve_keys: true, keep: ['user.profile.email'])

        expect(result['user']['profile']['name']).not_to eq('John')
        expect(result['user']['profile']['email']).to eq('john@example.com')
      end

      it 'keeps deeply nested keys with array notation' do
        input = {
          'user' => {
            'profile' => {
              'name' => 'John',
              'email' => 'john@example.com'
            }
          }
        }
        result = described_class.fake_json(input, preserve_keys: true, keep: [['user', 'profile', 'email']])

        expect(result['user']['profile']['name']).not_to eq('John')
        expect(result['user']['profile']['email']).to eq('john@example.com')
      end

      it 'keeps multiple nested paths' do
        input = {
          'user' => { 'name' => 'John', 'email' => 'john@example.com' },
          'metadata' => { 'id' => 123, 'timestamp' => 456 }
        }
        result = described_class.fake_json(
          input,
          preserve_keys: true,
          keep: ['user.email', 'metadata.id']
        )

        expect(result['user']['name']).not_to eq('John')
        expect(result['user']['email']).to eq('john@example.com')
        expect(result['metadata']['id']).to eq(123)
        expect(result['metadata']['timestamp']).to eq(0)
      end

      it 'mixes dot and array notation' do
        input = {
          'user' => { 'name' => 'John', 'email' => 'john@example.com' },
          'metadata' => { 'id' => 123 }
        }
        result = described_class.fake_json(
          input,
          preserve_keys: true,
          keep: ['user.email', ['metadata', 'id']]
        )

        expect(result['user']['email']).to eq('john@example.com')
        expect(result['metadata']['id']).to eq(123)
      end

      it 'keeps numeric values in nested structures' do
        input = { 'data' => { 'count' => 42, 'total' => 100 } }
        result = described_class.fake_json(input, preserve_keys: true, keep: ['data.count'])

        expect(result['data']['count']).to eq(42)
        expect(result['data']['total']).to eq(0)
      end

      it 'works with empty keep array' do
        input = { 'name' => 'John', 'email' => 'john@example.com' }
        result = described_class.fake_json(input, preserve_keys: true, keep: [])

        expect(result['name']).not_to eq('John')
        expect(result['email']).not_to eq('john@example.com')
      end

      it 'handles non-existent paths gracefully' do
        input = { 'name' => 'John' }
        result = described_class.fake_json(input, preserve_keys: true, keep: ['email', 'user.profile.age'])

        expect(result['name']).not_to eq('John')
        expect(result.keys).to contain_exactly('name')
      end

      it 'keeps values in deeply nested structures with multiple levels' do
        input = {
          'level1' => {
            'level2' => {
              'level3' => {
                'secret' => 'password123',
                'public' => 'hello'
              }
            }
          }
        }
        result = described_class.fake_json(
          input,
          preserve_keys: true,
          keep: ['level1.level2.level3.secret']
        )

        expect(result['level1']['level2']['level3']['secret']).to eq('password123')
        expect(result['level1']['level2']['level3']['public']).not_to eq('hello')
      end

      it 'handles complex nested structures with arrays' do
        input = {
          'users' => [
            { 'name' => 'John', 'age' => 30 },
            { 'name' => 'Jane', 'age' => 25 }
          ]
        }
        result = described_class.fake_json(input, preserve_keys: true, keep: ['users.0.name'])

        expect(result['users'][0]['name']).to eq('John')
        expect(result['users'][0]['age']).to eq(0)
        expect(result['users'][1]['name']).not_to eq('Jane')
      end

      it 'keeps string values using dot notation' do
        input = { 'config' => { 'api_key' => 'secret123', 'url' => 'https://example.com' } }
        result = described_class.fake_json(input, preserve_keys: true, keep: ['config.api_key'])

        expect(result['config']['api_key']).to eq('secret123')
        expect(result['config']['url']).not_to eq('https://example.com')
      end

      it 'raises for invalid keep path types' do
        input = { 'name' => 'John' }

        expect {
          described_class.fake_json(input, preserve_keys: true, keep: [123])
        }.to raise_error(ArgumentError, /keep paths must be Strings or Arrays/)
      end

      it 'preserves structure while keeping selective values' do
        input = {
          'user' => {
            'id' => 1,
            'profile' => {
              'email' => 'test@example.com',
              'name' => 'Test User',
              'bio' => 'A long bio'
            },
            'settings' => {
              'theme' => 'dark',
              'notifications' => true
            }
          }
        }
        result = described_class.fake_json(
          input,
          preserve_keys: true,
          keep: ['user.id', 'user.profile.email', 'user.settings.notifications']
        )

        expect(result['user']['id']).to eq(1)
        expect(result['user']['profile']['email']).to eq('test@example.com')
        expect(result['user']['profile']['name']).not_to eq('Test User')
        expect(result['user']['profile']['bio']).not_to eq('A long bio')
        expect(result['user']['settings']['theme']).not_to eq('dark')
        expect(result['user']['settings']['notifications']).to be true
      end
    end
  end
end
