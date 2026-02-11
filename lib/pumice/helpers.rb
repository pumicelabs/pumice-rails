# frozen_string_literal: true
require 'bcrypt'

module Pumice
  module Helpers
    extend self

    GENERATORS = {
      sentence:  ->(len) { Faker::Lorem.sentence(word_count: [len / 5, 3].max) },
      paragraph: ->(len) { Faker::Lorem.paragraph(sentence_count: [len / 50, 2].max, supplemental: true) },
      word:      ->(len) { Faker::Lorem.word },
      characters: ->(len) { Faker::Lorem.characters(number: len) }
    }.freeze

    def match_length(value, use: :sentence)
      length = value.to_s.length
      return nil if length.zero?

      text = case use
             when Symbol
               generator = GENERATORS[use] || GENERATORS[:sentence]
               generator.call(length)
             when Proc
               use.call
             else
               raise ArgumentError, "use: must be a Symbol or Proc"
             end

      text.to_s.truncate(length + 10)
    end

    def fake_phone(last = 10)
      Faker::PhoneNumber.cell_phone.gsub(/\D/, '').last(last)
    end

    def fake_password(password = 'password123', cost: 4)
      BCrypt::Password.create(password, cost: cost)
    end

    def fake_id(id, prefix: 'ID')
      "#{prefix}#{sprintf('%06d', id)}"
    end

    def fake_or_blank(old_value, new_value)
      old_value.present? ? new_value : nil
    end

    def fake_json(value, preserve_keys: true, keep: [])
      return nil if value.nil?

      data = case value
             when Hash, Array
               value
             when String
               JSON.parse(value)
             else
               raise TypeError, "fake_json expects Hash, Array, or JSON String, got #{value.class}"
             end

      return {} unless preserve_keys

      # Normalize keep paths to arrays for consistent comparison
      normalized_keep = normalize_keep_paths(keep)

      scrub_json_values(data, keep_paths: normalized_keep)
    rescue JSON::ParserError => e
      raise TypeError, "fake_json received invalid JSON string: #{e.message}"
    end

    def fake_email(record_or_prefix = nil, prefix: 'abc', domain: 'example.test', unique_id: nil)
      record = record_or_prefix if record_or_prefix.respond_to?(:id)
      id = unique_id || record&.id

      raise ArgumentError, 'fake_email requires a unique_id or record with id' unless id

      effective_prefix = if record
                           record.class.name.underscore
                         else
                           prefix.to_s
                         end

      Faker::Internet.email(name: "#{effective_prefix}#{id}", domain: domain)
    end

    private

    def normalize_keep_paths(keep)
      return [] if keep.nil? || keep.empty?

      keep.map do |path|
        case path
        when String
          path.split('.')
        when Array
          path.map(&:to_s)
        else
          raise ArgumentError, "keep paths must be Strings or Arrays, got #{path.class}"
        end
      end
    end

    def scrub_json_values(obj, keep_paths: [], current_path: [])
      case obj
      when Hash
        obj.each_with_object({}) do |(key, value), result|
          new_path = current_path + [key.to_s]
          result[key] = scrub_json_values(value, keep_paths: keep_paths, current_path: new_path)
        end
      when Array
        obj.map.with_index do |value, idx|
          new_path = current_path + [idx.to_s]
          scrub_json_values(value, keep_paths: keep_paths, current_path: new_path)
        end
      when String
        should_keep?(current_path, keep_paths) ? obj : Faker::Lorem.word
      when Numeric
        should_keep?(current_path, keep_paths) ? obj : 0
      when TrueClass, FalseClass
        obj
      else
        nil
      end
    end

    def should_keep?(current_path, keep_paths)
      keep_paths.any? { |keep_path| keep_path == current_path }
    end
  end
end
