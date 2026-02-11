# Pumice

Database PII sanitization for Rails. Declarative scrubbing, pruning, and safe export of PII-free database copies. All operations are **non-destructive** to the source database unless you explicitly opt into destructive mode.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Sanitizer DSL](#sanitizer-dsl)
- [Verification](#verification)
- [Helpers](#helpers)
- [Rake Tasks](#rake-tasks)
- [Configuration](#configuration)
- [Safe Scrub](#safe-scrub)
- [Pruning](#pruning)
- [Soft Scrubbing](#soft-scrubbing)
- [Testing](#testing)
- [Materialized Views](#materialized-views)
- [Gotchas](#gotchas)

---

## Quick Start

### 1. Install

```ruby
# Gemfile
gem 'pumice'
```

```bash
bundle install
```

### 2. Create the initializer

```bash
rails generate pumice:install
```

This creates [config/initializers/pumice.rb](config/initializers/pumice.rb) with commented defaults. The defaults work out of the box — customize later as needed.

### 3. Generate a sanitizer (and test)

```bash
rails generate pumice:sanitizer User            # sanitizer + test (if applicable)
```

This inspects your model's columns and generates `app/sanitizers/user_sanitizer.rb` — PII columns get `scrub` stubs, credentials get flagged, and safe columns get `keep` declarations. Every `scrub` block raises `NotImplementedError` until you define the logic.

```bash
rails generate pumice:sanitizer User              # stubs (you define scrub logic)
rails generate pumice:sanitizer User --defaults   # pre-filled with Faker defaults
rails generate pumice:sanitizer User --no-test    # skip test generation
rails generate pumice:test User                   # test only (backfill existing sanitizers)
```

If your project uses RSpec (detected by the presence of `spec/`), a spec is generated with `have_scrubbed` and `have_kept` matchers. See [Testing](#testing) for the full RSpec integration.

### 4. Review and adjust the generated sanitizer

Without `--defaults`, scrub blocks require you to define the logic:

```ruby
# app/sanitizers/user_sanitizer.rb
class UserSanitizer < Pumice::Sanitizer
  # PII - scrub with fake data
  scrub(:email) { raise NotImplementedError }
  scrub(:first_name) { raise NotImplementedError }
  scrub(:last_name) { raise NotImplementedError }

  # Credentials - clear sensitive data
  scrub(:encrypted_password) { raise NotImplementedError }

  # Non-PII - safe to keep
  keep :roles, :active
end
```

With `--defaults`, blocks are pre-filled with smart Faker logic:

```ruby
# app/sanitizers/user_sanitizer.rb (--defaults)
class UserSanitizer < Pumice::Sanitizer
  scrub(:email) { fake_email(record) }
  scrub(:first_name) { Faker::Name.first_name }
  scrub(:last_name) { Faker::Name.last_name }
  scrub(:encrypted_password) { nil }

  keep :roles, :active
end
```

| Column name contains | Pre-filled scrubbing definition |
|---|---|
| `email` | `fake_email(record)` (nil-safe when nullable) |
| `phone`, `call_number` | `fake_phone` (nil-safe when nullable) |
| `first_name` | `Faker::Name.first_name` |
| `last_name` | `Faker::Name.last_name` |
| `name`, `display_name`, `full_name` | `Faker::Name.name` |
| `address`, `street` | `Faker::Address.street_address` |
| `city` | `Faker::Address.city` |
| `state` | `Faker::Address.state_abbr` |
| `zip` | `Faker::Address.zip` |
| `username`, `login` | `"user_#{record.id}"` |
| `bio`, `description`, `notes` | `match_length(value, use: :paragraph)` |
| other `text` columns | `match_length(value, use: :paragraph)` |
| other `string` columns | `Faker::Lorem.word` |
| **Credentials** (`password`, `token`, `secret`, `key`, `encrypted`, `oauth`, etc.) | `nil` |

### 5. Run it

```bash
# Preview what would change (no writes)
rake db:scrub:test

# Generate a scrubbed database dump (source untouched)
rake db:scrub:generate

# Or copy-and-scrub to a separate database
SOURCE_DATABASE_URL=postgres://prod/myapp \
TARGET_DATABASE_URL=postgres://local/myapp_dev \
rake db:scrub:safe
```

That's it. Pumice auto-discovers sanitizers in `app/sanitizers/` and auto-registers them by class name (`UserSanitizer` → `users`).

---

## Sanitizer DSL

Each sanitizer handles one ActiveRecord model. Place them in `app/sanitizers/`.

### `scrub(column, &block)`

Define how to replace a PII column. The block receives the original value and has access to `record` (the ActiveRecord instance) and all [helpers](#helpers).

```ruby
scrub(:first_name) { Faker::Name.first_name }
scrub(:bio) { |value| match_length(value, use: :paragraph) }
scrub(:notes) { |value| value.present? ? Faker::Lorem.sentence : nil }
scrub(:email) { fake_email(record, domain: 'test.example') }
```

### `keep(*columns)`

Mark columns as non-PII. No changes applied.

```ruby
keep :id, :created_at, :updated_at, :role, :status
```

### `keep_undefined_columns!`

Keeps all columns not explicitly defined via `scrub` or `keep`. **Bypasses PII review.** Use only during initial development. Disable globally with:

```ruby
Pumice.configure { |c| c.allow_keep_undefined_columns = false }
```

### Referencing other attributes in scrub blocks

**Bare names** return scrubbed values. **`raw(:attribute_name)`** returns original database values.

```ruby
class UserSanitizer < Pumice::Sanitizer
  scrub(:first_name) { Faker::Name.first_name }
  scrub(:last_name) { Faker::Name.last_name }
  scrub(:display_name) { "#{first_name} #{last_name}" }                        # scrubbed values
  scrub(:email) { "#{raw(:first_name)}.#{raw(:last_name)}@example.test".downcase }  # original values
  keep :id, :created_at, :updated_at
end
```

### Model binding

Inferred from class name by default — `UserSanitizer` automatically binds to `User`, so `sanitizes` is optional when the naming convention matches. Use it when the class name doesn't map directly to the model:

```ruby
class LegacyUserDataSanitizer < Pumice::Sanitizer
  sanitizes :users                                   # binds to User
end

class AdminUserSanitizer < Pumice::Sanitizer
  sanitizes :admin_users, class_name: 'Admin::User'  # namespaced model
end
```

### Friendly names

Controls the name used in rake tasks. Default: class name underscored and pluralized.

```ruby
class TutorSessionFeedbackSanitizer < Pumice::Sanitizer
  friendly_name 'feedback'  # rake 'db:scrub:only[feedback]'
end
```

| Class Name | Default | Custom |
|---|---|---|
| `UserSanitizer` | `users` | - |
| `TutorSessionFeedbackSanitizer` | `tutor_session_feedbacks` | `feedback` |

### `prune` (pre-step, not terminal)

Removes matching records **before** record-by-record scrubbing. Survivors get scrubbed. Use when you have records worth keeping but need to reduce the dataset first.

```ruby
class EmailLogSanitizer < Pumice::Sanitizer
  prune { where(created_at: ..1.year.ago) }  # delete old logs

  scrub(:email) { fake_email(record) }        # scrub the rest
  scrub(:body) { |value| match_length(value, use: :paragraph) }
  keep :user_id, :status
end
```

Convenience shorthands:

```ruby
prune_older_than 1.year
prune_older_than 90.days, column: :updated_at
prune_older_than "2024-01-01"
prune_newer_than 30.days
```

### Bulk operations (terminal)

For tables where you want records **gone**, not scrubbed. The entire sanitizer is just the deletion — no `scrub`/`keep` declarations needed, and no scrubbing runs after. Use `destroy_all` over `delete_all` when you need ActiveRecord callbacks (e.g., `dependent: :destroy` associations).

```ruby
# Wipe entire table (fastest, resets auto-increment)
class SessionSanitizer < Pumice::Sanitizer
  truncate!
end

# SQL DELETE with optional scope (no callbacks)
class VersionSanitizer < Pumice::Sanitizer
  sanitizes :versions, class_name: 'PaperTrail::Version'
  delete_all { where(item_type: %w[User Message]) }
end

# ActiveRecord destroy with callbacks and dependent associations
class AttachmentSanitizer < Pumice::Sanitizer
  destroy_all { where(attachable_id: nil) }
end
```

### When to use what

The key distinction: `prune` is a pre-step that scrubs survivors, while bulk operations are terminal — deletion is the entire sanitizer.

| Goal | DSL | Scrubs survivors? |
|---|---|:---:|
| Delete old records, scrub the rest | `prune` / `prune_[older\|newer]_than` | Yes |
| Wipe entire table | `truncate!` | No |
| Delete matching records (fast, no callbacks) | `delete_all { scope }` | No |
| Delete with callbacks/associations | `destroy_all { scope }` | No |

### Programmatic usage

```ruby
UserSanitizer.sanitize(user)          # returns hash, does not persist
UserSanitizer.sanitize(user, :email)  # returns single scrubbed value
UserSanitizer.scrub!(user)            # persists all scrubbed values
UserSanitizer.scrub!(user, :email)    # persists single scrubbed value
UserSanitizer.scrub_all!              # batch: prune → scrub → verify
```

---

## Verification

Post-operation checks declared inside a sanitizer definition. All verification raises `Pumice::VerificationError` on failure and is skipped during dry runs.

### Table-level

```ruby
class UserSanitizer < Pumice::Sanitizer
  sanitizes :users
  scrub(:email) { Faker::Internet.email }
  keep :id, :created_at, :updated_at

  verify_all "No real emails should remain" do
    where("email LIKE '%@gmail.com'").none?
  end
end
```

The `verify_all` block runs in model scope (`User.instance_exec`). Return truthy for success.

### Per-record

```ruby
class UserSanitizer < Pumice::Sanitizer
  sanitizes :users
  scrub(:email) { Faker::Internet.email }
  keep :id, :created_at, :updated_at

  verify_each "Email should be scrubbed" do |record|
    !record.email.match?(/gmail|yahoo|hotmail/)
  end
end
```

### Inline (bulk operations)

Bulk operations accept a `verify: true` option that uses a default check after execution:

```ruby
class AuditLogSanitizer < Pumice::Sanitizer
  sanitizes :audit_logs
  truncate!(verify: true)                              # verifies count.zero?
end

class VersionSanitizer < Pumice::Sanitizer
  sanitizes :versions
  delete_all(verify: true) { where(item_type: 'User') } # verifies scope.none?
end
```

### Default verification for bulk operations

| Operation | Default check |
|---|---|
| `truncate!` | `count.zero?` |
| `delete_all` (no scope) | `count.zero?` |
| `delete_all { scope }` | `scope.none?` |
| `destroy_all` (no scope) | `count.zero?` |
| `destroy_all { scope }` | `scope.none?` |

Call `verify_all` without a block on a bulk sanitizer to use the default. Calling `verify_all` without a block on a non-bulk sanitizer raises `ArgumentError`.

### Custom verification policy

```ruby
Pumice.configure do |config|
  config.default_verification = ->(_model_class, operation) {
    case operation[:type]
    when :truncate
      -> { count.zero? }
    when :delete, :destroy
      operation[:scope] || -> { count.zero? }
    end
  }
end
```

---

## Helpers

All helpers are available inside `scrub` blocks via `Pumice::Helpers`.

### Quick reference

| Helper | Output | Example |
|---|---|---|
| `fake_email(record)` | `user_123@example.test` | Deterministic per record |
| `fake_phone(digits = 10)` | `5551234567` | Random digits |
| `fake_password(pwd = 'password123', cost: 4)` | `$2a$04$...` | BCrypt hash |
| `fake_id(id, prefix: 'ID')` | `ID000123` | Zero-padded |
| `match_length(value, use: :sentence)` | `Lorem ipsum...` | Matches original length |
| `fake_json(value, preserve_keys: true, keep: [])` | `{"name": "lorem"}` | Structure-preserving |

### `fake_email`

Deterministic — same record always produces the same email across runs. Important for data consistency.

```ruby
scrub(:email) { fake_email(record) }                               # user_123@example.test
scrub(:email) { fake_email(record, domain: 'test.example.com') }   # user_123@test.example.com
scrub(:contact_email) { fake_email(prefix: 'contact', unique_id: record.id) }
```

### `fake_password`

Uses low BCrypt cost (4) for speed. All scrubbed users get the same password so devs can log in.

```ruby
scrub(:encrypted_password) { fake_password }                # hash of 'password123'
scrub(:encrypted_password) { fake_password('testpass') }    # custom password
```

### `match_length`

Generates text approximating the original value's length. Respects column constraints.

```ruby
scrub(:bio) { |value| match_length(value, use: :paragraph) }
scrub(:code) { |value| match_length(value, use: :characters) }  # random alphanumeric
scrub(:title) { |value| match_length(value, use: -> { Faker::Book.title }) }  # custom generator
```

| Generator | Best for |
|---|---|
| `:sentence` | Bios, comments (default) |
| `:paragraph` | Long-form content |
| `:word` | Short fields, names |
| `:characters` | Codes, tokens |
| `-> { ... }` | Any custom Faker or logic |

### `fake_json`

Sanitizes JSON structures. Strings become random words, numbers become `0`, booleans and `nil` are preserved. Structure (nesting depth, array lengths) is always retained.

```ruby
scrub(:preferences) { |value| fake_json(value) }                          # fake values, keep keys
scrub(:metadata) { |value| fake_json(value, preserve_keys: false) }       # fake keys AND values
scrub(:config) { |value| fake_json(value, keep: ['api_version']) }         # preserve specific key/value pairs
scrub(:data) { |value| fake_json(value, keep: ['user.profile.email']) }    # dot notation for nesting
```

| Option | Keys | Values |
|---|---|---|
| `fake_json(value)` | Original | Faked |
| `fake_json(value, preserve_keys: false)` | Faked | Faked |
| `fake_json(value, keep: ['path'])` | Original (kept paths preserved) | Faked (kept paths preserved) |
| `fake_json(value, preserve_keys: false, keep: ['path'])` | Faked (kept paths preserved) | Faked (kept paths preserved) |

### Custom helpers

Extend `Pumice::Helpers` for project-specific needs:

```ruby
# config/initializers/pumice_helpers.rb
module Pumice
  module Helpers
    def fake_student_id(record)
      "STU-#{record.school_id}-#{sprintf('%04d', record.id)}"
    end

    def redact(value, show_last: 4)
      return nil if value.blank?
      "#{'*' * (value.length - show_last)}#{value.last(show_last)}"
    end
  end
end
```

---

## Rake Tasks

### Inspection

```bash
rake db:scrub:list         # list registered sanitizers and their friendly names
rake db:scrub:lint         # check all columns are defined (scrub or keep), exits 1 on issues
rake db:scrub:validate     # check scrubbed DB for PII leaks (real emails, uncleared tokens)
rake db:scrub:analyze      # show top 20 tables by size, row counts for sensitive tables
```

### Safe operations (source never modified)

```bash
rake db:scrub:test                    # dry run all sanitizers
rake 'db:scrub:test[users,messages]'  # dry run specific sanitizers
rake db:scrub:generate                # create temp DB, scrub, export dump, cleanup
rake db:scrub:safe                    # copy to target DB, scrub target (interactive)
rake 'db:scrub:safe_confirmed[mydb]'  # same, but auto-confirmed for CI
```

### Destructive operations (modifies current DATABASE_URL)

```bash
rake db:scrub:all                     # scrub current DB in-place (interactive confirmation)
rake 'db:scrub:only[users,messages]'  # scrub specific tables in-place
```

### Environment variables

| Variable | Effect |
|---|---|
| `DRY_RUN=true` | Log changes without persisting |
| `VERBOSE=true` | Detailed progress output |
| `PRUNE=false` | Disable pruning without changing config |
| `SOURCE_DATABASE_URL` | Source DB for safe scrub |
| `TARGET_DATABASE_URL` | Target DB for safe scrub |
| `SCRUBBED_DATABASE_URL` | Alternative to `TARGET_DATABASE_URL` |
| `EXPORT_PATH` | Path to export scrubbed dump |
| `EXCLUDE_INDEXES=true` | Exclude indexes/triggers/constraints from dump |
| `EXCLUDE_MATVIEWS=false` | Include materialized views in dump (excluded by default) |

---

## Configuration

Create an initializer. All settings have sensible defaults — only override what you need.

```ruby
# config/initializers/sanitization.rb
Pumice.configure do |config|
  # Column coverage enforcement (default: true)
  # Raises if a sanitizer doesn't define every column as scrub or keep
  config.strict = true

  # Tables to report row counts for in db:scrub:analyze (default: [])
  config.sensitive_tables = %w[users messages student_profiles]

  # Email domains that indicate real PII — validation fails if found (default: [])
  config.sensitive_email_domains = %w[gmail.com yahoo.com hotmail.com]
end
```

### Full options reference

| Option | Default | Description |
|---|---|---|
| `verbose` | `false` | Increase console output detail |
| `strict` | `true` | Raise if sanitizer columns are undefined |
| `continue_on_error` | `false` | Continue on sanitizer failure vs halt |
| `allow_keep_undefined_columns` | `true` | Allow `keep_undefined_columns!` DSL |
| `sensitive_tables` | `[]` | Tables to analyze for row counts |
| `sensitive_email_domains` | `[]` | Domains indicating real PII |
| `sensitive_email_model` | `'User'` | Model to query for email validation |
| `sensitive_email_column` | `'email'` | Column for email lookup |
| `sensitive_token_columns` | `%w[reset_password_token confirmation_token]` | Token columns to verify are cleared |
| `sensitive_external_id_columns` | `[]` | External ID columns to verify are cleared |
| `source_database_url` | `nil` | Source DB for safe scrub (`:auto` to derive from Rails config) |
| `target_database_url` | `nil` | Target DB for safe scrub |
| `export_path` | `nil` | Path to export scrubbed dump |
| `export_format` | `:custom` | `:custom` (pg_dump -Fc) or `:plain` (SQL) |
| `require_readonly_source` | `false` | Enforce read-only source (error vs warn) |
| `soft_scrubbing` | `false` | Runtime PII masking — set to hash to enable |
| `pruning` | `false` | Pre-sanitization record pruning — set to hash to enable |

---

## Safe Scrub

Safe Scrub creates a sanitized copy of your database without modifying the source. This is the recommended workflow for production environments.

### Flow

```
rake db:scrub:generate
├─ Create temp database
├─ Copy source → temp
├─ Run global pruning (if configured)
├─ Run all sanitizers
├─ Export dump file
└─ Drop temp database

rake db:scrub:safe
├─ Validate source ≠ target
├─ Confirm target DB name (interactive or argument)
├─ Drop and recreate target
├─ Copy source → target
├─ Run global pruning
├─ Run sanitizers
├─ Verify
└─ Export (if configured)
```

### Configuration

```ruby
Pumice.configure do |config|
  # Auto-detect source from database.yml (works in Docker dev with zero env vars)
  config.source_database_url = :auto unless Rails.env.production?

  # Or set explicitly
  # config.source_database_url = ENV['DATABASE_URL']

  config.target_database_url = ENV['SCRUBBED_DATABASE_URL']
  config.export_path = "tmp/scrubbed_#{Date.today}.dump"
  config.export_format = :custom  # :custom (pg_dump -Fc) or :plain (SQL)
end
```

When `source_database_url` is `:auto`, Pumice derives the URL from `ActiveRecord::Base.connection_db_config`. This means `rake db:scrub:generate` works locally with no env vars.

Environment variables (`SOURCE_DATABASE_URL`) always take precedence over config.

### Safety guarantees

- Source database is **never modified** — read-only access
- Target cannot equal `DATABASE_URL` — prevents accidental production writes
- Source and target must differ — validated at startup
- Interactive confirmation — must type the target DB name
- Write-access detection — warns (or errors) if source credentials can write

### Read-only source credentials (recommended)

```sql
-- On source (production): read-only
CREATE ROLE pumice_readonly WITH LOGIN PASSWORD 'readonly_secret';
GRANT CONNECT ON DATABASE myapp_production TO pumice_readonly;
GRANT USAGE ON SCHEMA public TO pumice_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pumice_readonly;

-- On target: full access
CREATE ROLE pumice_writer WITH LOGIN PASSWORD 'writer_secret';
CREATE DATABASE myapp_scrubbed OWNER pumice_writer;
```

```bash
SOURCE_DATABASE_URL=postgres://pumice_readonly:readonly_secret@prod-host/myapp_production
TARGET_DATABASE_URL=postgres://pumice_writer:writer_secret@scrub-host/myapp_scrubbed
```

Even if URLs are swapped, the read-only credential cannot modify production.

To enforce read-only source (error instead of warning):

```ruby
config.require_readonly_source = true
```

### CI mode

```bash
# Auto-confirmed — argument must match target DB name or the task fails
rake 'db:scrub:safe_confirmed[myapp_scrubbed]'
```

### Programmatic usage

```ruby
Pumice::SafeScrubber.new(
  source_url: ENV['DATABASE_URL'],
  target_url: ENV['SCRUBBED_DATABASE_URL'],
  export_path: 'tmp/scrubbed.dump',
  confirm: true  # skip interactive prompt
).run
```

### Error types

| Error | Cause |
|---|---|
| `Pumice::ConfigurationError` | Missing URL, source = target, target = DATABASE_URL, confirmation mismatch |
| `Pumice::SourceWriteAccessError` | `require_readonly_source = true` and source has write access |

---

## Pruning

Removes old records before sanitization to reduce dataset size. Useful for log tables, audit trails, and event streams.

Pumice supports pruning at two levels:

- **Per-sanitizer `prune`** — defined inside a sanitizer with a custom scope. Runs as part of that sanitizer's `scrub_all!`, right before record-by-record scrubbing. See [`prune` in the Sanitizer DSL](#prune-pre-step-not-terminal).
- **Global pruning** — configured once in the initializer. Applies a single age-based rule across many tables at once, before any sanitizers run. Useful when you want a blanket retention policy (e.g., "delete everything older than 90 days") without adding `prune` to every sanitizer.

Use per-sanitizer `prune` when different tables need different scopes (age-based, status-based, etc.). Use global pruning when a uniform retention policy covers most tables.

### Analyze first

```bash
rake db:prune:analyze

# Customize thresholds
RETENTION_DAYS=30 MIN_SIZE=50000000 MIN_ROWS=5000 rake db:prune:analyze
```

The analyzer categorizes tables by confidence:

- **High**: Log tables, >50% old records, no foreign key dependencies
- **Medium**: Log tables OR >70% old, no dependencies
- **Low**: Everything else — review before pruning

### Global pruning configuration

```ruby
Pumice.configure do |config|
  config.pruning = {
    older_than: 90.days,          # required (mutually exclusive with newer_than)
    column: :created_at,          # default
    except: %w[users messages],   # never prune these (mutually exclusive with only)
    on_conflict: :warn,           # when global + sanitizer prune overlap: :warn, :raise, :rollback

    analyzer: {
      table_patterns: %w[portal_session voice_log],  # domain-specific log patterns
      min_table_size: 10_000_000,                      # 10 MB (default)
      min_row_count: 1000                              # default
    }
  }
end
```

### Execution order

```
1. Global pruning     → deletes across all eligible tables (config.pruning)
2. Per-sanitizer prune → deletes within one table (DSL prune block)
3. Record-by-record scrub → scrubs surviving records
```

Global pruning runs once before any sanitizers execute. Per-sanitizer `prune` runs inside each sanitizer's `scrub_all!`, just before scrubbing begins. If the same table is pruned at both levels, the `on_conflict` option controls behavior (`:warn`, `:raise`, or `:rollback`).

### Disable at runtime

```bash
PRUNE=false rake db:scrub:generate
```

---

## Soft Scrubbing

Masks data at read time without modifying the database. Use for runtime access control — e.g., non-admin users see scrubbed PII, admins see real data.

### Enable

```ruby
Pumice.configure do |config|
  config.soft_scrubbing = {
    context: :current_user,
    if: ->(record, viewer) { viewer.nil? || !viewer.admin? }
  }
end
```

When enabled, Pumice prepends an attribute interceptor on `ActiveRecord::Base`. On attribute read, the policy is checked. If it returns true, the `scrub` block runs and the scrubbed value is returned. The database is never modified.

### Policy options

| Option | Behavior |
|---|---|
| `if:` | Scrub when lambda returns **true** |
| `unless:` | Scrub when lambda returns **false** |
| Neither | Always scrub |

Both receive `(record, viewer)`. They are mutually exclusive — `if:` takes precedence.

### Setting viewer context

```ruby
# In ApplicationController
before_action { Pumice.soft_scrubbing_context = current_user }

# Or scoped
Pumice.with_soft_scrubbing_context(current_user) do
  @users = User.all  # reads scrubbed for non-admins
end
```

The `context:` config option resolves a Symbol through: `record.method` → `Pumice.method` → `Current.method` → `Thread.current[:key]`.

### Accessing original values

When soft scrubbing is enabled, attribute reads return scrubbed values. To access the original database value:

**Inside sanitizer definitions** — `raw(:*)` and `raw_attr` are available via the sanitizer DSL (see [Referencing other attributes](#referencing-other-attributes-in-scrub-blocks)).

**Inside ActiveRecord models** — use `read_attribute(:attr)` or define a helper:

```ruby
class User < ApplicationRecord
  def admin?
    ADMIN_EMAILS.include?(read_attribute(:email))
  end

  # Or define a convenience method:
  def raw(attr_name)
    if Pumice.soft_scrubbing?
      read_attribute(attr_name)
    else
      @attributes.fetch_value(attr_name.to_s)
    end
  end
end
```

---

## Testing

### Setup

```ruby
# spec/rails_helper.rb
require 'pumice/rspec'
```

This gives you:

- **Auto-reset** — `Pumice.reset!` runs before each `type: :sanitizer` spec
- **Auto-lint** — column coverage is verified automatically; incomplete sanitizers fail before examples run
- **Path inference** — specs in `spec/sanitizers/` are automatically tagged `type: :sanitizer`
- **Helpers** — `with_soft_scrubbing` and `without_soft_scrubbing` available in sanitizer specs
- **Matchers** — `have_scrubbed(:attr)` and `have_kept(:attr)` for verifying sanitizer definitions

### Sanitizer specs

```ruby
# spec/sanitizers/user_sanitizer_spec.rb
RSpec.describe UserSanitizer, type: :sanitizer do
  let(:user) { create(:user, email: 'real@gmail.com', first_name: 'John') }

  # Column coverage is checked automatically — no need to add a lint test.

  describe '.sanitize' do
    it 'returns sanitized values without persisting' do
      result = described_class.sanitize(user)

      expect(result[:email]).to match(/user_\d+@example\.test/)
      expect(user.reload.email).to eq('real@gmail.com')
    end
  end

  describe '.scrub!' do
    it 'persists sanitized values' do
      described_class.scrub!(user)
      expect(user.reload.email).to match(/user_\d+@example\.test/)
    end
  end
end
```

To skip auto-lint for a specific sanitizer (e.g., during initial development):

```ruby
RSpec.describe UserSanitizer, type: :sanitizer, lint: false do
  # ...
end
```

### Soft scrubbing specs

```ruby
RSpec.describe 'User soft scrubbing', type: :sanitizer do
  let(:user) { create(:user, email: 'real@gmail.com') }
  let(:admin) { create(:user, :admin) }
  let(:regular) { create(:user) }

  it 'scrubs for non-admins' do
    with_soft_scrubbing(viewer: regular, if: ->(r, v) { !v.admin? }) do
      expect(user.email).to match(/user_\d+@example\.test/)
    end
  end

  it 'shows real data to admins' do
    with_soft_scrubbing(viewer: admin, if: ->(r, v) { !v.admin? }) do
      expect(user.email).to eq('real@gmail.com')
    end
  end
end
```

### Helpers reference

| Helper | Use |
|---|---|
| `with_soft_scrubbing(viewer:, if:, unless:)` | Enable soft scrubbing for a block |
| `without_soft_scrubbing { ... }` | Disable soft scrubbing for a block |
| `have_scrubbed(:attr)` | Assert a sanitizer defines a scrub rule for `:attr` |
| `have_kept(:attr)` | Assert a sanitizer marks `:attr` as kept |

Both soft scrubbing helpers restore original config after the block, even on error.

```ruby
# Matcher examples
RSpec.describe UserSanitizer, type: :sanitizer do
  it { is_expected.to have_scrubbed(:email) }
  it { is_expected.to have_scrubbed(:first_name) }
  it { is_expected.to have_kept(:role) }
end
```

---

## Materialized Views

Pumice includes rake tasks for managing materialized views, which are relevant during safe scrub since view data is excluded from dumps by default.

```bash
rake db:matviews:list                    # list all materialized views with sizes
rake db:matviews:refresh                 # refresh all materialized views
rake 'db:matviews:refresh[view1,view2]'  # refresh specific views
```

After restoring a scrubbed dump, refresh materialized views to rebuild their data:

```bash
pg_restore -d myapp_dev tmp/scrubbed.dump && rake db:matviews:refresh
```

Set `EXCLUDE_MATVIEWS=false` to include materialized view data in the dump (skipping the need to refresh after restore).

---

## Gotchas

### Strict mode and new columns

When `strict: true` (default), adding a column to a model without updating its sanitizer will raise an error on next scrub. Run `rake db:scrub:lint` in CI to catch this early.

### Bulk operations skip column validation

`truncate!`, `delete_all`, and `destroy_all` don't require `scrub`/`keep` declarations. Strict mode doesn't apply to them.

### Faker seeding

Pumice seeds Faker with `record.id` before each record. This makes scrubbing **deterministic** — the same record always produces the same fake values. Important for consistency across runs.

### Protected columns

`id`, `created_at`, and `updated_at` are automatically excluded from column coverage checks. You never need to declare them.

### Soft scrubbing circular dependency

If your policy check reads a scrubbed attribute (e.g., `viewer.admin?` checks `viewer.email`), use `read_attribute(:email)` instead. Without this, the policy triggers scrubbing, which triggers the policy — infinite loop. Pumice includes a recursion guard that falls through to `super` (the real value) on re-entry, so the app won't crash, but `read_attribute()` makes the intent explicit.

### `source_database_url = :auto`

Only works with PostgreSQL. Builds a URL from `ActiveRecord::Base.connection_db_config` components. Returns `nil` for non-PostgreSQL adapters.

### Pruning mutual exclusivity

- `older_than` and `newer_than` cannot both be set — raises `ArgumentError`
- `only` and `except` cannot both be set — they are mutually exclusive
- One of `older_than` or `newer_than` is required

### Global pruning and foreign keys

The global pruner skips tables with foreign key dependencies and logs a warning. Per-sanitizer `prune` does **not** check dependencies — that's on you.

### Safe scrub connection management

Safe Scrub temporarily changes `ActiveRecord::Base.connection_db_config` to operate on the target. It always restores the original connection, even on error. Existing connections to the target are terminated before DROP/CREATE.

---

## License

MIT
