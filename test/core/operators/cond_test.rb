# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class CondTest < Minitest::Test
  include CoreTestSupport

  def replacements(text)
    built = source(text)
    mutants_for(built, :cond).map { |mutant| mutant.splice(text) }
  end

  def test_if_predicate_becomes_true_and_false
    assert_equal ["if false\n  a\nend\n", "if true\n  a\nend\n"], replacements("if b\n  a\nend\n").sort
  end

  def test_unless_predicate_becomes_true_and_false
    assert_equal ["unless false\n  a\nend\n", "unless true\n  a\nend\n"],
                 replacements("unless b\n  a\nend\n").sort
  end

  def test_loops_are_left_alone_because_they_would_time_out
    assert_empty replacements("while b\n  a\nend\n")
  end
end
