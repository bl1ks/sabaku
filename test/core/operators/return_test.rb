# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class ReturnTest < Minitest::Test
  include CoreTestSupport

  def test_last_expression_becomes_nil
    text = "def value\n  compute\nend\n"
    built = source(text)

    mutant = mutants_for(built, :return).first

    assert_equal "def value\n  nil\nend\n", mutant.splice(text)
    assert_equal 2, mutant.line
  end

  def test_the_reported_line_is_the_expression_not_the_def
    built = source("def value\n  a = 1\n  a + 2\nend\n")

    assert_equal 3, mutants_for(built, :return).first.line
  end

  def test_side_effects_before_the_return_value_stay
    text = "def save(record)\n  record.write\n  record.id\nend\n"

    assert_equal "def save(record)\n  record.write\n  nil\nend\n",
                 mutants_for(source(text), :return).first.splice(text)
  end

  def test_empty_and_rescue_bodies_are_skipped
    assert_empty mutants_for(source("def empty; end\n"), :return)
    assert_empty mutants_for(source("def risky\n  work\nrescue\n  fallback\nend\n"), :return)
  end

  def test_a_trailing_nil_is_not_mutated
    assert_empty mutants_for(source("def nothing\n  nil\nend\n"), :return)
  end

  def test_heredoc_returns_are_skipped
    text = "def sql\n  <<~SQL\n    select 1\n  SQL\nend\n"

    assert_empty mutants_for(source(text), :return)
  end

  def test_suppressed_definitions_are_not_mutated
    assert_empty mutants_for(source("def inspect\n  @name\nend\n"), :return)
  end
end
