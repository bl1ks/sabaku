# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"

# The three ways fork isolation can lose a result, and what each one should
# report: a file that cannot be reloaded (the harness), a child the suite
# aborts while the selected tests run (a kill), and a mutation that makes the
# file unloadable (an invalid mutant).
class RunnerAttributionTest < Minitest::Test
  include AdapterTestHelpers

  def setup
    @tmpdir = Dir.mktmpdir("ruby-mutation-attribution-test")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def run_campaign(fixture, test_id:, path:, line:, original:, replacement:, operator:, node_kind:,
                   map_lines:)
    in_project(fixture, glob: "test/*_case.rb") do |root|
      mutants = [
        build_mutant(root: root, path: path, line: line, original: original,
                     replacement: replacement, operator: operator, node_kind: node_kind)
      ]
      map = Mutation::CoverageMap.empty
      map.record(test_id, { path => map_lines })
      config = config_for(paths: ["lib"], adapter: :minitest, isolation: :fork,
                          output: File.join(@tmpdir, "report.json"))
      adapter = Mutation::Adapter.for(:minitest, config)
      Mutation::Runner.new(config, analyzer: nil, adapter: adapter, coverage_map: map).call(mutants)
    end
  end

  # configurable.rb cannot be evaluated twice, so no mutation of that file is
  # measurable in fork isolation. The report must not blame the mutant.
  def test_a_file_that_cannot_be_reloaded_is_not_an_error
    result = run_campaign(
      "hostile_reload_minitest", test_id: "HostileTest#test_value",
      path: "lib/hostile.rb", line: 10,
      original: "42", replacement: "43", operator: :lcr, node_kind: "IntegerNode",
      map_lines: (1..12).to_a
    ).first

    assert_equal :skipped, result.status, result.message
    assert_match(/cannot reload the file in fork isolation/, result.message)
    assert_match(/hostile loaded 2 times/, result.message)
  end

  # A helper that ends the child on failure leaves no summary. Exit status 1 is
  # the contract's "a selected test failed", so this is a kill, not an error.
  def test_a_child_that_dies_with_the_failed_test_status_is_a_kill
    result = run_campaign(
      "exit_child_minitest", test_id: "FatalTest#test_value",
      path: "lib/fatal.rb", line: 5,
      original: "1", replacement: "0", operator: :lcr, node_kind: "IntegerNode",
      map_lines: (1..7).to_a
    ).first

    assert_equal :killed, result.status, result.message
    assert_match(/stopped the child/, result.message)
  end

  # A project may override `run`; Active Support's isolation helper does. A
  # return value that is not a Result is that test's failure, not a child crash.
  def test_a_test_class_that_overrides_run_does_not_take_the_child_down
    result = run_campaign(
      "odd_run_minitest", test_id: "OddRunTest#test_value",
      path: "lib/odd.rb", line: 5,
      original: "1", replacement: "0", operator: :lcr, node_kind: "IntegerNode",
      map_lines: (1..7).to_a
    ).first

    assert_equal :killed, result.status, result.message
    assert_equal "OddRunTest#test_value", result.failed_test
    assert_match(/passed\?/, result.message)
  end

  # The exception message travels to the parent as one JSON line. A project byte
  # that is not UTF-8 must not cost the result: the kill has to arrive with the
  # test that made it.
  def test_an_exception_message_with_binary_bytes_still_reports_the_kill
    result = run_campaign(
      "binary_message_minitest", test_id: "BinaryMessageTest#test_value",
      path: "lib/binary_message.rb", line: 5,
      original: "1", replacement: "0", operator: :lcr, node_kind: "IntegerNode",
      map_lines: (1..7).to_a
    ).first

    assert_equal :killed, result.status, result.message
    assert_equal "BinaryMessageTest#test_value", result.failed_test
    assert_match(/ConverterNotFoundError/, result.message)
    assert result.message.valid_encoding?, "the report must carry valid UTF-8"
  end

  # A failure in the test phase is not a load failure. It must stay an error:
  # a broken harness cannot be allowed to leave the score as "not measured".
  def test_a_harness_failure_while_running_tests_stays_an_error
    in_project("tiny_minitest", glob: "test/*_case.rb") do |root|
      mutants = [build_mutant(root: root, line: 5, original: "a + b", replacement: "a - b")]
      map = Mutation::CoverageMap.empty
      map.record("CalcTest#test_add", { "lib/calc.rb" => [4, 5, 6] })
      setup = Mutation::Setup.new
      setup.before_test_run { raise "harness blew up" }
      config = config_for(paths: ["lib"], adapter: :minitest, isolation: :fork, setup: setup,
                          output: File.join(@tmpdir, "report.json"))
      adapter = Mutation::Adapter.for(:minitest, config)
      result = Mutation::Runner.new(config, analyzer: nil, adapter: adapter,
                                    coverage_map: map).call(mutants).first

      assert_equal :error, result.status, result.message
      assert_match(/harness blew up/, result.message)
      refute_match(/does not load/, result.message)
    end
  end

  # The mutation itself makes the class body raise. Reloading the unmutated
  # file proves the harness is fine, so this is an invalid mutant, not an error.
  def test_a_mutation_that_makes_the_file_unloadable_is_not_measured
    result = run_campaign(
      "unviable_load_minitest", test_id: "RegistryTest#test_find",
      path: "lib/registry.rb", line: 19,
      original: 'add "answer", 42', replacement: "add", operator: :call, node_kind: "CallNode",
      map_lines: (1..21).to_a
    ).first

    assert_equal :skipped, result.status, result.message
    assert_match(/the mutated file does not load/, result.message)
    assert_match(/ArgumentError/, result.message)
  end
end
