# Rails

sabaku drives a minitest suite; it has no Rails adapter and no Rails dependency. What a
Rails app needs is a boot sequence and a database that survives a fork, and both are the project's
job. The `--setup` file is where a project states them.

`fixture/rails_app` is a working example. `test/e2e/rails_test.rb` runs a campaign against it on
SQLite, and `test/e2e/mysql_test.rb` runs the same app on MySQL. Build the image both use with
`docker build -f docker/rails.Dockerfile -t sabaku:rails .`, then run `bin/check-rails` to
execute both campaigns against a throwaway `mysql:8.4` container.

## The setup file

```ruby
# sabaku.rb
env "RAILS_ENV" => "test"
require_path "./config/environment"

after_boot do
  Rails.application.eager_load!
end

before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

child_start do |index, slot|
  # optional, see the database and Redis recipes below
end
```

Run it with:

```sh
bundle exec sabaku run app --setup=sabaku.rb --jobs=4 --timeout=5
```

The CLI applies the hooks at fixed points:

| Hook | Process | When |
| --- | --- | --- |
| `env` | parent | before anything loads, so `RAILS_ENV=test` is set for the boot |
| `require_path` | parent | after `Coverage.start`, before the test files load, so `app/` is instrumented from its first parse |
| `after_boot` | parent | after the test framework and the application have loaded |
| `before_fork` | parent | once, after the coverage pass, before the first child exists |
| `child_start` | each child | before the mutated file is evaluated, with the mutant index and the pool slot |
| `before_test_run` | each child | after the mutation is applied, before the tests run |
| `after_campaign` | parent | after the last child, before the process exits |

In process isolation `child_start` fires before the application boots, so `ActiveRecord` is not
defined yet; application-level database work belongs in `before_test_run`, which fires after boot
in both modes. A first-load child boots like the parent: `--require` paths and `require_path`, the
test files, then `after_boot`, all before the mutated file is substituted.

A hook that raises stops the campaign with exit 2, except `after_campaign`: it runs after the
verdict, so its failure is printed to stderr and the campaign keeps its exit status. A red suite
stops it too, unless you pass `--no-baseline`: a test that fails with no mutation applied would
kill every mutant it covers and produce a fake score. The coverage pass already runs every test
once and reports what failed; with `--no-coverage` a forked or spawned child runs the whole suite
with no mutation applied before the campaign starts.

Two neutral children use the same hooks as a mutant: the baseline above, and the kill check that
re-runs one failing test with the file loaded a second time and no mutation. Their `child_start`
index is the mutant's index, or `-1` for the baseline, so a hook that clones a database per index
gives the baseline its own copy.

The second argument is the slot: the child's position in the pool, an integer in `0...jobs`. No
two children that run at the same time share a slot, and a slot is reused only after its child has
exited. The index names a mutant and grows with the campaign; the slot names a worker and is the
one to use for a fixed pool of resources. Process isolation passes it to the child as
`SABAKU_CHILD_SLOT`. A block that takes only `|index|` keeps working.

## Why eager load

A mutation is applied by re-evaluating one file in the child. If the constant it defines has not
been loaded yet, the first reference inside the child triggers Zeitwerk, which loads the original
file and replaces the mutated one. `Rails.application.eager_load!` in `after_boot` prevents that.

`config.enable_reloading = false` is the test environment default in Rails 8 and is assumed here.
A reloading app can drop the mutated constant on the next request.

## Why disconnect before forking

The coverage pass runs the whole suite in the parent, so the connection pool is populated. Forking
copies the file descriptors, and two children would then share one SQLite handle or one PostgreSQL
socket. `clear_all_connections!` in `before_fork` makes each child open its own connection on first
use, which is what the `child_start` recipes below rely on.

## Database recipes

The coverage pass runs in the parent, before any child. Whatever you do in `child_start` therefore
sees the database after the whole suite has already run once.

### Transactional fixtures (default)

Rails' transactional tests wrap each test in a transaction and roll it back. Nothing to do: the
shared test database is safe because no test leaves a row behind. This is what
`fixture/rails_app` uses, and it works with `--jobs=N` for any N.

### SQLite, non-transactional

Each child gets its own copy of the test database file:

```ruby
child_start do |index|
  source = Rails.root.join("storage/test.sqlite3")
  target = Rails.root.join("storage/test-#{Process.pid}.sqlite3")
  FileUtils.cp(source, target)
  ActiveRecord::Base.establish_connection(
    ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: target.to_s)
  )
end
```

`Process.pid` rather than `index`: one child per mutant, so the index repeats across campaigns and
a stale file would hide the copy.

### PostgreSQL, non-transactional

The parent must not hold a connection to the template database. `before_fork` already disconnects;
connect the parent to the `postgres` database, then create one copy per child:

```ruby
child_start do |_index|
  name = "sabaku_#{Process.pid}"
  ActiveRecord::Base.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash
    .merge(database: "postgres"))
  ActiveRecord::Base.connection.execute("CREATE DATABASE #{name} TEMPLATE #{template_name}")
  ActiveRecord::Base.establish_connection(
    ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: name)
  )
end
```

Drop the copies from the parent's `after_campaign`, as the MySQL recipe below does. A
`before_test_run`-time `at_exit` never runs, because children end with `Kernel#exit!`.

### MySQL, non-transactional

MySQL has no `CREATE DATABASE ... TEMPLATE`, so each child creates an empty database, matches the
source database's character set and collation, and loads `db/schema.rb` into it.
`fixture/rails_app/sabaku_mysql.rb` is the same file, and `test/e2e/mysql_test.rb` runs it.

```ruby
# sabaku_mysql.rb
env "RAILS_ENV" => "test"
require_path "./config/environment"

after_boot do
  Rails.application.eager_load!
end

before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

prefix = ENV.fetch("SABAKU_DB_PREFIX") { "sabaku_#{Process.pid}" }

settings = lambda do
  ActiveRecord::Base.connection_db_config.configuration_hash.dup
end

maintenance = lambda do
  ActiveRecord::Base.establish_connection(settings.call.except(:database))
  ActiveRecord::Base.connection
end

after_campaign do
  connection = maintenance.call
  names = connection.select_values("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA")
  names.select { |name| name.start_with?("#{prefix}_") }
       .each { |name| connection.drop_database(name) }
end

before_test_run do
  source = settings.call
  name = "#{prefix}_#{Process.pid}"

  connection = maintenance.call
  connection.drop_database(name)
  charset, collation = connection.select_rows(
    "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME " \
    "FROM information_schema.SCHEMATA " \
    "WHERE SCHEMA_NAME = #{connection.quote(source.fetch(:database))}"
  ).first
  connection.create_database(name, source.merge(encoding: charset, collation: collation))

  ActiveRecord::Base.establish_connection(source.merge(database: name))
  load Rails.root.join("db/schema.rb")
end
```

`SABAKU_DB_PREFIX` is read once in the parent, so every child shares it, and the child database
adds the child's pid. A child drops its own name before use, because a reused pid must not inherit
a stale copy. The cleanup selects the names and filters with `start_with?` in Ruby rather than a
`LIKE` pattern, where `_` is a wildcard and would match the main test database too.

Transactional fixtures hide the clone: they roll back every test, so a shared database would pass
as well. The fixture's `test_helper.rb` sets `use_transactional_tests = false` and truncates in a
`setup` block when `SABAKU_DB=mysql`, and its `config/database.yml` selects the mysql2 branch for
the test environment.

### Redis, one db per worker

Children that share one Redis db see each other's keys, so a test that passes alone can fail
under `--jobs=4`, or a mutant can survive because another child wrote the key it reads. Redis has
16 numbered dbs by default. Give each slot its own and empty it before the tests run:

```ruby
child_start do |_index, slot|
  ENV["REDIS_URL"] = "redis://localhost:6379/#{slot % 16}"
end

before_test_run do
  Redis.new(url: ENV.fetch("REDIS_URL")).flushdb
end
```

`child_start` runs before the application boots in process isolation, so it only sets the URL; the
client is built after boot. Keep `--jobs` at 16 or below, or two slots share a db.

### Cleanup runs in the parent

Both isolation modes end a child with `Kernel#exit!`, and `bin/sabaku` ends the parent the same
way, so an `at_exit` registered by a `--setup` file never runs: not in a child, not after the
campaign. Teardown belongs in `after_campaign`, which the CLI fires once after the last child; a
hook that raises is reported on stderr without changing the campaign's exit status. A child killed
on a timeout cannot clean up after itself, and a campaign that dies before `after_campaign` leaves
its `<prefix>_*` databases behind. `after_campaign` drops by prefix, so a later run with the same
`SABAKU_DB_PREFIX` reclaims them, and a child that reuses a pid drops that name before copying.
With the default pid-based prefix the next run uses a new namespace, so an orphaned set needs a
manual `DROP DATABASE`.

## What can be targeted

Models, service objects, jobs, mailers, helpers, and controllers reached through integration tests
all work: they are Ruby files loaded by the app.

Leave out of scope for now: ERB templates, system tests (a browser process per mutant), ActionCable,
initializers, routes, and `config/`. Constants redefined at boot, `define_method` bodies, and
`Struct`/`Data` field lists are not mutable in place; the analyzer skips what the operators do not
recognize rather than guessing.

## Cost

Rails boot is a fixed cost per campaign: about 0.44s for a minimal app in this repository's
measurement, plus 0.17s for `eager_load!`. A campaign over a handful of mutants is dominated by
that boot, so use `--since` (or `--diff`) to keep the mutant count up when iterating.

## Known limits

- A file that calls `undef` at class level cannot be re-evaluated in a forked child: the second
  `undef` raises `NameError` before the mutation is applied. The mutant is reported as `error`.
  Run that campaign with `--isolation=process`, where the mutated file is loaded once into a fresh
  process and the original is never evaluated.
- A file that runs code at load time can be observed twice by fork isolation, because the mutated
  file is re-evaluated over the parent's copy. A test that counts what the file registered then
  fails without the mutation having caused it. For those files the runner re-runs the failing test
  with the file loaded a second time and no mutation; if it fails there too, the kill is reported
  as `error` with `unverified kill` rather than as a kill. Registration in a Rails initializer is
  the common trigger. `--isolation=process` does not have this failure mode.
- `Bundler` has to be set up before the campaign: run `bundle exec mutation ...`, or point
  `BUNDLE_PATH` at the same bundle the tests use.
