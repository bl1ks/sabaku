# frozen_string_literal: true

# The boot recipe for a Rails app: `sabaku run app --setup=sabaku.rb`.
# docs/rails.md explains each hook and the database choices behind them.
env "RAILS_ENV" => "test"
require_path "./config/environment"

after_boot do
  # A mutation is applied by re-evaluating the file in a child. Every constant
  # has to exist before the fork, or Zeitwerk loads the original file inside
  # the child on first reference and the mutation is overwritten.
  Rails.application.eager_load!
end

before_fork do
  # A child must not inherit the parent's open SQLite handle or PostgreSQL
  # socket. The coverage pass ran the whole suite in this process, so the pool
  # is populated by now.
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

child_start do |index, slot|
  # Transactional fixtures isolate each test's writes, so the shared test
  # database works here. docs/rails.md shows the per-child copy recipe for
  # projects that truncate instead.
  path = Rails.root.join("tmp", "mutation_children.log")
  FileUtils.mkdir_p(path.dirname)
  File.open(path, "a") { |file| file.puts("child_start:#{index}:#{slot}") }
end
