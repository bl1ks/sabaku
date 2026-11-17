# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class AssignTest < Minitest::Test
  include CoreTestSupport

  def replacements(text)
    built = source(text)
    mutants_for(built, :assign).map { |mutant| mutant.splice(text) }
  end

  def test_compound_assignment_becomes_plain_assignment
    assert_equal ["x = 1\n"], replacements("x += 1\n")
    assert_equal ["@x = 1\n"], replacements("@x *= 1\n")
    assert_equal ["x = 1\n"], replacements("x ||= 1\n")
    assert_equal ["x = 1\n"], replacements("x &&= 1\n")
  end

  def test_every_write_target_is_covered
    %w[@a $g A::B].push("h[:k]", "obj.attr").each do |target|
      text = "#{target} += 1\n"
      assert_equal ["#{target} = 1\n"], replacements(text), "target #{target}"
    end
  end

  def test_plain_assignment_is_not_mutated
    assert_empty replacements("x = 1\n")
  end
end
