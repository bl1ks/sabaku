# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class StrTest < Minitest::Test
  include CoreTestSupport

  def test_replaces_non_empty_literal_with_empty_string
    text = "x = \"hello\"\n"
    built = source(text)
    node = built.flat_nodes.grep(Prism::StringNode).first

    replacement = operator(:str).mutations(node, built).first
    assert_equal "\"hello\"", replacement.original
    assert_equal "\"\"", replacement.replacement

    mutant = mutants_for(built, :str).first
    assert_equal "x = \"\"\n", mutant.splice(text)
    assert_valid_ruby(mutant.splice(text))
  end

  def test_skips_empty_literals
    built = source("x = \"\"\n")
    assert_empty mutants_for(built, :str)
  end

  def test_skips_heredocs_and_interpolated_parts
    heredoc = source("x = <<~TEXT\n  hi\nTEXT\n")
    interpolated = source(%q{x = "a#{b}c"})

    assert_empty mutants_for(heredoc, :str)
    assert_empty mutants_for(interpolated, :str)
  end
end
