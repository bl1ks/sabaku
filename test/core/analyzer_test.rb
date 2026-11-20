# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support"

class AnalyzerTest < Minitest::Test
  include CoreTestSupport

  def test_two_runs_produce_identical_mutant_ids
    built = source("total = a + b\nif total >= 10\n  ship\nend\n")

    first = analyze(built, per_line: 1)
    second = analyze(built, per_line: 1)

    refute_empty first
    assert_equal first.map(&:id), second.map(&:id)
    assert_equal first.map(&:replacement), second.map(&:replacement)
  end

  def test_per_line_spends_its_budget_on_the_most_productive_operator
    built = source("a + b\n")
    aor = fake_mutant(built, operator: :aor, replacement: "a - b")
    lcr = fake_mutant(built, operator: :lcr, replacement: "a || b")
    analyzer = Sabaku::Analyzer.new([built], Sabaku::Config.default(per_line: 1))

    assert_equal [:lcr], analyzer.send(:select_per_line, built, [aor, lcr]).map(&:operator)

    two = Sabaku::Analyzer.new([built], Sabaku::Config.default(per_line: 2))
    assert_equal %i[lcr aor].sort,
                 two.send(:select_per_line, built, [aor, lcr]).map(&:operator).sort
  end

  def test_moving_a_method_keeps_its_mutant_ids
    before = source("def price(a, b)\n  a + b\nend\n", "lib/pricing.rb")
    after = source("# a new comment\n\ndef price(a, b)\n  a + b\nend\n", "lib/pricing.rb")

    assert_equal analyze(before, per_line: 99).map(&:id).sort,
                 analyze(after, per_line: 99).map(&:id).sort
  end

  def test_reopening_a_class_and_redefining_a_method_keeps_ids_distinct
    built = source("class A\n  def value(a, b)\n    a + b\n  end\nend\n\n" \
                   "class A\n  def value(a, b)\n    a + b\n  end\nend\n")
    ids = analyze(built, per_line: 99).select { |m| m.operator == :aor }.map(&:id)

    refute_empty ids
    assert_equal ids.uniq.size, ids.size
  end

  def test_the_same_body_in_two_scopes_is_two_mutants
    built = source("class A\n  def value(a, b)\n    a + b\n  end\nend\n\n" \
                   "class B\n  def value(a, b)\n    a + b\n  end\nend\n")
    ids = analyze(built, per_line: 99).select { |m| m.operator == :aor }.map(&:id)

    refute_empty ids
    assert_equal ids.uniq.size, ids.size
  end

  def test_each_is_lazy_and_matches_mutants
    built = source("a + b\nc * d\n")
    analyzer = Sabaku::Analyzer.new([built], Sabaku::Config.default)

    assert_instance_of Enumerator, analyzer.each
    assert_equal analyzer.mutants, analyzer.each.to_a
    assert_equal analyzer.mutants.map(&:id), analyzer.each.map(&:id)
  end

  def test_mutants_are_ordered_by_path_offset_and_operator
    later = source("a + b\n", "zeta.rb")
    earlier = source("c * d\ne - f\n", "alpha.rb")
    mutants = analyze([later, earlier], per_line: 99)

    assert_equal %w[alpha.rb zeta.rb], mutants.map(&:path).uniq,
                 "mutants are grouped by path"
    assert_equal mutants.map(&:path).sort, mutants.map(&:path), "paths are ordered"
    earlier_mutants = mutants.select { |mutant| mutant.path == "alpha.rb" }
    offsets = earlier_mutants.map(&:start_offset)
    assert_equal offsets.sort, offsets
    ties = earlier_mutants.group_by(&:start_offset).values.select { |group| group.size > 1 }
    ties.each do |group|
      assert_equal group.sort_by { |mutant| [mutant.operator.to_s, mutant.replacement] },
                   group
    end
  end

  def test_diff_ranges_filter_by_line
    built = source("a + b\nc + d\ne + f\n", "lib/subject.rb")

    mutants = analyze(built, diff_ranges: { "lib/subject.rb" => [2..2] }, per_line: 99)

    assert_equal [2], mutants.map(&:line).uniq
    assert(mutants.all? { |mutant| mutant.line == 2 })
  end

  def test_diff_ranges_for_another_file_drop_everything
    built = source("a + b\n", "lib/subject.rb")
    assert_empty analyze(built, diff_ranges: { "lib/other.rb" => [1..3] })
  end

  def test_diff_filters_on_the_line_a_statement_mutant_is_reported_on
    built = source(<<~RUBY, "lib/subject.rb")
      def total(x)
        a = x + 1
        b = a * 2
        a + b
      end
    RUBY

    first_only = analyze(built, diff_ranges: { "lib/subject.rb" => [2..2] }, per_line: 99)
    second_only = analyze(built, diff_ranges: { "lib/subject.rb" => [3..3] }, per_line: 99)

    assert_equal [2], first_only.map(&:line).uniq
    assert(second_only.any? { |mutant| mutant.operator == :sbr && mutant.line == 3 })
  end

  def test_per_line_caps_mutants_on_one_line
    built = source("a + b + c\n")

    assert_equal 1, analyze(built, per_line: 1).size
    assert_equal 2, analyze(built, per_line: 2).size
    assert_operator analyze(built, per_line: 99).size, :>=, 8
    assert_equal 2, analyze(built, per_line: 2).size
  end

  def test_arid_nodes_are_not_mutated
    arids = [
      "LIMIT = 3\n",
      "attr_reader :value\n",
      "def initialize(value)\n  @value = value\nend\n",
      "def to_s\n  \"Box\"\nend\n",
      "puts \"a + b\"\n",
      "value.freeze\n",
      "__FILE__\n"
    ]

    arids.each do |text|
      assert_empty analyze(source(text), per_line: 99), "expected no mutants for #{text.inspect}"
    end
    assert_equal [1], analyze(source("value = a + b\n"), per_line: 99).map(&:line).uniq
  end

  def test_suppressed_calls_do_not_leak_mutants
    assert_empty analyze(source("puts \"a + b\"\n"), per_line: 99)
    assert_equal [1], analyze(source("value = a + b\n"), per_line: 99).map(&:line).uniq
  end

  def test_operator_original_mismatch_raises_operator_error
    built = source("a + b\n")
    node = built.flat_nodes.find { |candidate| candidate.is_a?(Prism::CallNode) }
    fake = Struct.new(:id).new(:fake)
    replacement = Sabaku::Operator::Replacement.new(original: "not the slice",
                                                      replacement: "a - b")
    analyzer = Sabaku::Analyzer.new([], Sabaku::Config.default(operators: []))

    error = assert_raises(Sabaku::OperatorError) do
      analyzer.send(:verify!, fake, replacement, "a + b", built, node)
    end

    assert_match(/expected "a \+ b"/, error.message)
  end

  def test_empty_sources_produce_no_mutants
    assert_empty analyze([])
  end

  # A heredoc, a multi-line receiver and a parenthesised modifier all produce
  # candidates that only break once they land. Scoring one as a mutant would fail
  # the campaign with an error the suite cannot fix, so the gate drops it and the
  # line keeps its next candidate.
  def test_a_candidate_that_does_not_parse_is_replaced_by_another_on_its_line
    built = source("a + b\n")
    good = fake_mutant(built, replacement: "a - b", end_offset: 5)
    broken = fake_mutant(built, replacement: "a -", end_offset: 5)
    analyzer = Sabaku::Analyzer.new([built], Sabaku::Config.default(per_line: 1))

    chosen = analyzer.send(:select_per_line, built, [broken, good])

    assert_equal [good.id], chosen.map(&:id)
  end

  def test_a_line_whose_candidates_all_break_keeps_no_mutant
    built = source("a + b\n")
    broken = fake_mutant(built, replacement: "a -", end_offset: 5)
    analyzer = Sabaku::Analyzer.new([built], Sabaku::Config.default(per_line: 1))

    assert_empty analyzer.send(:select_per_line, built, [broken])
  end

  def fake_mutant(built, replacement:, end_offset: 5, operator: :aor)
    Sabaku::Mutant.new(
      path: built.rel_path, operator: operator, line: 1, column: 0, node_kind: "CallNode",
      original: "a + b", replacement: replacement, start_offset: 0, end_offset: end_offset
    )
  end
end
