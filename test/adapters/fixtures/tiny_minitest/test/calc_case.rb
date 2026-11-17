# frozen_string_literal: true

require "minitest/autorun"
require "calc"

class CalcTest < Minitest::Test
  def test_add
    assert_equal 5, Calc.new.add(2, 3)
  end
end
