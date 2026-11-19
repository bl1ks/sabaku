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

  def run_cli(fixture, *args, timeout: 120, env: {})
    run_cli_at(fixture_path(fixture), *args, timeout: timeout, env: env)
  end

  def run_cli_at(root, *args, timeout: 120, env: {})
    out, err, status = nil
    Timeout.timeout(timeout) do
      out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args, chdir: root)
    end
    [out, err, status.exitstatus]
  end

  def campaign(fixture, lib, *args, env: {})
    out, err, code = run_cli(fixture, "run", lib, "--report=json", *args, env: env)
    assert_equal 0, code, "expected exit 0, got #{code}\n#{err}\n#{out}"
    JSON.parse(out.lines.last)
  end

  # A scratch copy, so a test can break the suite without touching the fixture
  # every other test reads.
  def copy_fixture(fixture)
    Dir.mktmpdir("ruby-mutation-e2e") do |dir|
      FileUtils.cp_r(File.join(fixture_path(fixture), "."), dir)
      FileUtils.rm_f(File.join(dir, ".mutation-cache.json"))
      yield dir
    end
  end

  def add_failing_test(dir)
    File.write(File.join(dir, "test", "zz_broken_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require "pricing"

      class ZzBrokenTest < Minitest::Test
        def test_deliberate_failure
          assert false, "deliberate"
        end
      end
    RUBY
  end

  def test_minitest_campaign_kills_and_leaves_survivors
    payload = campaign("minitest_calc", "lib", "--jobs=2")
    assert_operator payload["mutants"], :>, 10, "a 27 line file should yield more than 10 mutants"
    assert_operator payload["killed"], :>, 0
    assert_operator payload["survived"], :>, 0, "the fixture has weak assertions on purpose"
    assert_equal 0, payload["error"], "no mutant should fail to apply\n#{payload["results"].select { |r| r["status"] == "error" }.first(3).inspect}"
    counted = payload["killed"] + payload["survived"] + payload["timeout"]
    assert_in_delta payload["killed"].fdiv(counted), payload["score"], 0.001
  end

  def test_same_mutants_from_list_and_run
    out, _err, code = run_cli("minitest_calc", "list", "lib")
    assert_equal 0, code
    listed = out[/^(\d+) mutants$/, 1].to_i
    payload = campaign("minitest_calc", "lib", "--jobs=2")
    assert_equal listed, payload["mutants"], "list and run must agree on the mutant set"
  end

  def test_arid_lines_are_never_survivors
    payload = campaign("minitest_calc", "lib", "--jobs=2")
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
      Open3.capture3(RbConfig.ruby, BIN, "run", "lib", "--report=json", "--jobs=2", chdir: root)
    end
    assert_equal 0, code, err
    payload = JSON.parse(out.lines.last)
    assert_equal 0, payload["error"], "reloading require_relative must not break mutants"
    assert_equal 0, payload["uncovered"], "interior lines of a && chain are still covered"
    assert_operator payload["killed"], :>, 0
  end

  def test_process_isolation_agrees_with_fork_on_a_shared_prefix
    fork_payload = campaign("minitest_calc", "lib", "--operators=aor", "--jobs=2")
    proc_payload = campaign("minitest_calc", "lib", "--operators=aor",
                            "--isolation=process", "--jobs=2")
    assert_equal fork_payload["mutants"], proc_payload["mutants"]
    assert_equal 0, proc_payload["error"]
  end

  def test_min_score_gate_exits_one
    _out, _err, code = run_cli("minitest_calc", "run", "lib",
                               "--min-score=99", "--report=quiet")
    assert_equal 1, code
  end

  def test_the_same_code_runs_the_same_mutants
    a = campaign("minitest_calc", "lib", "--jobs=2")
    b = campaign("minitest_calc", "lib", "--jobs=2")
    assert_equal a["mutants"], b["mutants"]
    assert_equal a["survivors"].map { |s| [s["line"], s["replacement"]] },
                 b["survivors"].map { |s| [s["line"], s["replacement"]] }
  end

  def test_no_coverage_runs_the_whole_suite_per_mutant_and_still_scores
    payload = campaign("minitest_calc", "lib", "--no-coverage", "--jobs=2")
    assert_operator payload["killed"], :>, 0
    assert_equal 0, payload["uncovered"], "without selection nothing is classified uncovered"
  end

  # With coverage on, the sampler runs every test once and reports a red suite.
  # Without it, nothing ran the suite at all, so a red one scored every covered
  # mutant as killed and the campaign still exited 0.
  def test_a_red_suite_stops_the_campaign_even_without_coverage
    copy_fixture("minitest_calc") do |dir|
      add_failing_test(dir)
      _out, err, code = run_cli_at(dir, "run", "lib", "--no-coverage", "--report=quiet",
                                   env: { "RUBY_MUTATION_NO_CACHE" => "1" })

      assert_equal 2, code
      assert_includes err, "not green with no mutation applied"
      assert_includes err, "ZzBrokenTest#test_deliberate_failure"
    end
  end

  def test_no_baseline_scores_a_red_suite_anyway
    copy_fixture("minitest_calc") do |dir|
      add_failing_test(dir)
      _out, _err, code = run_cli_at(dir, "run", "lib", "--no-coverage", "--no-baseline",
                                    "--report=quiet", env: { "RUBY_MUTATION_NO_CACHE" => "1" })

      assert_equal 0, code
    end
  end

  # Fork isolation applies a mutant by re-running the file over the parent's
  # copy. This fixture registers itself at load time, so every child sees two
  # registrations and the test that counts them fails without the mutation
  # having done anything.
  def test_a_kill_that_only_the_second_load_caused_is_not_reported_as_killed
    out, err, code = run_cli("plugin_project", "run", "lib/plugin.rb", "--operators=literal,return",
                             "--per-line=all", "--report=json",
                             env: { "RUBY_MUTATION_NO_CACHE" => "1" })
    payload = JSON.parse(out.lines.last)

    assert_equal 2, code, err
    assert_equal 0, payload["killed"], "every kill here was caused by the second load"
    assert_operator payload["error"], :>, 0
    assert_includes out, "unverified kill"
    assert_includes err, "produced no result"
  end

  def test_process_isolation_scores_the_same_file_without_the_second_load
    payload = campaign("plugin_project", "lib/plugin.rb", "--operators=literal,return",
                       "--per-line=all", "--isolation=process",
                       env: { "RUBY_MUTATION_NO_CACHE" => "1" })

    assert_operator payload["killed"], :>, 0
    assert_operator payload["survived"], :>, 0
    assert_equal 0, payload["error"]
  end
end
