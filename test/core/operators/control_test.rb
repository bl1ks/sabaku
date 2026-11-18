# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class ControlTest < Minitest::Test
  include CoreTestSupport

  def test_break_and_next_swap
    text = "[1, 2].each do |x|\n  break if x == 2\nend\n"
    built = source(text)

    assert_equal "[1, 2].each do |x|\n  next if x == 2\nend\n",
                 mutants_for(built, :control).first.splice(text)
    assert_valid_ruby(mutants_for(built, :control).first.splice(text))
  end

  def test_next_becomes_break
    text = "[1].each do |x|\n  next x\nend\n"

    assert_equal "[1].each do |x|\n  break\nend\n",
                 mutants_for(source(text), :control).first.splice(text)
  end
end
