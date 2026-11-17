# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class SelectorTest < Minitest::Test
  include CoreTestSupport

  def replacements(text)
    built = source(text)
    mutants_for(built, :selector).map { |mutant| mutant.splice(text) }
  end

  def test_infix_relational_becomes_a_call_form
    assert_equal ["(a).eql?(b)\n", "(a).equal?(b)\n", "a != b\n"], replacements("a == b\n").sort
  end

  def test_method_name_is_swapped_in_place
    assert_equal ["xs.each\n"], replacements("xs.map\n")
  end

  def test_arguments_and_receiver_survive
    assert_equal ["xs.each { |x| x }"], replacements("xs.map { |x| x }")
  end

  def test_exact_alias_pairs_are_not_offered
    replacements = Mutation::Operator::Selector::REPLACEMENTS

    assert_equal %i[public_send], replacements[:send]
    assert_equal %i[public_send], replacements[:__send__]
  end

  def test_safe_navigation_is_not_rewritten
    assert_empty replacements("a&.map\n")
  end

  def test_every_replacement_parses
    text = "class A\n  def f(a, b)\n    (a >= b).eql?(a) && a.send(:m) && a.at(1) || a.empty?\n  end\nend\n"
    built = source(text)
    mutants = mutants_for(built, :selector)

    refute_empty mutants
    assert_mutants_parse(built, mutants)
  end
end
