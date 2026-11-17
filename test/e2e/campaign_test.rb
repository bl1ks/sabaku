# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "json"
require "timeout"

# End-to-end: the real binary, the real fixtures, the real exit codes.
# Run with: ./bin/rt ruby -Ilib -Itest test/e2e/campaign_test.rb
class CampaignTest < Minitest::Test
  include FixtureHelper

  BIN = File.expand_path("../../bin/mutation", __dir__)

  def run_cli(fixture, *args, timeout: 120)
    root = fixture_path(fixture)
    out, err, status = nil
    Timeout.timeout(timeout) do
      out, err, status = Open3.capture3(RbConfig.ruby, BIN, *args, chdir: root)
    end
    [out, err, status.exitstatus]
  end

  def campaign(fixture, lib, *args)
    out, err, code = run_cli(fixture, "run", lib, "--report=json", *args)
    assert_equal 0, code, "expected exit 0, got #{code}\n#{err}\n#{out}"
    JSON.parse(out.lines.last)
  end

  def test_minitest_campaign_kills_and_leaves_survivors
    payload = campaign("minitest_calc", "lib", "--adapter=minitest", "--jobs=2")
    assert_operator payload["mutants"], :>, 10, "a 27 line file should yield more than 10 mutants"
    assert_operator payload["killed"], :>, 0
    assert_operator payload["survived"], :>, 0, "the fixture has weak assertions on purpose"
    assert_equal 0, payload["error"], "no mutant should fail to apply\n#{payload["results"].select { |r| r["status"] == "error" }.first(3).inspect}"
    counted = payload["killed"] + payload["survived"] + payload["timeout"]
    assert_in_delta payload["killed"].fdiv(counted), payload["score"], 0.001
  end

  def test_rspec_campaign_runs
    payload = campaign("rspec_inventory", "lib", "--adapter=rspec")
    assert_operator payload["mutants"], :>, 5
    assert_operator payload["killed"] + payload["survived"], :>, 0
    assert_equal 0, payload["error"]
  end

  def test_same_mutants_from_list_and_run
    out, _err, code = run_cli("minitest_calc", "list", "lib", "--adapter=minitest")
    assert_equal 0, code
    listed = out[/^(\d+) mutants$/, 1].to_i
    payload = campaign("minitest_calc", "lib", "--adapter=minitest", "--jobs=2")
    assert_equal listed, payload["mutants"], "list and run must agree on the mutant set"
  end

  def test_arid_lines_are_never_survivors
    payload = campaign("minitest_calc", "lib", "--adapter=minitest", "--jobs=2")
    source = read_fixture("minitest_calc", "lib", "pricing.rb").lines
    attr_line = source.index { |l| l.include?("attr_reader :items") } + 1
    to_s_line = source.index { |l| l.include?("def to_s") } + 1
    survivor_lines = payload["survivors"].map { |s| s["line"] }
    refute_includes survivor_lines, attr_line
    refute_includes survivor_lines, to_s_line
  end

  # Regression for two bugs the self-mutation run found. A file that uses require_relative
  # must reload with the path it is used to (or every mutant is an error), and a mutant on an
  # interior line of a multi-line boolean chain must not be misreported as uncovered.
  def test_require_relative_and_multiline_chains_are_handled
    root = File.expand_path("fixtures/reload_project", __dir__)
    out, err, code = Timeout.timeout(120) do
      Open3.capture3(RbConfig.ruby, BIN, "run", "lib", "--report=json",
                     "--adapter=minitest", "--jobs=2", chdir: root)
    end
    assert_equal 0, code, err
    payload = JSON.parse(out.lines.last)
    assert_equal 0, payload["error"], "reloading require_relative must not break mutants"
    assert_equal 0, payload["uncovered"], "interior lines of a && chain are still covered"
    assert_operator payload["killed"], :>, 0
  end

  def test_process_isolation_agrees_with_fork_on_a_shared_prefix
    fork_payload = campaign("minitest_calc", "lib", "--adapter=minitest", "--operators=aor", "--jobs=2")
    proc_payload = campaign("minitest_calc", "lib", "--adapter=minitest", "--operators=aor",
                            "--isolation=process", "--jobs=2")
    assert_equal fork_payload["mutants"], proc_payload["mutants"]
    assert_equal 0, proc_payload["error"]
  end

  def test_min_score_gate_exits_one
    _out, _err, code = run_cli("minitest_calc", "run", "lib", "--adapter=minitest",
                               "--min-score=99", "--report=quiet")
    assert_equal 1, code
  end

  def test_seed_changes_the_per_line_pick_but_not_the_count
    a = campaign("minitest_calc", "lib", "--adapter=minitest", "--seed=1", "--jobs=2")
    b = campaign("minitest_calc", "lib", "--adapter=minitest", "--seed=2", "--jobs=2")
    assert_equal a["mutants"], b["mutants"]
    refute_equal a["survivors"].map { |s| [s["line"], s["replacement"]] },
                 b["survivors"].map { |s| [s["line"], s["replacement"]] }
  end

  def test_no_coverage_runs_the_whole_suite_per_mutant_and_still_scores
    payload = campaign("minitest_calc", "lib", "--adapter=minitest", "--no-coverage", "--jobs=2")
    assert_operator payload["killed"], :>, 0
    assert_equal 0, payload["uncovered"], "without selection nothing is classified uncovered"
  end
end
