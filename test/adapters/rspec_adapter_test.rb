# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"

class RSpecAdapterTest < Minitest::Test
  include AdapterTestHelpers

  def test_preload_fixture_and_run_subsets
    in_project("rspec_inventory") do
      adapter = Mutation::Adapter.for(:rspec, config_for(adapter: :rspec))

      assert_equal :rspec, adapter.name
      adapter.preload!

      ids = adapter.test_ids
      assert_equal 5, ids.size
      assert_equal ids.sort, ids
      assert ids.all? { |id| id.match?(%r{\A\./spec/inventory_spec\.rb\[1:\d+\]\z}) },
             "unexpected ids: #{ids.inspect}"

      assert adapter.run(ids).ok, "the whole fixture suite should pass"
      assert adapter.run([ids.first]).ok, "one example at a time should pass"
      assert adapter.run(ids).ok, "a second full run in the same process should pass"
    end
  end

  def test_failing_example_returns_failed_outcome_without_raising
    in_project("failing_rspec") do
      adapter = Mutation::Adapter.for(:rspec, config_for(adapter: :rspec))
      adapter.preload!

      ids = adapter.test_ids
      assert_equal ["./spec/widget_spec.rb[1:1]", "./spec/widget_spec.rb[1:2]"], ids

      outcome = adapter.run(ids)
      refute outcome.ok
      assert_equal "./spec/widget_spec.rb[1:2]", outcome.failed_id
      assert_kind_of RSpec::Expectations::ExpectationNotMetError, outcome.error

      passing = adapter.run(["./spec/widget_spec.rb[1:1]"])
      assert passing.ok

      # Re-running the failed example (a fresh reporter) fails again rather than
      # inheriting stale state from the first run.
      failing_again = adapter.run(["./spec/widget_spec.rb[1:2]"])
      refute failing_again.ok
      assert_equal "./spec/widget_spec.rb[1:2]", failing_again.failed_id
    end
  end

  def test_unknown_id_is_an_error_outcome_not_an_exception
    in_project("rspec_inventory") do
      adapter = Mutation::Adapter.for(:rspec, config_for(adapter: :rspec))
      adapter.preload!

      outcome = adapter.run(["./spec/missing_spec.rb[1:1]"])
      refute outcome.ok
      assert_equal "./spec/missing_spec.rb[1:1]", outcome.failed_id
      assert_kind_of Mutation::Error, outcome.error
    end
  end
end
