# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"

class MinitestAdapterTest < Minitest::Test
  include AdapterTestHelpers

  def test_preload_fixture_and_run_subsets
    in_project("minitest_calc") do
      adapter = Sabaku::Adapters::MinitestAdapter.new

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
      adapter = Sabaku::Adapters::MinitestAdapter.new
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
      adapter = Sabaku::Adapters::MinitestAdapter.new
      adapter.preload!

      outcome = adapter.run(["Nope#test_missing"])
      refute outcome.ok
      assert_equal "Nope#test_missing", outcome.failed_id
      assert_kind_of Sabaku::Error, outcome.error
    end
  end

  def test_custom_test_glob
    in_project("minitest_calc") do
      ENV["SABAKU_TEST_GLOB"] = "test/*_test.rb"
      adapter = Sabaku::Adapters::MinitestAdapter.new
      adapter.preload!

      assert_equal 6, adapter.test_ids.size
    ensure
      ENV.delete("SABAKU_TEST_GLOB")
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
      adapter = Sabaku::Adapters::MinitestAdapter.new
      adapter.preload!
      assert_equal ["HiddenCaseTest#test_value"], adapter.test_ids
    end
  ensure
    Minitest.const_set(:Spec, spec) unless Minitest.const_defined?(:Spec, false)
  end
end
