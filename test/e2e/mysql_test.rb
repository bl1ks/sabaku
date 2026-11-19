# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require "timeout"

# End to end against a real MySQL server: the fixture app boots on mysql2, the
# campaign clones the test database per child, and the parent's cleanup drops
# every clone without touching the main test database.
#
# The server and mysql2 are not in the default image, so this test skips unless
# both are reachable. `bin/check-rails` starts a throwaway mysql:8.4 container.
class MysqlCampaignTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  APP = File.join(ROOT, "fixture", "rails_app")
  BIN = File.join(ROOT, "bin", "mutation")

  DATABASE = "ruby_mutation_e2e_#{Process.pid}"
  PREFIX = "mutation_e2e_#{Process.pid}"

  def setup
    skip "mysql2 and a reachable MySQL server are required" unless mysql_available?
  end

  def test_campaign_clones_the_database_per_child_and_drops_the_clones
    Dir.mktmpdir("ruby-mutation-mysql") do |dir|
      app = File.join(dir, "app")
      FileUtils.cp_r(APP, app)
      log = File.join(app, "tmp", "mutation_mysql.log")
      env = mysql_env.merge("RAILS_ENV" => "test", "MUTATION_DB" => "mysql",
                            "MUTATION_DB_PREFIX" => PREFIX, "MUTATION_DB_LOG" => log,
                            "MYSQL_DATABASE" => DATABASE)
      begin
        _out, err, status = run!(app, RbConfig.ruby, "bin/rails", "db:create", "db:schema:load",
                                 env: env)
        assert_equal 0, status.exitstatus, "db:create db:schema:load failed: #{err}"

        out, err, status = run!(app, RbConfig.ruby, BIN, "run", "app/models",
                                "--setup=mutation_mysql.rb", "--jobs=2", "--timeout=5",
                                "--report=json", env: env)
        payload = JSON.parse(out.lines.last)

        assert_equal 0, status.exitstatus, err
        assert_operator payload["mutants"], :>, 5
        assert_operator payload["killed"], :>, 0, "no mutant was killed on MySQL"
        assert_equal 0, payload["error"], payload["results"].select { |r| r["status"] == "error" }.first(3).inspect
        assert_operator payload["score"], :>, 0.5

        ticket_kills = payload["results"].count do |result|
          result["status"] == "killed" && result["mutant"]["path"] == "app/models/ticket.rb"
        end
        assert_operator ticket_kills, :>, 0, "the truncating MySQL test should kill a Ticket mutation"

        assert_path_exists log, "the MySQL test helper did not record a database"
        clones = File.readlines(log, chomp: true)
                     .select { |name| name.start_with?("#{PREFIX}_") }.uniq
        assert_operator clones.size, :>=, 2,
                        "children did not clone the database: #{clones.inspect}"
        clones.each { |name| assert_match(/\A#{Regexp.escape(PREFIX)}_\d+\z/, name) }

        assert_empty databases.grep(/\A#{Regexp.escape(PREFIX)}_/), "the campaign left clones behind"
        assert_includes databases, DATABASE, "cleanup dropped the main test database too"
      ensure
        drop_databases
      end
    end
  end

  private

  def mysql_env
    {
      "MYSQL_HOST" => ENV.fetch("MYSQL_HOST", "127.0.0.1"),
      "MYSQL_PORT" => ENV.fetch("MYSQL_PORT", "3306"),
      "MYSQL_USER" => ENV.fetch("MYSQL_USER", "root"),
      "MYSQL_PASSWORD" => ENV.fetch("MYSQL_PASSWORD", "")
    }
  end

  def mysql_available?
    require "mysql2"
    databases
    true
  rescue LoadError, StandardError
    false
  end

  def client
    @client ||= Mysql2::Client.new(host: mysql_env["MYSQL_HOST"],
                                   port: Integer(mysql_env["MYSQL_PORT"]),
                                   username: mysql_env["MYSQL_USER"],
                                   password: mysql_env["MYSQL_PASSWORD"])
  end

  def databases
    client.query("SELECT SCHEMA_NAME AS name FROM information_schema.SCHEMATA")
          .map { |row| row.fetch("name") }
  end

  # Clones survive a crashed campaign, and a fresh prefix per run would let them
  # accumulate, so the test drops its own namespace too.
  def drop_databases
    names = databases.select { |name| name == DATABASE || name.start_with?("#{PREFIX}_") }
    names.each { |name| client.query("DROP DATABASE IF EXISTS `#{name}`") }
  rescue StandardError => e
    warn "mysql e2e cleanup failed: #{e.class}: #{e.message}"
  ensure
    @client&.close
    @client = nil
  end

  def run!(dir, *command, env: {})
    out, err, status = nil
    Timeout.timeout(180) do
      out, err, status = Open3.capture3(env, *command, chdir: dir)
    end
    [out, err, status]
  end
end
