# frozen_string_literal: true

require "minitest/autorun"
require "till"

class TillTest < Minitest::Test
  def test_total
    assert_equal 7, Till.total([1, 2, 3], 1)
  end

  def test_total_again
    assert_equal 7, Till.total([3, 2, 1], 1)
  end

  def test_total_is_a_number
    assert_kind_of Integer, Till.total([1])
  end

  def test_discount
    assert_equal 90, Till.discount(100, 10)
  end

  def test_change
    assert_equal 5, Till.change(20, 15)
  end

  def test_no_change_when_short
    assert_equal 0, Till.change(10, 15)
  end
end
