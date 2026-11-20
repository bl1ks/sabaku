# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require "timeout"

# End to end against a real Rails application: boot under coverage, eager load,
# fork a child, re-evaluate a model with a mutation, and run a transactional
# fixture test that writes to SQLite.
#
# Rails, sqlite3 and mysql2 are not in the default image, so this test skips
# unless all three are loadable. `sabaku:rails` has them (build it from
# docker/rails.Dockerfile), and bin/check-rails runs this test and the MySQL one
# against a throwaway server:
#
#   docker run --rm -v "$PWD:/app" -w /app --user "$(id -u):$(id -g)" \
#     -e HOME=/tmp sabaku:rails ruby -Ilib -Itest test/e2e/rails_test.rb
class RailsCampaignTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  APP = File.join(ROOT, "fixture", "rails_app")
  BIN = File.join(ROOT, "bin", "sabaku")

  def setup
    skip "rails, sqlite3 and mysql2 are not installed" unless rails_available?
  end

  def test_campaign_boots_rails_eager_loads_and_runs_a_database_test
    Dir.mktmpdir("sabaku-rails") do |dir|
      app = File.join(dir, "app")
      FileUtils.cp_r(APP, app)

      _out, err, status = run!(app, RbConfig.ruby, "bin/rails", "db:schema:load",
                               env: { "RAILS_ENV" => "test" })
      assert_equal 0, status.exitstatus, "db:schema:load failed: #{err}"

      out, err, status = run!(app, RbConfig.ruby, BIN, "run", "app/models",
                              "--setup=sabaku.rb", "--jobs=2", "--timeout=5",
                              "--report=json")
      payload = JSON.parse(out.lines.last)

      assert_equal 0, status.exitstatus, err
      assert_operator payload["mutants"], :>, 5
      assert_operator payload["killed"], :>, 0, "no mutant was killed by the Rails suite"
      assert_equal 0, payload["error"], payload["results"].select { |r| r["status"] == "error" }.first(3).inspect
      assert_operator payload["score"], :>, 0.5

      ticket_kills = payload["results"].count do |result|
        result["status"] == "killed" && result["mutant"]["path"] == "app/models/ticket.rb"
      end
      assert_operator ticket_kills, :>, 0,
                      "the transactional-fixture test should kill a Ticket mutation"

      log = File.join(app, "tmp", "mutation_children.log")
      assert_path_exists log, "the child_start hook did not run"
      assert_operator File.readlines(log).size, :>, 0
    end
  end

  private

  def rails_available?
    # The fixture Gemfile declares mysql2, so the app's bundle needs it to boot
    # even when this test only touches SQLite.
    system(RbConfig.ruby, "-e", "require 'rails'; require 'sqlite3'; require 'mysql2'",
           out: File::NULL, err: File::NULL)
  end

  def run!(dir, *command, env: {})
    out, err, status = nil
    Timeout.timeout(180) do
      out, err, status = Open3.capture3(env, *command, chdir: dir)
    end
    [out, err, status]
  end
end
