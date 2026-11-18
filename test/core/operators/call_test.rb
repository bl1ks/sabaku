# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class CallTest < Minitest::Test
  include CoreTestSupport

  def replacements(text)
    built = source(text)
    mutants_for(built, :call).map { |mutant| mutant.splice(text) }
  end

  def test_receiver_removal_leaves_the_receiver_expression
    assert_includes replacements("x.first\n"), "x\n"
  end

  def test_naked_selector_sends_to_self
    assert_includes replacements("x.first\n"), "first\n"
  end

  def test_argument_deletion_and_nil_substitution
    text = "f(a, b)\n"
    assert_includes replacements(text), "f\n"
    assert_includes replacements(text), "f(a)\n"
    assert_includes replacements(text), "f(b)\n"
    assert_includes replacements(text), "f(nil, b)\n"
    assert_includes replacements(text), "f(a, nil)\n"
  end

  def test_a_single_argument_takes_the_call_place
    assert_includes replacements("sanitize(value)\n"), "value\n"
    assert_empty replacements("sanitize(a, b)\n").select { |result| result == "a\n" }
  end

  def test_argument_propagation_is_skipped_when_a_block_is_attached
    refute_includes replacements("each(value) { |v| v }\n"), "value\n"
  end

  def test_keyword_messages_never_go_naked
    assert_empty replacements("x.class\n").select { |text| text.strip == "class" }
  end

  def test_heredoc_arguments_are_left_alone
    text = "f(<<~SQL, 1)\n  select 1\nSQL\n"

    assert_empty replacements(text).select { |result| result.include?("<<~SQL") }
  end

  def test_safe_navigation_and_missing_nodes_are_skipped
    assert_empty replacements("a&.foo\n")
    assert_empty replacements("f(\n")
  end

  def test_every_replacement_parses
    sources = [
      "x.slice(1, 2) { |v| v }\n",
      "foo(bar)\n",
      "self.call(a: 1, b: 2)\n",
      "obj.method do |x|\n  x\nend\n"
    ]
    sources.each do |text|
      built = source(text)
      assert_mutants_parse(built, mutants_for(built, :call))
    end
  end
end
