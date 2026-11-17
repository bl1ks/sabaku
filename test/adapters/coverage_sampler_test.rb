# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"

class CoverageSamplerTest < Minitest::Test
  include AdapterTestHelpers

  SHIPPING_TEST = "PricingTest#test_shipping_under_threshold"

  def test_shipping_test_covers_shipping_lines_and_not_unrelated_ones
    in_project("minitest_calc") do
      source = Mutation::Source.new("lib/pricing.rb", File.read("lib/pricing.rb"))
      adapter = Mutation::Adapter.for(:minitest, config_for)
      map = Mutation::Adapters::CoverageSampler.new(config_for, adapter, [source]).call

      # Both tests that call Pricing#shipping must be recorded on the lines of
      # the method body...
      assert_includes map.tests_for("lib/pricing.rb", 37), SHIPPING_TEST
      assert_includes map.tests_for("lib/pricing.rb", 39), SHIPPING_TEST
      assert_includes map.tests_for("lib/pricing.rb", 37), "PricingTest#test_total"
      assert_includes map.tests_for("lib/pricing.rb", 39), "PricingTest#test_total"

      # ...and the shipping test must not be credited with lines it never ran:
      # the tax expression and the bulk-discount tier.
      refute_includes map.tests_for("lib/pricing.rb", 33), SHIPPING_TEST
      refute_includes map.tests_for("lib/pricing.rb", 24), SHIPPING_TEST
      assert_includes map.tests_for("lib/pricing.rb", 33), "PricingTest#test_tax"
      assert_includes map.tests_for("lib/pricing.rb", 24), "PricingTest#test_discount_for_bulk_order"

      # Keys stay repo-relative so they line up with Mutant#path and the cache.
      paths = map.to_h.fetch("tests").values.flat_map(&:keys).uniq
      assert_equal ["lib/pricing.rb"], paths
      refute_includes map.test_ids, SHIPPING_TEST + "_not_a_test"
    end
  end

  # Selection only ever asks about a mutant's own span or the statement span it
  # falls back to. Recording just those lines must not change any answer.
  def test_mutant_scope_keeps_every_selection_query_identical
    in_project("minitest_calc") do
      source = Mutation::Source.new("lib/pricing.rb", File.read("lib/pricing.rb"))
      config = config_for
      mutants = Mutation::Analyzer.new([source], config).mutants

      full = Mutation::Adapters::CoverageSampler.new(
        config, Mutation::Adapter.for(:minitest, config), [source]
      ).call
      scoped = Mutation::Adapters::CoverageSampler.new(
        config, Mutation::Adapter.for(:minitest, config), [source], mutants: mutants
      ).call

      mutants.each do |mutant|
        last = source.line_of(mutant.end_offset - 1)
        assert_equal full.tests_for_span(mutant.path, mutant.line, last),
                     scoped.tests_for_span(mutant.path, mutant.line, last),
                     "selection changed for #{mutant.path}:#{mutant.line}"
      end
    end
  end

  def test_rspec_examples_are_recorded_by_native_id
    in_project("rspec_inventory") do
      source = Mutation::Source.new("lib/inventory.rb", File.read("lib/inventory.rb"))
      config = config_for(adapter: :rspec)
      adapter = Mutation::Adapter.for(:rspec, config)
      map = Mutation::Adapters::CoverageSampler.new(config, adapter, [source]).call

      release_example = "./spec/inventory_spec.rb[1:5]"
      restock_example = "./spec/inventory_spec.rb[1:4]"

      assert_includes map.tests_for("lib/inventory.rb", 35), release_example
      refute_includes map.tests_for("lib/inventory.rb", 35), restock_example
      assert_includes map.tests_for("lib/inventory.rb", 43), restock_example
      refute_includes map.tests_for("lib/inventory.rb", 43), release_example
    end
  end

  # Ruby instruments a file when it is compiled. If an embedding process (or an
  # earlier adapter preload) already required the source before Coverage.start,
  # the sampler must re-load that target under coverage instead of returning an
  # empty map for it.
  def test_source_loaded_before_coverage_start_is_still_instrumented
    in_project("minitest_calc") do
      lib = File.expand_path("lib")
      $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
      require "pricing"

      source = Mutation::Source.new("lib/pricing.rb", File.read("lib/pricing.rb"))
      config = config_for
      adapter = Mutation::Adapter.for(:minitest, config)
      map = Mutation::Adapters::CoverageSampler.new(config, adapter, [source]).call

      assert_includes map.tests_for("lib/pricing.rb", 39), SHIPPING_TEST
    end
  end
end
