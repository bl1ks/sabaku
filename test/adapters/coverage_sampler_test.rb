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

  # The weak pass runs after the coverage pass, so both answers come from one call.
  def test_the_weak_pass_answers_covered_mutants
    in_project("minitest_calc") do
      source = Mutation::Source.new("lib/pricing.rb", File.read("lib/pricing.rb"))
      config = config_for
      mutants = Mutation::Analyzer.new([source], config).mutants
      sampler = Mutation::Adapters::CoverageSampler.new(
        config, Mutation::Adapter.for(:minitest, config), [source], mutants: mutants
      )
      map = sampler.call
      weak = sampler.weak_report

      refute_nil weak
      assert_empty sampler.probe_failures
      answered = mutants.each_with_object([]) do |mutant, out|
        next unless mutant.weak

        selected = map.tests_for_span(mutant.path, mutant.line,
                                      source.line_of(mutant.end_offset - 1))
        next if selected.empty?

        out << weak.decision(mutant, selected)
      end
      refute_empty answered
      assert(answered.any? { |verdict| verdict != :unknown },
             "the probe should decide at least one covered mutant: #{answered.inspect}")
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

  def test_a_red_suite_stops_the_campaign_before_it_scores_anything
    in_project("failing_minitest", glob: "test/*_case.rb") do
      source = Mutation::Source.new("lib/thing.rb", File.read("lib/thing.rb"))
      config = config_for
      adapter = Mutation::Adapter.for(:minitest, config)

      error = assert_raises(Mutation::BaselineError) do
        Mutation::Adapters::CoverageSampler.new(config, adapter, [source]).call
      end

      assert_match(/1 of 2 tests fail/, error.message)
      assert_match(/ThingTest#test_broken/, error.message)
      assert_match(/--no-baseline/, error.message)
    end
  end

  def test_no_baseline_keeps_sampling_a_red_suite
    in_project("failing_minitest", glob: "test/*_case.rb") do
      source = Mutation::Source.new("lib/thing.rb", File.read("lib/thing.rb"))
      config = config_for(baseline: false)
      adapter = Mutation::Adapter.for(:minitest, config)

      map = Mutation::Adapters::CoverageSampler.new(config, adapter, [source]).call

      assert_includes map.test_ids, "ThingTest#test_broken"
      assert_includes map.test_ids, "ThingTest#test_value"
    end
  end
end
