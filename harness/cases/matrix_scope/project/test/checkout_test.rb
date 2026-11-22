# frozen_string_literal: true

require "minitest/autorun"
require "till"

# Drives every Till method in one flow, the way a request test drives a service.
class CheckoutTest < Minitest::Test
  def test_checkout
    total = Till.total([40, 60])
    due = Till.discount(total, 10)

    assert_equal 100, total
    assert_equal 90, due
    assert_equal 10, Till.change(100, due)
    assert_equal 0, Till.change(80, due)
  end
end
