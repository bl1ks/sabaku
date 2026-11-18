# Rails

ruby-mutation drives minitest or rspec; it has no Rails adapter and no Rails dependency. What a
Rails app needs is a boot sequence and a database that survives a fork, and both are the project's
job. The `--setup` file is where a project states them.

`fixture/rails_app` is a working example. `test/e2e/rails_test.rb` runs a campaign against it in
the `ruby-mutation:rails` image.

## The setup file

```ruby
# mutation.rb
env "RAILS_ENV" => "test"
require_path "./config/environment"

after_boot do
  Rails.application.eager_load!
end

before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

child_start do |index|
  # optional, see the database recipes below
end
```

Run it with:

```sh
bundle exec mutation run app --setup=mutation.rb --jobs=4 --timeout=5
```

The CLI applies the hooks at fixed points:

| Hook | Process | When |
| --- | --- | --- |
| `env` | parent | before anything loads, so `RAILS_ENV=test` is set for the boot |
| `require_path` | parent | after `Coverage.start`, before the test files load, so `app/` is instrumented from its first parse |
| `after_boot` | parent | after the test framework and the application have loaded |
| `before_fork` | parent | once, after the coverage pass, before the first child exists |
| `child_start` | each child | before the mutated file is evaluated |
| `before_test_run` | each child | after the mutation is applied, before the tests run |

A hook that raises stops the campaign with exit 2. A red suite stops it too, unless you pass
`--no-baseline`: a test that fails with no mutation applied would kill every mutant it covers and
produce a fake score. The coverage pass already runs every test once and reports what failed; with
`--no-coverage` a forked or spawned child runs the whole suite with no mutation applied before the
campaign starts.

Two neutral children use the same hooks as a mutant: the baseline above, and the kill check that
re-runs one failing test with the file loaded a second time and no mutation. Their `child_start`
index is the mutant's index, or `-1` for the baseline, so a hook that clones a database per index
gives the baseline its own copy.

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
  name = "mutation_#{Process.pid}"
  ActiveRecord::Base.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash
    .merge(database: "postgres"))
  ActiveRecord::Base.connection.execute("CREATE DATABASE #{name} TEMPLATE #{template_name}")
  ActiveRecord::Base.establish_connection(
    ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: name)
  )
end
```

Drop the databases from a `before_test_run`-time `at_exit` or a cleanup script; the runner kills
children on timeout, so a child that never returns still leaks its database.

## What can be targeted

Models, service objects, jobs, mailers, helpers, and controllers reached through integration tests
all work: they are Ruby files loaded by the app.

Leave out of scope for now: ERB templates, system tests (a browser process per mutant), ActionCable,
initializers, routes, and `config/`. Constants redefined at boot, `define_method` bodies, and
`Struct`/`Data` field lists are not mutable in place; the analyzer skips what the operators do not
recognize rather than guessing.

## rspec-rails

The rspec adapter runs examples directly, so `before(:suite)` and `before(:context)` do not run.
Transactional fixtures are an `around` hook and do run. If your suite depends on suite-level state,
add it to `after_boot` instead of a `before(:suite)` block.

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
