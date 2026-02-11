# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.test" }
    first_name { "Test" }
    last_name { "User" }
    status { "active" }
    roles { "member" }
  end
end
