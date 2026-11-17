# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class BoolTest < Minitest::Test
  include CoreTestSupport

  def test_flips_true_and_false
    text = "x = true\ny = false\n"
    built = source(text)
    true_node = built.flat_nodes.grep(Prism::TrueNode).first
    false_node = built.flat_nodes.grep(Prism::FalseNode).first

    assert_equal "false", operator(:bool).mutations(true_node, built).first.replacement
    assert_equal "true", operator(:bool).mutations(false_node, built).first.replacement

    mutants = mutants_for(built, :bool)
    assert_equal ["x = false\ny = false\n", "x = true\ny = true\n"],
                 mutants.map { |mutant| mutant.splice(text) }
    assert_mutants_parse(built, mutants)
  end
end
