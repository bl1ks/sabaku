# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class LcrTest < Minitest::Test
  include CoreTestSupport

  TEXT = "if foo(1) && bar(2)\n  work\nend\n"

  def setup
    @source = source(TEXT)
    @node = @source.flat_nodes.find { |node| node.is_a?(Prism::AndNode) }
  end

  def test_offers_operands_other_connector_and_booleans
    replacements = operator(:lcr).mutations(@node, @source)

    assert_equal 5, replacements.size
    assert_equal ["foo(1)", "bar(2)", "foo(1) || bar(2)", "true", "false"],
                 replacements.map(&:replacement)
    assert(replacements.all? { |replacement| replacement.original == "foo(1) && bar(2)" })
  end

  def test_splice_uses_exact_operand_slices
    mutants = mutants_for(@source, :lcr)

    assert_equal "if foo(1)\n  work\nend\n", mutants[0].splice(TEXT)
    assert_equal "if bar(2)\n  work\nend\n", mutants[1].splice(TEXT)
    assert_equal "if foo(1) || bar(2)\n  work\nend\n", mutants[2].splice(TEXT)
    assert_mutants_parse(@source, mutants)
  end

  def test_keyword_and_or_connectors_stay_keywords
    keyword = source("a and b\na or b\n")
    and_node = keyword.flat_nodes.grep(Prism::AndNode).first
    or_node = keyword.flat_nodes.grep(Prism::OrNode).first

    assert_includes operator(:lcr).mutations(and_node, keyword).map(&:replacement), "a or b"
    assert_includes operator(:lcr).mutations(or_node, keyword).map(&:replacement), "a and b"
  end

  def test_call_connectors_are_supported
    other = source("foo(1) & bar(2)\n")
    call = other.flat_nodes.find { |node| node.is_a?(Prism::CallNode) && node.name == :& }
    replacements = operator(:lcr).mutations(call, other)

    assert_equal ["foo(1)", "bar(2)", "foo(1) | bar(2)", "true", "false"],
                 replacements.map(&:replacement)
  end
end
