# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support"

class FixtureMutantsTest < Minitest::Test
  include CoreTestSupport
  include FixtureHelper

  PRICING = "lib/pricing.rb"
  INVENTORY = "lib/inventory.rb"

  def pricing
    source(read_fixture("minitest_calc", "lib", "pricing.rb"), PRICING)
  end

  def inventory
    source(read_fixture("inventory", "lib", "inventory.rb"), INVENTORY)
  end

  def mutants_for_fixture(built, operators: Sabaku::Operator::Registry.ids, per_line: 100)
    analyze(built, operators: operators, per_line: per_line)
  end

  def test_pricing_default_selection_is_one_mutant_per_line
    built = pricing
    mutants = mutants_for_fixture(built, operators: Sabaku::Operator::Registry.defaults, per_line: 1)

    assert_includes 8..20, mutants.size
    assert_equal mutants.size, mutants.map(&:line).uniq.size
    assert_mutants_parse(built, mutants)
  end

  def test_pricing_full_candidate_set_is_plausible
    built = pricing
    mutants = mutants_for_fixture(built)

    assert_includes 20..260, mutants.size
    assert_mutants_parse(built, mutants)
  end

  def test_inventory_default_selection_is_one_mutant_per_line
    built = inventory
    mutants = mutants_for_fixture(built, operators: Sabaku::Operator::Registry.defaults, per_line: 1)

    assert_includes 6..15, mutants.size
    assert_equal mutants.size, mutants.map(&:line).uniq.size
    assert_mutants_parse(built, mutants)
  end

  def test_inventory_full_candidate_set_is_plausible
    built = inventory
    mutants = mutants_for_fixture(built)

    assert_includes 20..260, mutants.size
    assert_mutants_parse(built, mutants)
  end

  def test_no_mutant_line_is_on_an_arid_pricing_line
    mutants = mutants_for_fixture(pricing)
    arid_lines = pricing.text.lines.each_with_index.filter_map do |line, index|
      number = index + 1
      number if line.match?(/^\s+attr_reader\b/) || line.match?(/^\s+def to_s\b/)
    end
    to_s_line = pricing.text.lines.index { |line| line.match?(/^\s+def to_s\b/) } + 1

    refute_empty arid_lines
    assert_empty(mutants.map(&:line).uniq & arid_lines)
    refute_includes mutants.map(&:line), to_s_line
    refute_includes mutants.map(&:line), to_s_line + 1
  end

  def test_guarded_debug_log_line_has_no_mutants
    built = inventory
    log_line = built.text.lines.index { |line| line.include?("restocked") } + 1
    mutants = mutants_for_fixture(built)

    refute_includes mutants.map(&:line), log_line
  end

  def test_no_mutant_line_is_on_an_arid_inventory_line
    mutants = mutants_for_fixture(inventory)
    arid_lines = inventory.text.lines.each_with_index.filter_map do |line, index|
      number = index + 1
      number if line.match?(/^\s+attr_reader\b/)
    end
    initialize_line = inventory.text.lines.index { |line| line.match?(/^\s+def initialize\b/) } + 1

    refute_empty arid_lines
    assert_empty(mutants.map(&:line).uniq & arid_lines)
    refute_includes mutants.map(&:line), initialize_line
  end
end
