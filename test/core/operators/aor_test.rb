# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class AorTest < Minitest::Test
  include CoreTestSupport

  TEXT = "total = price * 0.15\n"

  def setup
    @source = source(TEXT)
    @node = @source.flat_nodes.find { |node| node.is_a?(Prism::CallNode) && node.name == :* }
  end

  def test_offers_every_other_arithmetic_operator
    replacements = operator(:aor).mutations(@node, @source)

    assert_equal 4, replacements.size
    assert_equal ["price + 0.15", "price - 0.15", "price / 0.15", "price % 0.15"],
                 replacements.map(&:replacement)
    assert(replacements.all? { |replacement| replacement.original == "price * 0.15" })
  end

  def test_splice_rewrites_only_the_operator_token
    mutants = mutants_for(@source, :aor)
    assert_equal ["total = price + 0.15\n", "total = price - 0.15\n",
                  "total = price / 0.15\n", "total = price % 0.15\n"],
                 mutants.map { |mutant| mutant.splice(TEXT) }
    assert_mutants_parse(@source, mutants)
  end

  def test_ignores_non_binary_and_non_arithmetic_calls
    other = source("x = -value\nx.size\na && b\n")
    call_nodes = other.flat_nodes.grep(Prism::CallNode)
    assert_empty call_nodes.flat_map { |node| operator(:aor).mutations(node, other) }
  end
end
