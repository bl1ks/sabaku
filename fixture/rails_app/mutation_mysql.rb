# frozen_string_literal: true

# Per-child MySQL database copy for a Rails app that truncates instead of
# using transactional fixtures: `mutation run app/models --setup=mutation_mysql.rb`.
# MySQL has no `CREATE DATABASE ... TEMPLATE`, so each child creates an empty
# database and loads the schema into it. docs/rails.md quotes this file.
env "RAILS_ENV" => "test"
require_path "./config/environment"

after_boot do
  Rails.application.eager_load!
end

before_fork do
  # The coverage pass ran the whole suite in this process, so the pool holds a
  # live MySQL connection. A forked child must open its own.
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

# Evaluated once in the parent, before any child. Both children and the CLI
# end with `exit!`, so an at_exit never runs; after_campaign is the one hook
# that can clean up after the last child.
prefix = ENV.fetch("MUTATION_DB_PREFIX") { "mutation_#{Process.pid}" }

settings = lambda do
  ActiveRecord::Base.connection_db_config.configuration_hash.dup
end

# A connection with no database is what CREATE DATABASE, DROP DATABASE and
# information_schema need.
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
  # Not child_start: in process isolation child_start fires before the
  # application boots, so ActiveRecord is not defined yet. before_test_run
  # fires after boot in both modes.
  source = settings.call
  name = "#{prefix}_#{Process.pid}"

  connection = maintenance.call
  # A reused pid must not inherit a stale copy from an earlier campaign.
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
