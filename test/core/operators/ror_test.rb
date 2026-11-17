# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class RorTest < Minitest::Test
  include CoreTestSupport

  TEXT = "if a >= b\n  work\nend\n"

  def setup
    @source = source(TEXT)
    @node = @source.flat_nodes.find { |node| node.is_a?(Prism::CallNode) && node.name == :>= }
  end

  def test_offers_other_relational_forms_and_boolean_literals
    replacements = operator(:ror).mutations(@node, @source)

    assert_equal 7, replacements.size
    assert_equal ["a == b", "a != b", "a > b", "a < b", "a <= b", "true", "false"],
                 replacements.map(&:replacement)
    assert(replacements.all? { |replacement| replacement.original == "a >= b" })
  end

  def test_splices_reparse_in_condition_position
    mutants = mutants_for(@source, :ror)

    assert_equal 7, mutants.size
    assert_equal "if a == b\n  work\nend\n", mutants.first.splice(TEXT)
    assert_equal "if true\n  work\nend\n", mutants[5].splice(TEXT)
    assert_mutants_parse(@source, mutants)
  end

  def test_ignores_non_relational_calls
    other = source("a + b\na && b\n")
    assert(other.flat_nodes.grep(Prism::CallNode).all? do |node|
      operator(:ror).mutations(node, other).empty?
    end)
  end
end
