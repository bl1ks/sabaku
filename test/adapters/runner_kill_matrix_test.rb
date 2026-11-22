# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"

class RunnerKillMatrixTest < Minitest::Test
  include AdapterTestHelpers

  ADD = %w[MatrixTest#test_add_strong MatrixTest#test_add_twin MatrixTest#test_add_wait
           MatrixTest#test_add_weak].freeze

  # Writes the ids of every sweep to a file, because a fork child's memory dies with it.
  class RecordingAdapter < Sabaku::Adapters::MinitestAdapter
    def initialize(log, test_globs:)
      super(test_globs: test_globs)
      @log = log
    end

    def sweep(ids)
      File.open(@log, "a") { |file| file.puts(ids.join(",")) }
      super
    end
  end

  # Decides the label mutant without a child, as the dry run does for an uninfected one.
  WeakLabel = Struct.new(:mutant_id) do
    def decision(mutant, _selected) = mutant.id == mutant_id ? :not_infected : :unknown
  end

  def setup
    @tmpdir = Dir.mktmpdir("sabaku-kill-matrix-test")
    @log = File.join(@tmpdir, "sweeps.log")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  # matrix_calc.rb: add on line 5, sub on line 9, label on line 13.
  def matrix_mutants(root)
    {
      multiply: build_mutant(root: root, path: "lib/matrix_calc.rb", line: 5,
                             original: "a + b", replacement: "a * b"),
      minus: build_mutant(root: root, path: "lib/matrix_calc.rb", line: 5,
                          original: "a + b", replacement: "a - b"),
      sub: build_mutant(root: root, path: "lib/matrix_calc.rb", line: 9,
                        original: "a - b", replacement: "a + b"),
      label: build_mutant(root: root, path: "lib/matrix_calc.rb", line: 13,
                          original: '"label"', replacement: '""', operator: :str,
                          node_kind: "StringNode")
    }
  end

  def matrix_map
    map = Sabaku::CoverageMap.empty
    ADD.each { |id| map.record(id, { "lib/matrix_calc.rb" => [4, 5, 6] }) }
    map.record("MatrixTest#test_sub_only", { "lib/matrix_calc.rb" => [8, 9, 10] })
    map.record("MatrixTest#test_label_smoke", { "lib/matrix_calc.rb" => [12, 13, 14] })
    map
  end

  def run_matrix(kill_matrix:, isolation: :fork, only: nil, weak: false, record: false)
    in_project("matrix_minitest", glob: "test/*_case.rb") do |root|
      mutants = matrix_mutants(root)
      mutants = mutants.slice(*only) if only
      config = config_for(isolation: isolation, timeout: 2.0, kill_matrix: kill_matrix,
                          output: File.join(@tmpdir, "report.json"))
      adapter = record ? RecordingAdapter.new(@log, test_globs: @test_globs) : minitest_adapter
      runner = Sabaku::Runner.new(config, analyzer: nil, adapter: adapter,
                                          coverage_map: matrix_map,
                                          weak: weak ? WeakLabel.new(mutants[:label].id) : nil)
      mutants.keys.zip(runner.call(mutants.values)).to_h
    end
  end

  def comparable(results) = results.transform_values { |result| result.to_h.except(:kills, :duration) }

  def test_kill_matrix_status_parity
    with_no_cache do
      %i[fork process].each do |isolation|
        off = run_matrix(kill_matrix: false, isolation: isolation)
        on = run_matrix(kill_matrix: true, isolation: isolation)

        assert_equal comparable(off), comparable(on), "#{isolation}: the flag changed a result"
        assert_equal %i[killed killed killed survived], on.values.map(&:status)
        assert(off.values.none?(&:kills), "#{isolation}: a row without the flag")
      end
    end
  end

  def test_kill_matrix_rows
    with_no_cache do
      %i[fork process].each do |isolation|
        results = run_matrix(kill_matrix: true, isolation: isolation, only: %i[minus sub label])

        assert_equal %w[MatrixTest#test_add_strong MatrixTest#test_add_twin],
                     results[:minus].kills.killers, isolation
        assert_equal ADD, results[:minus].kills.tested
        assert_equal %w[MatrixTest#test_sub_only], results[:sub].kills.killers
        assert_equal [], results[:label].kills.killers
        assert_equal %w[MatrixTest#test_label_smoke], results[:label].kills.tested
      end
    end
  end

  def test_an_uninfected_survivor_has_a_row_without_a_child
    with_no_cache do
      results = run_matrix(kill_matrix: true, only: %i[label], weak: true)

      assert_equal :not_infected, results[:label].reason
      assert_equal [], results[:label].kills.killers
    end
  end

  def test_sweep_timeout_keeps_kill
    with_no_cache do
      result = run_matrix(kill_matrix: true, only: %i[multiply])[:multiply]

      assert_equal :killed, result.status
      assert_equal "MatrixTest#test_add_strong", result.failed_test
      assert_nil result.kills
    end
  end

  def test_sweep_runs_tail_only
    with_no_cache do
      run_matrix(kill_matrix: true, only: %i[minus sub], record: true)

      assert_equal ["MatrixTest#test_add_twin,MatrixTest#test_add_wait,MatrixTest#test_add_weak"],
                   File.readlines(@log, chomp: true)
    end
  end

  def test_no_sweep_without_flag
    with_no_cache do
      run_matrix(kill_matrix: false, record: true)

      refute_path_exists @log
    end
  end

  def test_an_adapter_that_cannot_sweep_is_refused
    adapter = Object.new
    config = config_for(kill_matrix: true)

    error = assert_raises(Sabaku::Error) { Sabaku::Runner.new(config, adapter: adapter) }
    assert_match(/--kill-matrix/, error.message)
  end

  def test_a_cache_warmed_without_the_flag_still_gets_its_rows
    first = run_matrix(kill_matrix: false, only: %i[minus sub])
    assert first.values.none?(&:kills)

    second = run_matrix(kill_matrix: true, only: %i[minus sub], record: true)

    assert_equal [0.0, 0.0], second.values.map(&:duration), "the pool should be all cache hits"
    assert_equal 2, second[:minus].kills.killers.size
    assert_equal %w[MatrixTest#test_sub_only], second[:sub].kills.killers
    assert_equal 1, File.readlines(@log).size

    third = run_matrix(kill_matrix: true, only: %i[minus sub], record: true)

    assert_equal 1, File.readlines(@log).size, "a cached row should need no sweep"
    assert_equal second.values.map(&:kills), third.values.map(&:kills)

    run_matrix(kill_matrix: false, only: %i[minus sub])
    fourth = run_matrix(kill_matrix: true, only: %i[minus sub], record: true)

    assert_equal 1, File.readlines(@log).size, "a run without the flag erased the cached rows"
    assert_equal second.values.map(&:kills), fourth.values.map(&:kills)
  end

  # test_b_loaded_once fails in every fork child, because the child loads load_counter.rb a second
  # time. The sweep finds it, its reload control fails too, and the row is dropped while the kill
  # by test_a_value stands.
  def test_sweep_unverified_drops_row
    with_no_cache do
      result = in_project("sweep_reload_minitest", glob: "test/*_case.rb") do |root|
        mutant = build_mutant(root: root, path: "lib/load_counter.rb", line: 13, original: "42",
                              replacement: "43", operator: :lcr, node_kind: "IntegerNode")
        map = Sabaku::CoverageMap.empty
        %w[LoadCounterTest#test_a_value LoadCounterTest#test_b_loaded_once].each do |id|
          map.record(id, { "lib/load_counter.rb" => [12, 13, 14] })
        end
        config = config_for(kill_matrix: true, output: File.join(@tmpdir, "report.json"))
        Sabaku::Runner.new(config, adapter: minitest_adapter,
                                   coverage_map: map).call([mutant]).first
      end

      assert_equal :killed, result.status, result.message
      assert_equal "LoadCounterTest#test_a_value", result.failed_test
      assert_nil result.kills
    end
  end

  def with_no_cache
    previous = ENV["SABAKU_NO_CACHE"]
    ENV["SABAKU_NO_CACHE"] = "1"
    yield
  ensure
    previous.nil? ? ENV.delete("SABAKU_NO_CACHE") : ENV["SABAKU_NO_CACHE"] = previous
  end
end
