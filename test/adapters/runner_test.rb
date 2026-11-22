# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"

class RunnerTest < Minitest::Test
  include AdapterTestHelpers

  def setup
    @tmpdir = Dir.mktmpdir("sabaku-runner-test")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def tiny_config(overrides = {})
    config_for({
      paths: ["lib"],
      output: File.join(@tmpdir, "mutation-report.json")
    }.merge(overrides))
  end

  # tiny_minitest/lib/calc.rb line map:
  #   5  a + b          (covered by test_add)
  #   9  "calculator"   (covered by test_add's coverage, but never called)
  #  13  42             (no covering test)
  def build_tiny_mutants(root)
    [
      build_mutant(root: root, line: 5, original: "a + b", replacement: "a - b"),
      build_mutant(root: root, line: 9, original: '"calculator"', replacement: '"mutant"',
                   operator: :str, node_kind: "StringNode"),
      build_mutant(root: root, line: 13, original: "42", replacement: "43",
                   operator: :lcr, node_kind: "IntegerNode")
    ]
  end

  def tiny_coverage_map
    map = Sabaku::CoverageMap.empty
    map.record("CalcTest#test_add", { "lib/calc.rb" => [4, 5, 6, 9] })
    map
  end

  def run_tiny(isolation: :fork, jobs: 1, timeout: 5.0, coverage: true,
               map: tiny_coverage_map, mutants: nil)
    in_project("tiny_minitest", glob: "test/*_case.rb") do |root|
      mutants ||= build_tiny_mutants(root)
      config = tiny_config(isolation: isolation, jobs: jobs, timeout: timeout,
                           coverage: coverage)
      adapter = minitest_adapter
      Sabaku::Runner.new(config, analyzer: nil, adapter: adapter, coverage_map: map).call(mutants)
    end
  end

  def test_an_uncovered_mutant_says_why_no_test_ran_it
    expected = { instrumented: :not_reached, uninstrumented: :uninstrumented, not_loaded: :not_loaded }
    expected.each do |state, reason|
      map = tiny_coverage_map
      map.describe(Sabaku::CoverageMap::FileCoverage.new(path: "lib/calc.rb", state: state))

      result = run_tiny(map: map).last

      assert_equal [:uncovered, reason], [result.status, result.reason], state
    end
  end

  def test_fork_isolation_statuses
    results = run_tiny(isolation: :fork)

    assert_equal %i[killed survived uncovered], results.map(&:status)
    assert_equal results.map { |result| result.mutant.line }, [5, 9, 13]
    assert_equal "CalcTest#test_add", results[0].failed_test
    assert_operator results[0].duration, :>, 0
    assert_operator results[1].duration, :>, 0
    assert_equal 0.0, results[2].duration
    assert_nil results[2].failed_test
    assert_match(/no covering test/, results[2].message)
  end

  def test_process_isolation_statuses
    results = run_tiny(isolation: :process)

    assert_equal %i[killed survived uncovered], results.map(&:status)
    assert_equal "CalcTest#test_add", results[0].failed_test
    assert_operator results[0].duration, :>, 0
    assert_operator results[1].duration, :>, 0
    assert_equal 0.0, results[2].duration
  end

  def test_jobs_pool_still_returns_statuses_in_input_order
    results = run_tiny(isolation: :fork, jobs: 2)

    assert_equal %i[killed survived uncovered], results.map(&:status)
  end

  def test_coverage_disabled_runs_all_tests
    # With coverage off there is no line map to select from, so every mutant
    # runs the whole suite and the "unused" method mutant is a survivor.
    results = run_tiny(isolation: :fork, coverage: false, map: Sabaku::CoverageMap.empty)

    assert_equal %i[killed survived survived], results.map(&:status)
    refute_includes results.map(&:status), :uncovered
  end

  def test_timeout_is_classified_and_child_is_reaped
    in_project("looping_minitest", glob: "test/*_case.rb") do |root|
      mutant = build_mutant(root: root, path: "lib/loop.rb", line: 5,
                            original: "false", replacement: "true",
                            operator: :bool, node_kind: "FalseNode")
      map = Sabaku::CoverageMap.empty
      map.record("LoopTest#test_spin", { "lib/loop.rb" => [4, 5, 6, 7] })
      config = tiny_config(isolation: :fork, timeout: 0.3)
      adapter = minitest_adapter

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                                             coverage_map: map).call([mutant])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal [:timeout], results.map(&:status)
      assert_equal :deadline, results[0].reason
      assert_operator results[0].duration, :>=, 0.2
      assert_operator elapsed, :<, 5.0

      # No zombie and no orphan: the runner reaped the killed child.
      leftover = begin
        Process.waitpid(-1, Process::WNOHANG)
      rescue Errno::ECHILD
        :no_children
      end
      assert_includes [:no_children, nil], leftover
    end
  end

  def test_cache_hit_skips_execution
    in_project("tiny_minitest", glob: "test/*_case.rb") do |root|
      mutants = build_tiny_mutants(root).first(2)
      config = tiny_config(isolation: :fork)
      map = tiny_coverage_map
      adapter = minitest_adapter

      first = Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                                           coverage_map: map).call(mutants)
      assert_equal %i[killed survived], first.map(&:status)
      assert_equal [5, 9], first.map { |result| result.mutant.line }
      assert_operator first.map(&:duration).min, :>, 0
      cache_file = File.join(@tmpdir, ".sabaku-cache.json")
      assert_path_exists cache_file

      replayed = Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                                               coverage_map: map).call(mutants)
      assert_equal %i[killed survived], replayed.map(&:status)
      assert_equal [0.0, 0.0], replayed.map(&:duration)
      assert_equal "CalcTest#test_add", replayed[0].failed_test
    end
  end

  def test_cache_kill_switch_via_env
    in_project("tiny_minitest", glob: "test/*_case.rb") do |root|
      mutants = build_tiny_mutants(root).first(2)
      config = tiny_config(isolation: :fork)
      map = tiny_coverage_map
      adapter = minitest_adapter

      ENV["SABAKU_NO_CACHE"] = "1"
      begin
        first = Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                                              coverage_map: map).call(mutants)
        second = Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                                               coverage_map: map).call(mutants)
      ensure
        ENV.delete("SABAKU_NO_CACHE")
      end

      assert_equal %i[killed survived], first.map(&:status)
      assert_equal %i[killed survived], second.map(&:status)
      assert_operator second.map(&:duration).min, :>, 0
    end
  end

  def test_fail_fast_stops_after_the_first_survivor
    in_project("tiny_minitest", glob: "test/*_case.rb") do |root|
      mutants = build_tiny_mutants(root)
      mutants << build_mutant(root: root, line: 9, original: '"calculator"',
                              replacement: '"other"', operator: :str,
                              node_kind: "StringNode")
      config = tiny_config(fail_fast: true, jobs: 1)
      adapter = minitest_adapter
      results = Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                                     coverage_map: tiny_coverage_map).call(mutants)

      assert_equal %i[killed survived uncovered skipped], results.map(&:status)
      assert_equal 0.0, results.last.duration
      assert_equal :fail_fast, results.last.reason
      assert_match(/--fail-fast/, results.last.message)
    end
  end

  def test_hooks_run_in_the_documented_order
    log = File.join(@tmpdir, "hooks.log")
    setup_path = File.join(@tmpdir, "sabaku.rb")
    File.write(setup_path, <<~RUBY)
      env "SABAKU_HOOK_TEST" => "on"
      after_boot { Sabaku::RunnerTestHooks.record(#{log.inspect}, "after_boot") }
      before_fork { Sabaku::RunnerTestHooks.record(#{log.inspect}, "before_fork") }
      child_start { |index| Sabaku::RunnerTestHooks.record(#{log.inspect}, "child_start:\#{index}") }
      before_test_run { Sabaku::RunnerTestHooks.record(#{log.inspect}, "before_test_run") }
    RUBY

    in_project("tiny_minitest", glob: "test/*_case.rb") do
      config = tiny_config(setup: Sabaku.setup(setup_path), setup_path: setup_path,
                           env: { "SABAKU_HOOK_TEST" => "on" })
      adapter = minitest_adapter
      Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                           coverage_map: tiny_coverage_map).call(build_tiny_mutants(Dir.pwd))
    end

    lines = File.readlines(log, chomp: true)
    assert_equal %w[after_boot before_fork], lines.first(2)
    assert_equal %w[child_start:0 before_test_run child_start:1 before_test_run],
                 lines.drop(2)
  end
end

# A plain module the setup file can call from a forked child.
module Sabaku
  module RunnerTestHooks
    def self.record(path, line)
      File.open(path, "a") { |file| file.puts(line) }
    end
  end
end
