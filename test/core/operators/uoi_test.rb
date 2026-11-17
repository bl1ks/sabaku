# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class UoiTest < Minitest::Test
  include CoreTestSupport

  def test_wraps_if_predicate
    text = "if value > 0\n  true\nend\n"
    built = source(text)
    node = built.flat_nodes.grep(Prism::IfNode).first
    replacements = operator(:uoi).mutations(node, built)

    assert_equal 1, replacements.size
    assert_equal "if !(value > 0)\n  true\nend", replacements.first.replacement
    assert_equal "if value > 0\n  true\nend", replacements.first.original
    assert_valid_ruby(replacements.first.replacement)
  end

  def test_wraps_while_until_and_unless_predicates
    text = "while running\n  tick\nend\nuntil done\n  wait\nend\nunless ready\n  poll\nend\n"
    built = source(text)
    replacements = built.flat_nodes.flat_map do |node|
      next [] unless [Prism::WhileNode, Prism::UntilNode, Prism::UnlessNode].any? { |klass| node.is_a?(klass) }

      operator(:uoi).mutations(node, built).map(&:replacement)
    end

    assert_equal ["while !(running)\n  tick\nend", "until !(done)\n  wait\nend",
                  "unless !(ready)\n  poll\nend"], replacements
    replacements.each { |replacement| assert_valid_ruby(replacement) }
  end

  def test_wraps_modifier_predicate
    text = "return 0 if items.empty?\n"
    built = source(text)
    node = built.flat_nodes.grep(Prism::IfNode).first
    replacement = operator(:uoi).mutations(node, built).first

    assert_equal "return 0 if !(items.empty?)", replacement.replacement
    assert_valid_ruby(replacement.replacement)
  end

  def test_removes_leading_negation
    text = "!ready\nnot ready\n"
    built = source(text)
    call_nodes = built.flat_nodes.select { |node| node.is_a?(Prism::CallNode) && node.name == :! }

    assert_equal 2, call_nodes.size
    actual = call_nodes.map do |node|
      replacement = operator(:uoi).mutations(node, built).first
      [replacement.original, replacement.replacement]
    end
    assert_equal [["!ready", "ready"], ["not ready", "ready"]], actual
    call_nodes.each do |node|
      assert_valid_ruby("x = #{operator(:uoi).mutations(node, built).first.replacement}")
    end
  end

  def test_splice_of_condition_mutant_keeps_the_body
    text = "if a && b\n  one\n  two\nend\n"
    built = source(text)
    mutants = mutants_for(built, :uoi)

    assert_equal "if !(a && b)\n  one\n  two\nend\n", mutants.first.splice(text)
    assert_mutants_parse(built, mutants)
  end

  def test_ignores_plain_calls
    built = source("value.empty?\n")
    call = built.flat_nodes.grep(Prism::CallNode).first
    assert_empty operator(:uoi).mutations(call, built)
  end
end
