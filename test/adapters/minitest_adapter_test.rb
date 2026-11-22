# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"

class MinitestAdapterTest < Minitest::Test
  include AdapterTestHelpers

  def test_preload_fixture_and_run_subsets
    in_project("minitest_calc") do
      adapter = minitest_adapter

      adapter.preload!

      ids = adapter.test_ids
      assert_equal 6, ids.size
      assert_equal ids.sort, ids
      assert ids.all? { |id| id.match?(/\APricingTest#test_\w+\z/) },
             "unexpected ids: #{ids.inspect}"

      assert adapter.run(ids).ok, "the whole fixture suite should pass"
      assert adapter.run([ids.first]).ok, "one test at a time should pass"
      assert adapter.run(ids).ok, "a second full run in the same process should pass"
    end
  end

  def test_failing_test_returns_failed_outcome_without_raising
    in_project("failing_minitest", glob: "test/*_case.rb") do
      adapter = minitest_adapter
      adapter.preload!

      ids = adapter.test_ids
      assert_equal %w[ThingTest#test_broken ThingTest#test_value], ids

      outcome = adapter.run(ids)
      refute outcome.ok
      assert_equal "ThingTest#test_broken", outcome.failed_id
      # An assertion failure is an ordinary result, not a raised exception.
      assert_nil outcome.error

      # A failing run must not poison the next subset run.
      passing = adapter.run(["ThingTest#test_value"])
      assert passing.ok
      assert_nil passing.failed_id
    end
  end

  def test_unknown_id_is_an_error_outcome_not_an_exception
    in_project("minitest_calc") do
      adapter = minitest_adapter
      adapter.preload!

      outcome = adapter.run(["Nope#test_missing"])
      refute outcome.ok
      assert_equal "Nope#test_missing", outcome.failed_id
      assert_kind_of Sabaku::Error, outcome.error
    end
  end

  def with_matrix_add(body)
    in_project("matrix_minitest", glob: "test/*_case.rb") do
      adapter = minitest_adapter
      adapter.preload!
      original = MatrixCalc.method(:add)
      MatrixCalc.define_singleton_method(:add, &body)
      yield adapter
    ensure
      MatrixCalc.define_singleton_method(:add, original) if original
    end
  end

  def test_sweep_reports_every_failing_id_in_order_and_run_still_stops_at_the_first
    with_matrix_add(->(a, b) { a * b }) do |adapter|
      ids = %w[MatrixTest#test_add_weak MatrixTest#test_sub_only MatrixTest#test_add_strong]

      assert_equal %w[MatrixTest#test_add_weak MatrixTest#test_add_strong],
                   adapter.sweep(ids).failed_ids
      assert_equal "MatrixTest#test_add_weak", adapter.run(ids).failed_id
      assert_empty adapter.sweep(["MatrixTest#test_sub_only"]).failed_ids
    end
  end

  def test_sweep_counts_an_unknown_id_as_failed_like_run
    with_matrix_add(->(a, b) { a + b }) do |adapter|
      swept = adapter.sweep(%w[Nope#test_missing MatrixTest#test_add_strong])

      assert_equal %w[Nope#test_missing], swept.failed_ids
      assert_predicate swept, :killed?
      refute adapter.run(%w[Nope#test_missing]).ok
    end
  end

  def test_sweep_counts_a_run_override_that_returns_garbage_as_failed
    in_project("odd_run_minitest", glob: "test/*_case.rb") do
      adapter = minitest_adapter
      adapter.preload!
      original = Odd.method(:value)
      Odd.define_singleton_method(:value) { 0 }

      assert_equal %w[OddRunTest#test_value], adapter.sweep(%w[OddRunTest#test_value]).failed_ids
      refute adapter.run(%w[OddRunTest#test_value]).ok
    ensure
      Odd.define_singleton_method(:value, original) if original
    end
  end

  def test_custom_test_glob
    in_project("minitest_calc") do
      adapter = Sabaku::Adapters::MinitestAdapter.new(test_globs: ["test/*_test.rb"])
      adapter.preload!

      assert_equal 6, adapter.test_ids.size
    end
  end

  def test_the_adapter_reads_its_globs_from_the_caller_not_the_environment
    in_project("minitest_calc") do
      ENV["SABAKU_TEST_GLOB"] = "test/nothing_matches_*.rb"
      adapter = minitest_adapter

      assert_equal [Sabaku::Adapters::MinitestAdapter::MINITEST_GLOB], adapter.test_globs
      refute_empty adapter.test_files
    ensure
      ENV.delete("SABAKU_TEST_GLOB")
    end
  end

  def test_preload_survives_classes_that_override_name_and_raise
    shadow = Class.new do
      def self.name(*)
        raise ArgumentError, "missing keywords: :size, :region"
      end
    end

    in_project("minitest_calc") do
      adapter = minitest_adapter
      adapter.preload!
      assert_equal 6, adapter.test_ids.size
      assert_raises(ArgumentError) { shadow.name }
    end
  end
end

class MinitestAdapterTest < Minitest::Test
  # A Rails test_helper requires minitest but not minitest/spec, so the
  # adapter must not name Minitest::Spec while discovering test classes.
  def test_preload_succeeds_when_minitest_spec_is_not_loaded
    spec = Minitest::Spec
    Minitest.send(:remove_const, :Spec)

    in_project("no_spec_minitest", glob: "test/*_case.rb") do
      adapter = minitest_adapter
      adapter.preload!
      assert_equal ["HiddenCaseTest#test_value"], adapter.test_ids
    end
  ensure
    Minitest.const_set(:Spec, spec) unless Minitest.const_defined?(:Spec, false)
  end
end
