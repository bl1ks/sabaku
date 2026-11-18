# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support"

class WeakTest < Minitest::Test
  include CoreTestSupport

  def setup
    Mutation::Weak.reset!
  end

  def teardown
    Mutation::Weak.reset!
  end

  def mutant(id)
    Mutation::Mutant.new(
      id: id, path: "lib/subject.rb", operator: :aor, line: 1, column: 0,
      node_kind: "CallNode", original: "a - b", replacement: "a + b",
      start_offset: 0, end_offset: 5
    )
  end

  def test_pure_binary_expressions_are_eligible
    built = source("def total(a, b)\n  a + b\nend\n")
    node, = find_node(built, Prism::CallNode, name: :+)

    assert Mutation::Weak.eligible?(:aor, node)
  end

  def test_a_method_call_operand_is_not_probed
    built = source("def total(a, b)\n  a.to_i + b\nend\n")
    node, = find_node(built, Prism::CallNode, name: :+)

    refute Mutation::Weak.eligible?(:aor, node)
    mutants = analyze(built, operators: [:aor], per_line: 99)
    refute_empty mutants
    assert(mutants.none?(&:weak))
  end

  # Four replacements of one expression are one probe: the original is evaluated
  # once and every replacement is compared against that value.
  def test_mutants_of_one_expression_share_a_probe
    built = source("def total(a, b)\n  a - b\nend\n")
    mutants = analyze(built, operators: [:aor], per_line: 99)

    assert_equal 4, mutants.size
    probes = Mutation::Weak.probes(built, mutants)

    assert_equal 1, probes.size
    mutants.each { |candidate| assert_includes probes.first.text, candidate.id }
    assert_valid_ruby(Mutation::Weak.apply(built.text, probes))
  end

  def test_a_nested_expression_is_left_to_the_outer_probe
    built = source("def total(a, b, c)\n  a + b * c\nend\n")
    mutants = analyze(built, operators: [:aor], per_line: 99)

    probes = Mutation::Weak.probes(built, mutants)

    assert_equal 1, probes.size
    assert_includes probes.first.text, "a + b * c"
  end

  def test_evaluate_returns_the_original_and_records_each_form
    Mutation::Weak.test_id = "T1"

    result = Mutation::Weak.evaluate(
      5,
      [
        ["same", -> { 5 }],
        ["diff", -> { 6 }],
        ["raise", -> { raise "boom" }]
      ]
    )
    report = Mutation::Weak.report

    assert_equal 5, result
    assert_equal :not_infected, report.decision(mutant("same"), ["T1"])
    assert_equal :infected, report.decision(mutant("diff"), ["T1"])
    assert_equal :infected, report.decision(mutant("raise"), ["T1"])
    assert_equal :unknown, report.decision(mutant("missing"), ["T1"])
    assert_equal :unknown, report.decision(mutant("same"), ["T2"]),
                 "a test that never evaluated the expression decides nothing"
  end

  def test_nothing_is_recorded_without_a_test_id
    Mutation::Weak.evaluate(5, [["k", -> { 6 }]])
    report = Mutation::Weak.report

    assert_equal :unknown, report.decision(mutant("k"), ["T1"])
  end

  def test_instrument_returns_nil_when_no_mutant_is_probe_eligible
    built = source("def total(a, b)\n  a.to_i + b\nend\n")
    mutants = analyze(built, operators: [:aor], per_line: 99)

    assert_nil Mutation::Weak.instrument(built, mutants)
  end
end
