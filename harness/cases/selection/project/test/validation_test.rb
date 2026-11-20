# frozen_string_literal: true

require "minitest/autorun"
require "validation"

class ValidationTest < Minitest::Test
  def test_a_plain_order_is_valid
    order = Cafe::Order.new(items: [Cafe::LineItem.new("espresso", 2)])
    assert_equal [], Cafe::Validation.errors(order)
    assert Cafe::Validation.valid?(order)
  end

  def test_an_empty_order_is_rejected
    order = Cafe::Order.new(items: [])
    assert_equal ["empty order"], Cafe::Validation.errors(order)
  end

  def test_unknown_products_and_bad_quantities_are_named
    order = Cafe::Order.new(items: [Cafe::LineItem.new("tea", 1),
                                    Cafe::LineItem.new("espresso", 0)])
    assert_equal ["unknown product tea", "bad quantity 0"], Cafe::Validation.errors(order)
  end

  # One error per offending line, at scale: every item of a long order is
  # checked, and the count limit is a separate reason.
  def test_more_than_two_hundred_units_is_rejected
    order = Cafe::Order.new(items: [Cafe::LineItem.new("espresso", 201)])
    assert_equal ["too many units"], Cafe::Validation.errors(order)

    long = Cafe::Order.new(items: (0...150).map { Cafe::LineItem.new("espresso", 1) })
    assert_equal [], Cafe::Validation.errors(long)
    assert_equal 150, long.units
  end
end
