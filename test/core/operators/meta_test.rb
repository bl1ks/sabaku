# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

# Operator meta examples: the input, the operator, and the exact rewrites that
# operator must offer. Adding an operator means adding rows here, and changing
# one means the row is the review. The corpus test at the bottom is the other
# half: every candidate the whole catalog produces for this library's own source
# must still parse, which is the failure mode a table cannot enumerate.
class OperatorMetaTest < Minitest::Test
  include CoreTestSupport

  EXAMPLES = [
    ["a + b\n", :aor, ["a - b\n", "a * b\n", "a / b\n", "a % b\n"]],
    ["a == b\n", :ror, ["a != b\n", "a > b\n", "a >= b\n", "a < b\n", "a <= b\n", "true\n", "false\n"]],
    ["a && b\n", :lcr, ["a\n", "b\n", "a || b\n", "true\n", "false\n"]],
    ["if flag\n  work\nend\n", :uoi, ["if !(flag)\n  work\nend\n"]],
    ["if flag\n  work\nend\n", :cond, ["if true\n  work\nend\n", "if false\n  work\nend\n"]],
    # The predicate of a modifier `if` is the whole parenthesised expression, so a
    # rewrite has to stay inside the parentheses or the keyword fuses with it.
    ["return 1 if(x > 0)\n", :cond, ["return 1 if(true)\n", "return 1 if(false)\n"]],
    ["return 1 if(x > 0)\n", :uoi, ["return 1 if(!(x > 0))\n"]],
    ["unless(x)\n  work\nend\n", :cond, ["unless(true)\n  work\nend\n", "unless(false)\n  work\nend\n"]],
    ["while(x > 0)\n  work\nend\n", :uoi, ["while(!(x > 0))\n  work\nend\n"]],
    ["x = 1\n", :literal, ["x = 2\n", "x = 0\n"]],
    ["xs.map { |x| x }\n", :selector, ["xs.each { |x| x }\n"]],
    ["x += 1\n", :assign, ["x = 1\n"]],
    ["def f\n  compute\nend\n", :return, ["def f\n  nil\nend\n"]],
    ["[1].each do |x|\n  next x\nend\n", :control, ["[1].each do |x|\n  break\nend\n"]],
    ["\n  one\n  two\n  three\n", :sbr, []]
  ].freeze

  def test_each_meta_example_produces_exactly_the_listed_rewrites
    EXAMPLES.each do |text, operator_id, expected|
      built = source(text)
      actual = mutants_for(built, operator_id).map { |mutant| mutant.splice(text) }.uniq
      expected = expected.uniq
      next if expected.empty? # SBR's fixture is exercised in its own test file.

      assert_equal expected.sort, actual.sort, "meta example for #{operator_id} drifted"
    end
  end

  def test_every_operator_handles_only_prism_nodes
    Sabaku::Operator::Registry.all.each do |operator|
      refute_empty operator.node_types, "#{operator.id} declares no node types"
      operator.node_types.each do |node_class|
        assert_operator node_class, :<, Prism::Node, "#{operator.id} declared #{node_class}"
      end
    end
  end

  def test_no_operator_offers_a_rewrite_that_changes_nothing
    Sabaku::Operator::Registry.all.each do |operator|
      built = source("x = thing(a, b)\nif x && y\n  xs.map { |v| v }\nend\n")
      mutants_for(built, operator.id).each do |mutant|
        refute_equal mutant.original, mutant.replacement,
                     "#{operator.id} offered a no-op on #{mutant.original.inspect}"
      end
    end
  end

  # This library's own source is the corpus. It is small enough to run on every
  # suite invocation and broad enough that a rewriting bug shows up as a syntax
  # error instead of a silent survivor in a campaign.
  def test_every_candidate_for_the_library_source_parses
    root = File.expand_path("../../..", __dir__)
    files = Dir[File.join(root, "lib/**/*.rb")].sort
    refute_empty files

    sources = files.map do |file|
      Sabaku::Source.new(file.delete_prefix("#{root}/"), File.read(file))
    end
    mutants = Sabaku::Analyzer.new(
      sources, Sabaku::Config.default(per_line: :all, operators: Sabaku::Operator::Registry.ids)
    ).mutants
    by_path = sources.to_h { |entry| [entry.rel_path, entry] }

    refute_empty mutants
    failures = mutants.filter_map do |mutant|
      spliced = mutant.splice(by_path.fetch(mutant.path).text)
      errors = Prism.parse(spliced).errors
      next if errors.empty?

      "#{mutant.path}:#{mutant.line} #{mutant.operator} #{errors.first.message}"
    end
    assert_empty failures.first(5), "#{failures.size} candidates did not parse"
  end
end
