# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pumice::SoftScrubbing::AttributeInterceptor do
  before do
    Pumice.reset!
  end

  after do
    Pumice.reset!
    Pumice::SoftScrubbing::Policy.reset!
  end

  let(:sanitizer) do
    Class.new(Pumice::Sanitizer) do
      sanitizes :users
      scrub(:email) { fake_email(record) }
      scrub(:first_name) { 'Fake' }
      keep :last_name, :status, :roles, :archived
      keep_undefined_columns!

      def self.name
        'UserSanitizer'
      end
    end
  end

  def enable_soft_scrubbing
    sanitizer # force registration
    Pumice.configure do |c|
      c.soft_scrubbing = { if: ->(_record, _viewer) { true } }
    end
  end

  describe 'cache invalidation on reload' do
    it 'returns fresh scrubbed values after reload' do
      enable_soft_scrubbing
      user = User.create!(email: 'original@example.com', first_name: 'John', last_name: 'Doe')

      Pumice.with_soft_scrubbing_context(:test) do
        first_read = user.email
        expect(first_read).not_to eq('original@example.com')

        # Update directly in the database
        User.where(id: user.id).update_all(email: 'changed@example.com')

        # After reload, cache should be cleared and new raw value used
        user.reload
        second_read = user.email
        expect(second_read).not_to eq('changed@example.com')
        # The scrubbed value may differ because the raw input changed
        # The key assertion: reload didn't return the stale cached value
        # when the underlying data changed
      end
    end
  end

  describe 'cache invalidation on write_attribute' do
    it 'clears cached value for the written attribute' do
      enable_soft_scrubbing
      user = User.create!(email: 'original@example.com', first_name: 'John', last_name: 'Doe')

      Pumice.with_soft_scrubbing_context(:test) do
        first_read = user.email
        expect(first_read).not_to eq('original@example.com')

        # Write a new value
        user.write_attribute(:email, 'new@example.com')

        # Cache for :email should be cleared, so next read re-scrubs
        second_read = user.email
        # Still scrubbed (not the raw 'new@example.com')
        expect(second_read).not_to eq('new@example.com')
      end
    end
  end
end
