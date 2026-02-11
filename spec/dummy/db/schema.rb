# frozen_string_literal: true

ActiveRecord::Schema.define(version: 1) do
  create_table :users, force: true do |t|
    t.string :email
    t.string :first_name
    t.string :last_name
    t.string :status
    t.string :roles
    t.string :reset_token
    t.string :clever_id
    t.boolean :archived, default: false
    t.string :encrypted_password
    t.timestamps
  end

  create_table :posts, force: true do |t|
    t.references :user, foreign_key: true
    t.string :title
    t.text :body
    t.timestamps
  end

  create_table :versions, force: true do |t|
    t.string :item_type
    t.integer :item_id
    t.string :event
    t.text :object
    t.timestamps
  end

  create_table :logs, force: true do |t|
    t.string :message
    t.string :level
    t.timestamps
  end

  create_table :events, force: true do |t|
    t.string :name
    t.datetime :recorded_at
    t.timestamps
  end
end
