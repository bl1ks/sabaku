# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support"

class AnalyzerTest < Minitest::Test
  include CoreTestSupport

  def test_two_runs_produce_identical_mutant_ids
    built = source("total = a + b\nif total >= 10\n  ship\nend\n")

    first = analyze(built, seed: 7, per_line: 1)
    second = analyze(built, seed: 7, per_line: 1)

    refute_empty first
    assert_equal first.map(&:id), second.map(&:id)
    assert_equal first.map(&:replacement), second.map(&:replacement)
  end

  def test_a_different_seed_changes_the_per_line_pick
    built = source("a + b + c\n")

    zero = analyze(built, seed: 0, per_line: 1)
    one = analyze(built, seed: 2, per_line: 1)

    assert_equal 1, zero.size
    assert_equal 1, one.size
    refute_equal zero.first.id, one.first.id
  end

  def test_each_is_lazy_and_matches_mutants
    built = source("a + b\nc * d\n")
    analyzer = Mutation::Analyzer.new([built], Mutation::Config.default(seed: 0))

    assert_instance_of Enumerator, analyzer.each
    assert_equal analyzer.mutants, analyzer.each.to_a
    assert_equal analyzer.mutants.map(&:id), analyzer.each.map(&:id)
  end

  def test_mutants_are_ordered_by_path_offset_and_operator
    later = source("a + b\n", "zeta.rb")
    earlier = source("c * d\ne - f\n", "alpha.rb")
    mutants = analyze([later, earlier], per_line: 99, seed: 0)

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
    assert_equal 8, analyze(built, per_line: 99).size
    assert_equal 2, analyze(built, per_line: 2, seed: 123).size
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
    replacement = Mutation::Operator::Replacement.new(original: "not the slice",
                                                      replacement: "a - b")
    analyzer = Mutation::Analyzer.new([], Mutation::Config.default(operators: []))

    error = assert_raises(Mutation::OperatorError) do
      analyzer.send(:verify!, fake, replacement, "a + b", built, node)
    end

    assert_match(/expected "a \+ b"/, error.message)
  end

  def test_empty_sources_produce_no_mutants
    assert_empty analyze([])
  end
end
