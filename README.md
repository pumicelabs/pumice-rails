# Pumice

A Rails library for sanitizing sensitive data (PII) in databases. All scrubbing operations are **non-destructive** to the source database.

## Usage Scenarios

| Scenario | Command | Source Modified? | Description |
|----------|---------|:---------------:|-------------|
| Generate scrubbed dump | `rake db:scrub:generate` | No | Creates temp copy, scrubs, exports dump, cleans up |
| Copy to secondary DB | `rake db:scrub:safe` | No | Copies to target database, scrubs target |
| Live soft scrubbing | `config.soft_scrubbing = {}` | No | Runtime masking without any database changes |

### Quick Start

```bash
# Generate a scrubbed SQL dump (source database untouched)
# With config.source_database_url = :auto, no env vars needed locally:
docker compose run --rm web bundle exec rake db:scrub:generate

# Copy and scrub to a separate database
SOURCE_DATABASE_URL=postgres://prod/myapp \
TARGET_DATABASE_URL=postgres://local/myapp_dev \
docker compose run --rm web bundle exec rake db:scrub:safe

# Enable soft scrubbing for runtime PII masking
# In config/initializers/sanitization.rb:
Pumice.configure { |c| c.soft_scrubbing = {} }
```

---

## Table of Contents

- [Usage Scenarios](#usage-scenarios)
- [Setup](#setup)
- [Configuration](#configuration)
- [Defining Sanitizers](#defining-sanitizers)
- [DSL Reference](#dsl-reference)
- [Hard Scrubbing](#hard-scrubbing)
- [Safe Scrub](#safe-scrub)
- [Pruning](#pruning)
- [Soft Scrubbing](#soft-scrubbing)
- [Testing](#testing)
- [Roadmap](#roadmap)

---

## Setup

### 1. Create the initializer

```ruby
# config/initializers/sanitization.rb
require Rails.root.join('lib/pumice')

Pumice.configure do |config|
  # Tables containing PII to analyze for row counts
  config.sensitive_tables = %w[users messages student_profiles]

  # Email domains that indicate real PII (validation fails if found)
  config.sensitive_email_domains = %w[gmail.com yahoo.com hotmail.com]

  # Enable soft scrubbing for runtime masking
  config.soft_scrubbing = {}
end
```

### 2. Create sanitizer classes

Place sanitizers in `app/sanitizers/` (auto-loaded by Rails). Sanitizers are auto-discovered by rake tasks based on class name:

```ruby
# app/sanitizers/user_sanitizer.rb
class UserSanitizer < Pumice::Sanitizer
  # Define scrub rules for each PII column
  scrub(:email) { fake_email(record) }
  scrub(:first_name) { Faker::Name.first_name }

  # Mark non-PII columns as safe to keep
  keep :created_at, :updated_at, :roles
end
# Auto-discovered as 'users' for rake tasks
```

Sanitizers are automatically registered when they inherit from `Pumice::Sanitizer`. The friendly name for rake tasks is derived from the class name (`UserSanitizer` → `users`). To customize:

```ruby
class TutorSessionFeedbackSanitizer < Pumice::Sanitizer
  friendly_name 'feedback'  # Use 'feedback' instead of 'tutor_session_feedbacks'
  # ...
end
```

---

## Configuration

```ruby
Pumice.configure do |config|
  # Increase console output (default: true)
  config.verbose = false
  # Raise if columns are undefined (default: true)
  config.strict = false
  # Stop on first sanitizer failure (default: true)
  config.continue_on_error = false 
  # Allow the use of keep_undefined_columns! in sanitizers (default: true)
  config.allow_keep_undefined_columns = false  
  # Tables containing PII to analyze (default: [])
  config.sensitive_tables = ['users', 'accounts']
  # Email domains that indicate real PII (validation fails if found)(default: [])
  config.sensitive_email_domains = ['gmail.com', 'microsoft.com']
  # Model to query for email validation (default: 'User')
  config.sensitive_email_model = 'Account'
  # Column name for email lookup (default: 'email')
  config.sensitive_email_column = 'email_address'
  # Token columns to verify are cleared during validation (default: Devise tokens)
  config.sensitive_token_columns = %w[reset_password_token confirmation_token]
  # External ID columns to verify are cleared (default: [])
  config.sensitive_external_id_columns = %w[clever_id google_id]

  # Soft scrubbing (runtime PII masking)

  # Default: false (disabled). Set to hash to enable with options.
  config.soft_scrubbing = {
    context: :current_user,  # Viewer context: user object, Proc, or Symbol
    if: ->(record, viewer) { viewer.nil? || !viewer.admin? }  # Scrub if not admin
    # Or use unless: for the inverse logic
    # unless: ->(record, viewer) { viewer&.admin? }  # Scrub unless viewer is admin
  }
  # How to handle raw_* method conflicts (default: :skip)
  # :skip  - silently skip (existing method takes precedence)
  # :warn  - log warning but continue
  # :raise - raise Pumice::MethodConflictError
  config.on_raw_method_conflict = :warn

  # Safe scrub (copy-then-scrub workflow)

  # Source database URL (default: nil, falls back to DATABASE_URL)
  # Set to :auto to derive from ActiveRecord config (no env vars needed locally)
  config.source_database_url = :auto unless Rails.env.production?
  # Target database URL (default: nil, falls back to SCRUBBED_DATABASE_URL)
  config.target_database_url = ENV['SCRUBBED_DATABASE_URL']
  # Optional export path for scrubbed dump (default: nil)
  config.export_path = "tmp/scrubbed_#{Date.today}.dump"
  # Export format: :custom (pg_dump -Fc) or :plain (SQL) (default: :custom)
  config.export_format = :custom
  # Enforce read-only source credentials (default: false = warn only)
  config.require_readonly_source = true

  # Pruning (remove old records before sanitization)

  # Delete old records to reduce dataset size (default: false = disabled)
  config.pruning = {
    older_than: 90.days,          # Delete records older than this (mutually exclusive with newer_than)
    # newer_than: 30.days,        # Or delete records newer than this
    column: :created_at,          # Timestamp column to check (default: :created_at)
    on_conflict: :warn,           # :warn, :raise, or :rollback when a sanitizer also declares prune
    # only: %w[logs events],      # Prune ONLY these tables (whitelist)
    except: %w[users messages]    # Never prune these tables (blacklist)
  }
end
```

### Environment Variables

Runtime options controlled via environment variables:

| Variable | Description |
|----------|-------------|
| `DRY_RUN=true` | Log changes without persisting to database |
| `VERBOSE=true` | Show detailed progress output |
| `PRUNE=false` | Disable pruning without changing config |
| `SOURCE_DATABASE_URL` | Source database for safe scrub (falls back to `DATABASE_URL`) |
| `TARGET_DATABASE_URL` | Target database for safe scrub |
| `SCRUBBED_DATABASE_URL` | Alternative to `TARGET_DATABASE_URL` |
| `EXPORT_PATH` | Path to export scrubbed database dump |

---

## Defining Sanitizers

Each sanitizer handles one ActiveRecord model:

```ruby
class UserSanitizer < Pumice::Sanitizer
  # Explicit model binding (optional if name matches *Sanitizer pattern)
  sanitizes :user

  # PII columns - define replacement logic
  scrub(:email) { fake_email(record) }
  scrub(:first_name) { Faker::Name.first_name }
  scrub(:last_name) { Faker::Name.last_name }
  scrub(:phone) { fake_phone }
  scrub(:address) { Faker::Address.street_address }
  scrub(:encrypted_password) { fake_password }
  scrub(:api_token) { nil }  # Clear sensitive tokens

  # Non-PII columns - explicitly mark as safe
  keep :id, :created_at, :updated_at, :roles, :active

  # UNSAFE: Keep all undefined columns (bypasses PII review)
  # Only use for development/testing
  keep_undefined_columns!
end
```

---

## DSL Reference

### `scrub(column_name, &block)`

Define how to sanitize a column. The block receives the original value and has access to:

- `record` - The ActiveRecord instance being sanitized
- Helper methods from `Pumice::Helpers`
- Other scrubbed attributes (by name)
- Raw database values (via `raw_*` methods)

```ruby
# Simple replacement
scrub(:first_name) { Faker::Name.first_name }

# Access original value
scrub(:bio) { |value| match_length(value, use: :paragraph) }

# Access the record
scrub(:email) { fake_email(record, domain: 'test.example') }

# Conditional logic
scrub(:notes) { |value| value.present? ? Faker::Lorem.sentence : nil }
```

#### Referencing Other Attributes

Within `scrub` blocks, you can reference other attributes using clean, readable syntax:

**Bare attribute names return scrubbed values:**

```ruby
class ClassroomSanitizer < Pumice::Sanitizer
  scrub(:name) { Faker::Educator.course_name }
  scrub(:abbreviation) { name }  # Uses the scrubbed name
  # If name is scrubbed to "Advanced Physics", abbreviation also gets "Advanced Physics"
end
```

**The `raw_*` prefix accesses original database values:**

```ruby
class UserSanitizer < Pumice::Sanitizer
  scrub(:first_name) { Faker::Name.first_name }
  scrub(:last_name) { Faker::Name.last_name }

  # Use raw database values to maintain relationships
  scrub(:email) { "#{raw_first_name}.#{raw_last_name}@example.test".downcase }
  # If DB has first_name="John", last_name="Doe", email becomes "john.doe@example.test"
end
```

**Complex dependencies:**

```ruby
class StudentProfileSanitizer < Pumice::Sanitizer
  scrub(:student_id) { fake_id(record.id, prefix: 'STU') }
  scrub(:display_name) { "Student #{student_id}" }  # Uses scrubbed student_id
  scrub(:login) { "#{raw_first_name}_#{student_id}".downcase }  # Mixes raw and scrubbed
end
```

**Why this is useful:**

- **Maintain data consistency** - Derived fields stay consistent with their source
- **Preserve relationships** - Related fields use the same scrubbed values
- **Readable code** - Clear whether you want scrubbed or raw values
- **Avoid repetition** - Don't duplicate scrubbing logic across columns

### `keep(*column_names)`

Mark columns as non-PII, safe to keep unchanged:

```ruby
keep :id, :created_at, :updated_at
keep :role, :status, :active
```

### `keep_undefined_columns!`

**Use with caution.** Keeps all columns not explicitly defined via `scrub` or `keep`. Bypasses PII review. Disable in production with:

```ruby
Pumice.configure { |c| c.allow_keep_undefined_columns = false }
```

### `sanitizes(model_name, class_name:)`

Explicitly bind to a model (optional if sanitizer follows `ModelSanitizer` naming):

```ruby
class LegacyUserDataSanitizer < Pumice::Sanitizer
  sanitizes :user  # Binds to User model
end

# Or with explicit class name (useful for namespaced models)
class AdminUserSanitizer < Pumice::Sanitizer
  sanitizes :admin_user, class_name: 'Admin::User'
end

# Also accepts a constant
class V2UserSanitizer < Pumice::Sanitizer
  sanitizes :user, class_name: V2::User
end
```

### `friendly_name(name)`

Override the auto-derived name used by rake tasks. By default, the name is derived from the class name:

| Class Name | Default Friendly Name |
|------------|----------------------|
| `UserSanitizer` | `users` |
| `StudentProfileSanitizer` | `student_profiles` |
| `TutorSessionFeedbackSanitizer` | `tutor_session_feedbacks` |

To customize:

```ruby
class TutorSessionFeedbackSanitizer < Pumice::Sanitizer
  friendly_name 'feedback'  # rake 'db:scrub:only[feedback]'
end

class ChatMessageSanitizer < Pumice::Sanitizer
  friendly_name 'chat'  # rake 'db:scrub:only[chat]'
end
```

### `prune(&scope)`

Removes matching records **before** record-by-record scrubbing. Use when a table has too many records but you still need to scrub the survivors.

Unlike bulk operations (`truncate!`, `delete_all`, `destroy_all`) which are **terminal** (no scrubbing runs after), `prune` is a **pre-step**: it deletes matching records first, then scrubbing continues on the remaining records.

```ruby
# Delete old records, then scrub the rest
class EmailLogSanitizer < Pumice::Sanitizer
  scrub(:email) { fake_email(record) }
  scrub(:subject) { match_length(raw_subject) }
  scrub(:body) { match_length(raw_body, use: :paragraph) }
  scrub(:headers) { fake_json(raw_headers) }

  keep :user_id, :status

  prune { where(created_at: ..1.year.ago) }
end

# Delete archived records, then scrub active ones
class NotificationSanitizer < Pumice::Sanitizer
  scrub(:message) { match_length(raw_message) }
  scrub(:recipient_email) { fake_email(record) }

  keep :notification_type, :read_at

  prune { where(status: 'archived') }
end
```

#### `prune_older_than(age, column:)` / `prune_newer_than(age, column:)`

Convenience shorthands for common time-based pruning. Accepts a duration (`1.year`, `90.days`), a `DateTime`/`Time`/`Date` object, or a date string (`"2024-01-01"`).

```ruby
# Duration — delete records older than 1 year
prune_older_than 1.year

# Date string
prune_older_than "2024-01-01"

# DateTime object
prune_older_than DateTime.new(2024, 6, 15)

# Custom column (default: :created_at)
prune_older_than 90.days, column: :updated_at

# Newer than — delete recent records, keep historical
prune_newer_than 30.days
```

**Execution flow:**

```
scrub_all!
├─ prune: DELETE matching records (fast SQL delete)
├─ scrub: Process remaining records one-by-one
└─ verify: Run verification checks
```

### Bulk Operations (Terminal)

For high-volume tables where you want to delete records and **nothing else**. No `scrub`/`keep` declarations are needed. No scrubbing runs after a bulk operation.

#### `truncate!`

Fastest option. Wipes the entire table and resets auto-increment counters. No conditions allowed.

```ruby
class SessionSanitizer < Pumice::Sanitizer
  sanitizes :session
  truncate!
end
```

#### `delete_all(&scope)`

Fast bulk delete using SQL DELETE. No callbacks or association handling. Optionally pass a block to scope the deletion.

```ruby
# Delete all records
class OldLogSanitizer < Pumice::Sanitizer
  sanitizes :log_entry
  delete_all
end

# Delete with conditions (block executes in model scope)
class VersionSanitizer < Pumice::Sanitizer
  sanitizes :version, class_name: 'PaperTrail::Version'

  SENSITIVE_TYPES = %w[User Message StudentProfile].freeze

  delete_all { where(item_type: SENSITIVE_TYPES) }
end
```

#### `destroy_all(&scope)`

Loads records and calls `destroy` on each, running callbacks and handling `dependent: :destroy` associations. Slower but respects ActiveRecord lifecycle.

```ruby
# Destroy orphaned attachments (triggers dependent: :destroy on blobs)
class OrphanedAttachmentSanitizer < Pumice::Sanitizer
  sanitizes :attachment
  destroy_all { where(attachable_id: nil) }
end
```

### Which to Use When

| Goal | DSL | Scrubs Survivors? |
|------|-----|:-----------------:|
| Delete old records by age, then scrub the rest | `prune_older_than 1.year` | Yes |
| Delete recent records by age, then scrub the rest | `prune_newer_than 30.days` | Yes |
| Delete some records (custom scope), then scrub the rest | `prune { scope }` | Yes |
| Delete all records (wipe table) | `truncate!` | No |
| Delete records matching a condition | `delete_all { scope }` | No |
| Delete all records (no scope) | `delete_all` | No |
| Destroy records with callbacks | `destroy_all { scope }` | No |

**Rule of thumb:**
- Need to **scrub** remaining records? Use `prune`.
- Just want records **gone**? Use a bulk operation (`truncate!`, `delete_all`, `destroy_all`).

### Bulk Operation Comparison

| Method | Speed | Callbacks | Associations | Conditions |
|--------|-------|-----------|--------------|------------|
| `prune` | Fast (pre-step) | No | No | Yes (block) |
| `prune_older_than` | Fast (pre-step) | No | No | Age-based |
| `prune_newer_than` | Fast (pre-step) | No | No | Age-based |
| `truncate!` | Fastest | No | No | No |
| `delete_all` | Fast | No | No | Optional |
| `destroy_all` | Slow | Yes | Yes | Optional |

**Note:** Bulk operations skip strict column coverage validation since they don't use `scrub`/`keep` declarations.

### Verification

Pumice provides two verification methods to confirm sanitization completed successfully:

| Method | Scope | Use Case |
|--------|-------|----------|
| `verify` | Entire table | Check table state after all records processed |
| `verify_each` | Per record | Check each record immediately after sanitization |

Bulk operations also accept `verify: true` as inline shorthand for default verification.

All verification raises `Pumice::VerificationError` on failure and is skipped in dry run mode.

#### `verify` - Table-Level Verification

Use a block for custom verification logic. The block executes in the model's scope and should return truthy for success:

```ruby
class UserSanitizer < Pumice::Sanitizer
  scrub(:email) { fake_email }
  scrub(:phone) { fake_phone }
  keep :id, :role

  verify "No real email domains should remain" do
    where("email LIKE '%@gmail.com' OR email LIKE '%@yahoo.com'").none?
  end
end

class AuditSanitizer < Pumice::Sanitizer
  delete_all { where('created_at < ?', 90.days.ago) }

  verify { where('created_at < ?', 90.days.ago).none? }
end
```

For bulk operations, call `verify` without a block to use the default verification:

```ruby
class VersionSanitizer < Pumice::Sanitizer
  delete_all { where(item_type: SENSITIVE_TYPES) }
  verify  # Uses default: where(item_type: SENSITIVE_TYPES).none?
end
```

#### `verify_each` - Per-Record Verification

Verify each record immediately after sanitization. The block receives the sanitized record:

```ruby
class UserSanitizer < Pumice::Sanitizer
  scrub(:email) { fake_email }
  scrub(:ssn) { '***-**-****' }
  keep :id, :name

  # Runs after each record is sanitized
  verify_each "Record should not contain real PII" do |record|
    !record.email.include?('@gmail.com') &&
    !record.ssn.match?(/\d{3}-\d{2}-\d{4}/)
  end
end
```

#### `verify: true` - Inline Verification

Pass `verify: true` to bulk operations for compact syntax:

```ruby
class VersionSanitizer < Pumice::Sanitizer
  # Equivalent to: delete_all { ... } + verify
  delete_all(verify: true) { where(item_type: SENSITIVE_TYPES) }
end

class SessionSanitizer < Pumice::Sanitizer
  truncate!(verify: true)  # Verifies count.zero?
end

class AttachmentSanitizer < Pumice::Sanitizer
  destroy_all(verify: true) { where(attachable_id: nil) }
end
```

#### Default Verification

| Operation | Default Verification |
|-----------|---------------------|
| `truncate!` | `count.zero?` |
| `delete_all` (no scope) | `count.zero?` |
| `delete_all { scope }` | `scope.none?` |
| `destroy_all` (no scope) | `count.zero?` |
| `destroy_all { scope }` | `scope.none?` |

**Note:** `verify` without a block raises `ArgumentError` for non-bulk sanitizers.

#### Custom Default Verification Policy

Override the global default with any callable (lambda, proc, or class with `.call`):

```ruby
Pumice.configure do |config|
  config.default_verification = MyCustomVerificationPolicy
end

class MyCustomVerificationPolicy
  def self.call(model_class, bulk_operation)
    case bulk_operation[:type]
    when :truncate
      -> { count.zero? }
    when :delete, :destroy
      bulk_operation[:scope] || -> { count.zero? }
    end
  end
end
```

---

## Hard Scrubbing

Hard scrubbing permanently replaces PII in database records. Use for creating sanitized dev/review databases.

### Rake Tasks

```bash
# Analyze database for pruning candidates (RECOMMENDED - run first)
docker compose run --rm web bundle exec rake db:prune:analyze

# Generate scrubbed database dump (RECOMMENDED - source never modified)
# Creates temp database, scrubs it, exports dump, cleans up temp
docker compose run --rm web bundle exec rake db:scrub:generate

# With custom export path
EXPORT_PATH=tmp/my-dump.sql.gz docker compose run --rm web bundle exec rake db:scrub:generate

# List available sanitizers
docker compose run --rm web bundle exec rake db:scrub:list

# Lint sanitizers for missing column coverage
docker compose run --rm web bundle exec rake db:scrub:lint

# Dry run all sanitizers (no changes made)
docker compose run --rm web bundle exec rake db:scrub:test

# Dry run specific sanitizers
docker compose run --rm web bundle exec rake 'db:scrub:test[users,schools]'

# Validate no PII remains in current database
docker compose run --rm web bundle exec rake db:scrub:validate

# Safe scrub - copy to persistent target database (interactive)
docker compose run --rm web bundle exec rake db:scrub:safe

# Safe scrub - CI mode with explicit confirmation
docker compose run --rm web bundle exec rake 'db:scrub:safe_confirmed[target_db_name]'
```

### Dry Run / Testing

Use `db:scrub:test` to preview scrubbing without making any changes. No confirmation prompt required.

```bash
# Dry run all sanitizers
docker compose run --rm web bundle exec rake db:scrub:test

# Dry run specific sanitizers
docker compose run --rm web bundle exec rake 'db:scrub:test[users,messages]'

# With verbose output
VERBOSE=true docker compose run --rm web bundle exec rake 'db:scrub:test[users]'
```

### Destructive Operations (Use with Caution)

These commands modify the current database **in-place**. Only use on disposable dev/test databases:

```bash
# Scrub current database (DESTRUCTIVE - modifies DATABASE_URL)
docker compose run --rm web bundle exec rake db:scrub:all

# Preview changes without modifying (equivalent to db:scrub:test)
DRY_RUN=true docker compose run --rm web bundle exec rake db:scrub:all

# Scrub specific tables only (DESTRUCTIVE)
docker compose run --rm web bundle exec rake 'db:scrub:only[users,messages]'
```

### Programmatic Usage

```ruby
# Sanitize a single record (returns hash, does not persist)
UserSanitizer.sanitize(user)
# => { email: "user_123@example.test", first_name: "Jane", ... }

# Sanitize and persist
UserSanitizer.scrub!(user)

# Sanitize a single attribute
UserSanitizer.sanitize(user, :email)
# => "user_123@example.test"

# Batch sanitize all records
UserSanitizer.scrub_all!
```

---

## Safe Scrub

Safe Scrub creates a sanitized copy of your database without ever modifying the source. This is the recommended approach for production environments where you need a scrubbed database for development or testing.

### How It Works

1. **Copy**: Creates a fresh target database and copies all data from source
2. **Scrub**: Runs all sanitizers against the target (source untouched)
3. **Verify**: Validates no PII remains in the scrubbed database
4. **Export** (optional): Generates a dump file for distribution

### Safety Guarantees

- **Source database is NEVER modified** - read-only access only
- **Target cannot be `DATABASE_URL`** - prevents accidental production overwrites
- **Explicit confirmation required** - must type target database name to proceed
- **Source ≠ Target validation** - fails if URLs point to the same database
- **Write-access detection** - warns (or errors) if source credentials can write

### Credential Security (Recommended)

For maximum safety, use **separate database credentials** with appropriate permissions:

```sql
-- On SOURCE database (production) - READ ONLY
CREATE ROLE pumice_readonly WITH LOGIN PASSWORD 'readonly_secret';
GRANT CONNECT ON DATABASE myapp_production TO pumice_readonly;
GRANT USAGE ON SCHEMA public TO pumice_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pumice_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO pumice_readonly;

-- On TARGET database server - FULL ACCESS
CREATE ROLE pumice_writer WITH LOGIN PASSWORD 'writer_secret';
CREATE DATABASE myapp_scrubbed OWNER pumice_writer;
-- Or grant full access if database exists:
GRANT ALL PRIVILEGES ON DATABASE myapp_scrubbed TO pumice_writer;
```

Then use separate credentials in your URLs:

```bash
# Source: read-only user (can only SELECT)
SOURCE_DATABASE_URL=postgres://pumice_readonly:readonly_secret@prod-host/myapp_production

# Target: full access user (can CREATE, DROP, INSERT, etc.)
TARGET_DATABASE_URL=postgres://pumice_writer:writer_secret@scrub-host/myapp_scrubbed
```

**Why this matters:** Even if URLs are accidentally swapped, the read-only credential physically cannot modify your production database.

### Write-Access Detection

Safe Scrub automatically detects if your source credentials have write access and warns you:

```
SECURITY WARNING: Source database credentials have WRITE access!

For maximum safety, the source connection should be read-only.
This prevents accidental modifications to your production database.
```

To enforce read-only source (fail instead of warn):

```ruby
Pumice.configure do |config|
  config.require_readonly_source = true  # Error if source has write access
end
```

Or per-invocation:

```ruby
Pumice::SafeScrubber.new(
  source_url: ENV['SOURCE_DATABASE_URL'],
  target_url: ENV['TARGET_DATABASE_URL'],
  require_readonly_source: true
).run
```

### Configuration

```ruby
# config/initializers/sanitization.rb
Pumice.configure do |config|
  # Auto-detect source from Rails database.yml (no env vars needed locally)
  config.source_database_url = :auto unless Rails.env.production?
  # Or set explicitly for production:
  # config.source_database_url = ENV['DATABASE_URL']

  config.target_database_url = ENV['SCRUBBED_DATABASE_URL']  # Where to create copy
  config.export_path = "tmp/scrubbed_#{Date.today}.dump"     # Optional export
  config.export_format = :custom                              # :custom (pg_dump -Fc) or :plain (SQL)
end
```

#### Auto-detecting Source Database URL

When `source_database_url` is set to `:auto`, Pumice derives the URL from `ActiveRecord::Base.connection_db_config` at runtime:

- **Development/test** (component-based `database.yml`): builds `postgresql://user@host:port/database`
- **Staging/production** (URL-based `database.yml`): returns the `url:` value directly

This means `rake db:scrub:generate` works in Docker dev with zero env vars:

```bash
docker compose run --rm web bundle exec rake db:scrub:generate
```

Env vars (`SOURCE_DATABASE_URL`) still override when provided.

### Rake Tasks

#### Interactive Mode (Manual Confirmation)

```bash
# Prompts you to type the target database name to confirm
SOURCE_DATABASE_URL=postgres://prod-host/myapp \
TARGET_DATABASE_URL=postgres://localhost/myapp_scrubbed \
docker compose run --rm web bundle exec rake db:scrub:safe
```

Output:
```
========================================
Safe Database Scrub
========================================

This will:
  1. Create a fresh copy of the source database
  2. Scrub all PII from the copy
  3. Verify the scrubbed data

The source database will NOT be modified.

WARNING: This will DESTROY and RECREATE the target database!

  Target database: myapp_scrubbed
  Target host:     localhost

All existing data in 'myapp_scrubbed' will be permanently deleted.

Type the database name 'myapp_scrubbed' to confirm: _
```

#### CI/Background Mode (Explicit Confirmation)

For automated pipelines, pass the target database name as an argument:

```bash
# The argument must match the actual target database name
TARGET_DATABASE_URL=postgres://localhost/myapp_scrubbed \
docker compose run --rm web bundle exec rake 'db:scrub:safe_confirmed[myapp_scrubbed]'
```

This ensures:
- No interactive prompt blocks CI
- Explicit acknowledgment of the target database
- Fails if argument doesn't match target

#### With Export

```bash
SOURCE_DATABASE_URL=postgres://prod-host/myapp \
TARGET_DATABASE_URL=postgres://localhost/myapp_scrubbed \
EXPORT_PATH=tmp/scrubbed.dump \
docker compose run --rm web bundle exec rake db:scrub:safe
```

### Programmatic Usage

```ruby
# Interactive (prompts for confirmation)
Pumice::SafeScrubber.new(
  source_url: ENV['DATABASE_URL'],
  target_url: ENV['SCRUBBED_DATABASE_URL'],
  export_path: 'tmp/scrubbed.dump'
).run

# Auto-confirmed (for scripts/CI)
Pumice::SafeScrubber.new(
  source_url: ENV['DATABASE_URL'],
  target_url: ENV['SCRUBBED_DATABASE_URL'],
  confirm: true  # Skip interactive prompt
).run

# Require confirmation but fail if not provided
Pumice::SafeScrubber.new(
  source_url: ENV['DATABASE_URL'],
  target_url: ENV['SCRUBBED_DATABASE_URL'],
  confirm: false  # Raises ConfigurationError
).run
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `SOURCE_DATABASE_URL` | Database to copy from (falls back to config, then `DATABASE_URL`) |
| `TARGET_DATABASE_URL` | Database to create scrubbed copy in |
| `SCRUBBED_DATABASE_URL` | Alternative to `TARGET_DATABASE_URL` |
| `EXPORT_PATH` | Path to write the scrubbed dump file |

**Resolution order for source URL:** `SOURCE_DATABASE_URL` → `config.source_database_url` (`:auto` or string) → `DATABASE_URL`

### Error Handling

Safe Scrub raises `Pumice::ConfigurationError` for:

- Missing source or target URL
- Source and target pointing to the same database
- Target matching the primary `DATABASE_URL`
- Confirmation mismatch (typed name doesn't match target)

Safe Scrub raises `Pumice::SourceWriteAccessError` when:

- `require_readonly_source = true` and source credentials have write access

```ruby
begin
  Pumice::SafeScrubber.new(
    source_url: ENV['DATABASE_URL'],
    target_url: ENV['DATABASE_URL']  # Same as source!
  ).run
rescue Pumice::ConfigurationError => e
  puts e.message
  # => "SAFETY ERROR: source and target cannot be the same database!"
end
```

### Heroku Example

```bash
# Create a follower database for scrubbing
heroku addons:create heroku-postgresql:standard-0 \
  --fork DATABASE_URL \
  --app myapp

# Wait for fork to complete
heroku pg:wait --app myapp

# Get the new database URL
heroku config:get HEROKU_POSTGRESQL_COPPER_URL --app myapp

# Run safe scrub (replace COPPER with your addon color)
heroku run \
  "SOURCE_DATABASE_URL=\$DATABASE_URL \
   TARGET_DATABASE_URL=\$HEROKU_POSTGRESQL_COPPER_URL \
   bundle exec rake 'db:scrub:safe_confirmed[myapp_scrubbed]'" \
  --app myapp
```

---

## Pruning

Pruning removes old records from tables before sanitization to reduce dataset size. This is useful for large tables like logs, events, or audit trails where historical data isn't needed in development environments.

### How It Works

Pruning runs in two places:

1. **Global pruning** runs first (before sanitizers) when configured via `config.pruning`
2. **Per-sanitizer pruning** runs within each sanitizer's `scrub_all!` via the `prune` DSL

In the Safe Scrub workflow:

```
SafeScrubber.run
├─ Create fresh target database
├─ Copy data from source → target
├─ Global pruning ← (removes records older/newer than threshold)
├─ Run sanitizers (each may have its own prune step)
├─ Verify scrubbed data
└─ Export
```

### Analyzing Pruning Candidates

Before configuring pruning, use the analyzer to identify which tables are good candidates:

```bash
# Analyze with default settings (90 days, 10 MB min size, 1000 min rows)
docker compose run --rm web bundle exec rake db:prune:analyze

# Customize analysis parameters
RETENTION_DAYS=30 MIN_SIZE=50000000 MIN_ROWS=5000 \
  docker compose run --rm web bundle exec rake db:prune:analyze
```

The analyzer categorizes tables by confidence level:

**High Confidence** - Log tables with >50% old records and no foreign key dependencies
**Medium Confidence** - Log tables OR >70% old records, but no dependencies
**Low Confidence** - Everything else (review carefully before pruning)

Example output:

```
========================================
Database Pruning Analysis
========================================

Analyzing tables with retention: 90 days
Minimum table size: 10.00 MB
Minimum row count: 1000

High Confidence Candidates (3)
Log tables with >50% old records and no dependencies

  student_portal_sessions            8.95 GB
    1,234,567 rows, 87.3% older than 90 days
    Potential savings: 7.81 GB

  ifl_voice_logs                     3.92 GB
    892,345 rows, 92.1% older than 90 days
    Potential savings: 3.61 GB

----------------------------------------

Recommended Configuration:

Add to config/initializers/sanitization.rb:

  config.pruning = {
    older_than: 90.days,
    column: :created_at,
    only: %w[
      student_portal_sessions
      ifl_voice_logs
      email_logs
    ]
  }

Estimated space savings: 15.23 GB
```

### Configuration

```ruby
Pumice.configure do |config|
  config.pruning = {
    older_than: 90.days,          # Delete records older than this (mutually exclusive with newer_than)
    # newer_than: 30.days,        # Or delete records newer than this
    column: :created_at,          # Timestamp column to check (default)
    on_conflict: :warn,           # :warn, :raise, or :rollback (see Conflict Detection)
    only: %w[logs events],        # Prune ONLY these tables

    analyzer: {
      table_patterns: %w[portal_session conference_session],  # Domain-specific log patterns
      min_table_size: 10_000_000,   # 10 MB - skip smaller tables (default)
      min_row_count: 1000           # Skip tables with fewer rows (default)
    }
  }
end
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `older_than` | Delete records older than this duration | - |
| `newer_than` | Delete records newer than this duration | - |
| `column` | Timestamp column to check | `:created_at` |
| `on_conflict` | Behavior when global pruning overlaps a sanitizer's `prune` | `:warn` |
| `only` | Whitelist: prune ONLY these tables | `[]` |
| `except` | Blacklist: never prune these tables | `[]` |
| `analyzer.table_patterns` | Domain-specific patterns for identifying log tables | `[]` |
| `analyzer.min_table_size` | Minimum table size in bytes for analysis | `10_000_000` |
| `analyzer.min_row_count` | Minimum row count for analysis | `1000` |

**Note:** `older_than` and `newer_than` are mutually exclusive — specifying both raises `ArgumentError`. One must be provided. `only` and `except` are also mutually exclusive.

### Analyzer Table Pattern Matching

The analyzer uses pattern matching to identify log/activity tables. It includes universal patterns (log, event, activity, session, history, audit, track, analytic) and can be extended with domain-specific patterns:

```ruby
config.pruning = {
  older_than: 90.days,
  analyzer: {
    # Add patterns specific to your application
    table_patterns: %w[portal_session game_session conference_session voice_log]
  }
}
```

Tables matching these patterns are more likely to be categorized as "High Confidence" candidates for pruning.

### Examples

**Prune specific tables only:**

```ruby
config.pruning = {
  older_than: 90.days,
  only: %w[ifl_voice_logs ifl_voice_events audit_logs]
}
```

**Prune all tables except critical ones:**

```ruby
config.pruning = {
  older_than: 90.days,
  except: %w[users messages tutor_sessions schools]
}
```

**Custom timestamp column:**

```ruby
config.pruning = {
  older_than: 30.days,
  column: :recorded_at
}
```

### Conflict Detection

When a table appears in both the global `only` list and a sanitizer's `prune` DSL, the `on_conflict` option controls behavior:

| Value | Behavior |
|-------|----------|
| `:warn` | Logs a warning and continues (default) |
| `:raise` | Raises `Pumice::PruningConflictError` |
| `:rollback` | Raises `ActiveRecord::Rollback` |

The global pruner runs first, then the sanitizer's prune runs on survivors. This is usually fine — the warning is informational.

### Disabling Pruning

Disable pruning without changing config using the `PRUNE` environment variable:

```bash
PRUNE=false docker compose run --rm web bundle exec rake db:scrub:generate
```

Or set `config.pruning = false` (the default).

### Dry Run

Use `DRY_RUN=true` to see what would be pruned without deleting:

```bash
DRY_RUN=true docker compose run --rm web bundle exec rake db:scrub:generate

# Output:
# >> Pruning old records...
#    ifl_voice_logs: would prune 50000 records
#    audit_logs: would prune 12000 records
```

### Edge Cases

| Case | Handling |
|------|----------|
| Table has no timestamp column | Skipped silently |
| Table has no corresponding model | Skipped silently |
| Custom timestamp column | Set `column: :your_column` |

### Custom Conditions

For complex pruning conditions beyond simple date filtering, use the existing `delete_all` DSL in sanitizers:

```ruby
class AuditLogSanitizer < Pumice::Sanitizer
  sanitizes :audit_log

  # Complex condition: delete debug logs OR old records
  delete_all { where(level: 'debug').or(where('created_at < ?', 30.days.ago)) }
end
```

---

## Soft Scrubbing

Soft scrubbing masks data at read time without modifying the database. Use for runtime access control in production.

### Configuration

```ruby
Pumice.configure do |config|
  # Default: false (disabled). Set to hash to enable.
  config.soft_scrubbing = {
    # Viewer context: user object, Proc, or Symbol
    context: :current_user,
    # Scrub if viewer is nil or not admin
    if: ->(record, viewer) { viewer.nil? || !viewer.admin? }
  }
end
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `context` | Viewer context - Symbol, Proc, or user object | `nil` |
| `if:` | Scrub when lambda returns **true** | - |
| `unless:` | Scrub when lambda returns **false** | - |

**Note:** `if:` and `unless:` are mutually exclusive. If neither is specified, all data is scrubbed. This mirrors the familiar Rails callback pattern.

### Setting Viewer Context

The viewer context can be configured globally or set dynamically:

```ruby
# Global context via config (Symbol resolves via record, Pumice, Current, or thread local)
config.soft_scrubbing = { context: :current_user }

# Or set dynamically in ApplicationController
before_action :set_scrub_context

def set_scrub_context
  Pumice.soft_scrubbing_context = current_user
end

# Or use a block for scoped context
Pumice.with_soft_scrubbing_context(current_user) do
  # All reads within this block use current_user as viewer
  @users = User.all
end
```

### Condition Configuration

Use `if:` or `unless:` to control when scrubbing applies:

```ruby
# Using if: (scrub when true)
config.soft_scrubbing = {
  if: ->(record, viewer) { viewer.nil? || !viewer.admin? }  # Scrub non-admins
}

# Using unless: (scrub when false)
config.soft_scrubbing = {
  unless: ->(record, viewer) { viewer&.admin? }  # Show real data to admins
}
```

Both options receive `(record, viewer)` arguments. Choose whichever reads more naturally for your use case.

### How It Works

When soft scrubbing is enabled:

1. `ActiveRecord::Base` is prepended with an attribute interceptor
2. On attribute read, the policy is checked
3. If policy returns `true`, the `scrub` block is called
4. The scrubbed value is returned (original DB value unchanged)

```ruby
user = User.find(123)

# Without context (or non-admin viewer)
user.email  # => "user_123@example.test" (scrubbed)

# With admin context
Pumice.with_soft_scrubbing_context(admin_user) do
  user.email  # => "john.doe@gmail.com" (real value)
end
```

### Accessing Raw Attributes

When a sanitizer declares `scrub(:email)`, Pumice automatically generates a `raw_email` method on the model. This lets policy checks access the real value without triggering soft scrubbing:

```ruby
# app/sanitizers/user_sanitizer.rb
class UserSanitizer < Pumice::Sanitizer
  scrub(:email) { fake_email(record) }  # Automatically creates User#raw_email
  scrub(:first_name) { Faker::Name.first_name }
  scrub(:last_name) { Faker::Name.last_name }
end
```

```ruby
# app/models/user.rb
class User < ApplicationRecord
  ADMIN_EMAILS = %w[admin@example.com super@example.com].freeze

  def admin?
    # raw_email bypasses soft scrubbing - auto-generated from scrub(:email)
    ADMIN_EMAILS.include?(raw_email)
  end
end
```

**Generated methods:**

| Sanitizer Declaration | Generated Method |
|-----------------------|------------------|
| `scrub(:email)` | `raw_email` |
| `scrub(:first_name)` | `raw_first_name` |
| `scrub(:ssn)` | `raw_ssn` |

**Why is this needed?** When checking `viewer.admin?` in the policy, if `admin?` reads `self.email`, it triggers soft scrubbing, which checks the policy, which calls `admin?`... creating a circular dependency. Using `raw_email` reads directly from the database attributes, bypassing the interceptor.

```ruby
# In config/initializers/sanitization.rb
config.soft_scrubbing = {
  # This policy calls viewer.admin?, which uses raw_email internally
  unless: ->(_record, viewer) { viewer&.admin? }
}
```

A generic `raw_attribute(:name)` method is also available for ad-hoc access to any attribute.

---

## Testing

### Testing Sanitizers

```ruby
# spec/sanitizers/user_sanitizer_spec.rb
require 'rails_helper'

RSpec.describe UserSanitizer do
  let(:user) { create(:user, email: 'real@gmail.com', first_name: 'John') }

  describe '.sanitize' do
    it 'returns sanitized values without persisting' do
      result = described_class.sanitize(user)

      expect(result[:email]).to match(/user_\d+@example\.test/)
      expect(result[:first_name]).not_to eq('John')
      expect(user.reload.email).to eq('real@gmail.com')  # Unchanged
    end
  end

  describe '.scrub!' do
    it 'persists sanitized values' do
      described_class.scrub!(user)

      expect(user.reload.email).to match(/user_\d+@example\.test/)
    end
  end

  describe 'column coverage' do
    it 'defines all columns' do
      issues = described_class.lint!
      expect(issues).to be_empty, -> { issues.join("\n") }
    end
  end
end
```

### Testing Soft Scrubbing

```ruby
# spec/models/user_soft_scrubbing_spec.rb
require 'rails_helper'

RSpec.describe 'User soft scrubbing' do
  let(:user) { create(:user, email: 'real@gmail.com') }
  let(:admin) { create(:user, :admin) }
  let(:regular_user) { create(:user) }

  before do
    Pumice.configure do |c|
      c.soft_scrubbing = {
        if: ->(record, viewer) { viewer.nil? || !viewer.admin? }
      }
    end
  end

  after { Pumice.reset! }

  it 'scrubs data for non-admin viewers' do
    Pumice.with_soft_scrubbing_context(regular_user) do
      expect(user.email).to match(/user_\d+@example\.test/)
    end
  end

  it 'shows real data to admins' do
    Pumice.with_soft_scrubbing_context(admin) do
      expect(user.email).to eq('real@gmail.com')
    end
  end
end
```

### Test Helpers

```ruby
# spec/support/pumice_helpers.rb
module PumiceHelpers
  def with_soft_scrubbing(viewer: nil, scrub_unless: nil, scrub_if: nil, &block)
    original_config = Pumice.config.instance_variable_get(:@soft_scrubbing)
    config_hash = {}
    config_hash[:unless] = scrub_unless if scrub_unless
    config_hash[:if] = scrub_if if scrub_if
    Pumice.configure { |c| c.soft_scrubbing = config_hash }
    Pumice.with_soft_scrubbing_context(viewer, &block)
  ensure
    Pumice.config.instance_variable_set(:@soft_scrubbing, original_config)
    Pumice.reset!
  end

  def without_soft_scrubbing(&block)
    original_config = Pumice.config.instance_variable_get(:@soft_scrubbing)
    Pumice.configure { |c| c.soft_scrubbing = false }
    yield
  ensure
    Pumice.config.instance_variable_set(:@soft_scrubbing, original_config)
  end
end

RSpec.configure do |config|
  config.include PumiceHelpers
end
```

---

## Helpers Reference

Built-in helpers are available in all `scrub` blocks via the `Pumice::Helpers` module. These helpers generate realistic fake data while maintaining data integrity constraints.

### Quick Reference

| Helper | Description | Example Output |
|--------|-------------|----------------|
| `fake_email(record)` | Deterministic email from record | `user_123@example.test` |
| `fake_phone(digits)` | Random phone number | `5551234567` |
| `fake_password(pwd, cost:)` | BCrypt hash | `$2a$04$...` |
| `fake_id(id, prefix:)` | Formatted ID string | `ID000123` |
| `fake_json(value, preserve_keys:, keep:)` | Sanitize JSON structure | `{"name": "lorem"}` |
| `match_length(value, use:)` | Text matching original length | `Lorem ipsum dolor...` |

### `fake_email(record_or_prefix, prefix:, domain:, unique_id:)`

Generates a deterministic, unique email address. Ensures the same record always produces the same fake email (important for data consistency across scrub runs).

```ruby
# Pass the record directly (recommended)
scrub(:email) { fake_email(record) }
# => "user_123@example.test"

# Custom domain
scrub(:email) { fake_email(record, domain: 'test.example.com') }
# => "user_123@test.example.com"

# Custom prefix instead of model name
scrub(:email) { fake_email(prefix: 'contact', unique_id: record.id) }
# => "contact123@example.test"

# For non-record contexts
scrub(:contact_email) { fake_email(prefix: 'contact', unique_id: record.id) }
```

**Why deterministic?** If you scrub the same database twice, emails remain consistent. This preserves foreign key relationships and makes debugging easier.

### `fake_phone(digits = 10)`

Generates a random phone number with the specified number of digits.

```ruby
# Default 10 digits
scrub(:phone) { fake_phone }
# => "5551234567"

# Shorter format (last 7 digits)
scrub(:extension) { fake_phone(7) }
# => "1234567"

# For formatted fields, you may need to add formatting
scrub(:formatted_phone) { |_| "(555) #{fake_phone(3)}-#{fake_phone(4)}" }
# => "(555) 123-4567"
```

### `fake_password(password = 'password123', cost: 4)`

Generates a BCrypt password hash. Uses low cost factor (4) for speed during bulk scrubbing.

```ruby
# Default password
scrub(:encrypted_password) { fake_password }
# => "$2a$04$..." (hash of 'password123')

# Custom password (all scrubbed users get same password for easy testing)
scrub(:encrypted_password) { fake_password('testpass') }

# Higher cost for production-like hashes (slower)
scrub(:encrypted_password) { fake_password('secure', cost: 12) }
```

**Tip:** Use a known password like `'password123'` so developers can log in as any scrubbed user during testing.

### `fake_id(id, prefix: 'ID')`

Generates a formatted ID string with zero-padding.

```ruby
scrub(:external_id) { fake_id(record.id) }
# => "ID000123"

scrub(:student_number) { fake_id(record.id, prefix: 'STU') }
# => "STU000123"

scrub(:order_reference) { fake_id(record.id, prefix: 'ORD-') }
# => "ORD-000123"
```

### `fake_json(value, preserve_keys: true, keep: [])`

Sanitizes JSON data structures. Handles Hash, Array, or JSON strings.

```ruby
# Preserve structure but replace values (default)
scrub(:preferences) { |value| fake_json(value) }
# Input:  {"name": "John", "settings": {"theme": "dark"}}
# Output: {"name": "lorem", "settings": {"theme": "ipsum"}}

# Clear JSON entirely
scrub(:metadata) { |value| fake_json(value, preserve_keys: false) }
# => {}
```

**Value transformations with `preserve_keys: true`:**
- Strings → Random word
- Numbers → `0`
- Booleans → Unchanged
- `nil` → `nil`
- Nested objects → Recursively processed

```ruby
# Complex nested JSON
scrub(:profile_data) do |value|
  fake_json(value)
end
# Input:  {"user": {"name": "John", "age": 30, "active": true}}
# Output: {"user": {"name": "dolor", "age": 0, "active": true}}
```

#### Keeping Specific Keys

Use the `keep` option to preserve specific values while scrubbing the rest. Supports dot notation and array notation for deeply nested paths.

```ruby
# Keep specific top-level keys
scrub(:config) { |value| fake_json(value, keep: ['api_version', 'format']) }
# Input:  {"api_version": "v2", "format": "json", "secret": "abc123"}
# Output: {"api_version": "v2", "format": "json", "secret": "lorem"}

# Keep deeply nested keys with dot notation
scrub(:metadata) { |value| fake_json(value, keep: ['user.profile.email']) }
# Input:  {"user": {"profile": {"email": "john@example.com", "name": "John"}}}
# Output: {"user": {"profile": {"email": "john@example.com", "name": "lorem"}}}

# Keep multiple paths, mixing dot and array notation
scrub(:data) do |value|
  fake_json(value, keep: ['user.email', ['metadata', 'id']])
end

# Keep values inside arrays using index notation
scrub(:records) { |value| fake_json(value, keep: ['users.0.name']) }
```

### `match_length(value, use: :sentence)`

Generates text that approximately matches the original value's length. Useful for maintaining column constraints and realistic data appearance.

```ruby
# Default: sentence-style text
scrub(:bio) { |value| match_length(value) }
# 50-char input => ~50 chars of "Lorem ipsum dolor sit amet..."

# Paragraph style (for longer text)
scrub(:description) { |value| match_length(value, use: :paragraph) }

# Single word
scrub(:nickname) { |value| match_length(value, use: :word) }

# Random characters (for codes/tokens)
scrub(:access_code) { |value| match_length(value, use: :characters) }
# => "xKj9mNpQ2r"

# Custom generator
scrub(:custom_field) do |value|
  match_length(value, use: -> { Faker::Company.buzzword })
end
```

**Available generators:**
| Symbol | Output Style | Best For |
|--------|--------------|----------|
| `:sentence` | Lorem ipsum sentences | Bios, descriptions, comments |
| `:paragraph` | Multi-sentence paragraphs | Long-form content |
| `:word` | Single word | Names, short fields |
| `:characters` | Random alphanumeric | Codes, tokens, IDs |

### Accessing Record Context

All helpers have access to `record` - the ActiveRecord instance being sanitized:

```ruby
scrub(:display_name) do |value|
  # Combine helpers with record data
  "#{Faker::Name.first_name} (#{fake_id(record.id, prefix: '')})"
end

scrub(:slug) do |value|
  # Use record associations
  "#{record.organization&.slug}-#{fake_id(record.id, prefix: '')}"
end
```

### Combining Helpers

```ruby
scrub(:contact_info) do |value|
  {
    email: fake_email(record),
    phone: fake_phone,
    address: Faker::Address.full_address
  }.to_json
end

scrub(:notes) do |value|
  next nil if value.blank?
  match_length(value, use: :paragraph)
end
```

### Creating Custom Helpers

Extend the helpers module for project-specific needs:

```ruby
# config/initializers/pumice_helpers.rb
module Pumice
  module Helpers
    def fake_student_id(record)
      "STU-#{record.school_id}-#{sprintf('%04d', record.id)}"
    end

    def fake_grade_level
      %w[K 1 2 3 4 5].sample
    end

    def redact(value, show_last: 4)
      return nil if value.blank?
      "#{'*' * (value.length - show_last)}#{value.last(show_last)}"
    end
  end
end
```

Then use in sanitizers:

```ruby
class StudentSanitizer < Pumice::Sanitizer
  scrub(:student_id) { fake_student_id(record) }
  scrub(:grade) { fake_grade_level }
  scrub(:ssn) { |value| redact(value, show_last: 4) }
end
```

---

## Roadmap

### Phase 1: Dynamic Attribute-Level Policies (Current Focus)

Replace the global on/off policy with per-attribute, role-aware scrubbing:

```ruby
# Future API concept
scrub :email do |value, viewer:|
  return value if viewer&.admin?
  fake_email(record)
end

scrub :ssn do |value, viewer:|
  return value if viewer&.finance?
  return "***-**-#{value[-4..]}" if viewer&.hr?
  "***-**-****"
end

scrub :credit_card do |value, viewer:|
  case viewer&.role
  when :finance then value
  when :support then mask_card(value, show_last: 4)
  else mask_card(value, show_last: 0)
  end
end
```

### Phase 2: Secure Storage Integration

Pipe scrubbed database dumps directly to secure storage:

```ruby
Pumice::DumpGenerator.new(
  output: :s3,
  bucket: 'scrubbed-databases',
  encryption: :aws_kms,
  key_id: ENV['KMS_KEY_ID']
).generate

# Or stream to multiple destinations
Pumice::DumpGenerator.new(
  outputs: [
    { type: :s3, bucket: 'primary-backups' },
    { type: :gcs, bucket: 'secondary-backups' }
  ]
).generate
```

### Phase 3: Frontend JavaScript Support

Extend scrubbing to frontend views with inline hide/show and role-based exposure:

```erb
<%# Server renders data attributes, JS handles display %>
<%= scrubbed_field @user, :email,
    scrub_class: 'blur-sm',
    reveal_roles: [:admin, :owner] %>

<%# Generates: %>
<span
  data-scrubbed="true"
  data-field="email"
  data-reveal-roles="admin,owner"
  class="blur-sm"
>
  user_123@example.test
</span>
```

```javascript
// Frontend JS module
import { Pumice } from 'pumice';

Pumice.configure({
  currentUserRole: window.currentUser.role,
  revealOnClick: true,
  revealDuration: 5000,  // Auto-hide after 5 seconds
  auditCallback: (field, action) => {
    analytics.track('pii_reveal', { field, action });
  }
});

// Programmatic reveal/hide
Pumice.reveal('[data-field="email"]');
Pumice.hide('[data-field="email"]');

// Bulk operations
Pumice.revealAll();
Pumice.hideAll();
```

### Phase 4: Audit Logging

Track who viewed what sensitive data and when:

```ruby
Pumice.configure do |config|
  config.audit_log = true
  config.audit_backend = :database  # or :cloudwatch, :datadog
  config.audit_events = [:reveal, :export, :bulk_access]
end

# Query audit logs
Pumice::AuditLog.where(viewer: user, field: :ssn).last_30_days
```

### Phase 5: Data Classification DSL

Define data classification tiers with inherited policies:

```ruby
Pumice.define_classification :pii do
  scrub_for_roles except: [:admin]
end

Pumice.define_classification :financial do
  scrub_for_roles except: [:admin, :finance]
  audit_access true
end

Pumice.define_classification :health do
  scrub_for_roles except: [:admin, :medical]
  audit_access true
  require_mfa_to_reveal true
end

class UserSanitizer < Pumice::Sanitizer
  scrub :email, classification: :pii
  scrub :ssn, classification: :pii
  scrub :salary, classification: :financial
  scrub :diagnosis, classification: :health
end
```
