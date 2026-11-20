# frozen_string_literal: true

require "minitest/autorun"
require "order"

class OrderTest < Minitest::Test
  def test_subtotal_and_units_sum_the_items
    order = Cafe::Order.new(
      items: [Cafe::LineItem.new("espresso", 2), Cafe::LineItem.new("pastry-box", 1)]
    )
    assert_equal 2140, order.subtotal_cents
    assert_equal 3, order.units
  end

  def test_a_dozen_items_earn_the_five_percent_tier
    order = Cafe::Order.new(items: [Cafe::LineItem.new("espresso", 12)])
    assert_equal 5, order.discount_percent
    assert_equal 192, order.discount_cents
    assert_equal 3648, order.taxable_cents
  end

  def test_a_coupon_beats_the_volume_tier
    order = Cafe::Order.new(items: [Cafe::LineItem.new("espresso", 12)], coupon: "BEANS10")
    assert_equal 10, order.discount_percent
    assert_equal 384, order.discount_cents
  end

  # A deterministic book of small orders, each within the free shipping
  # threshold, so the invariant is the total and not a hardcoded number.
  def test_tax_and_shipping_add_to_the_total
    order = Cafe::Order.new(items: [Cafe::LineItem.new("espresso", 2)], grams: 2000)
    assert_equal 64, order.tax_cents
    assert_equal 640, order.shipping_cents
    assert_equal 1344, order.total_cents

    codes = %w[espresso filter oat-milk]
    bad = []
    (0...120).each do |index|
      items = (0...10).map do |slot|
        Cafe::LineItem.new(codes[(index + slot) % codes.size], 1 + ((index + slot) % 3))
      end
      book = Cafe::Order.new(items: items, zone: %w[pickup local kanto][index % 3],
                             region: %w[tokyo osaka][index % 2], grams: (index % 8) * 500)
      parts = book.taxable_cents + book.tax_cents + book.shipping_cents
      bad << index unless book.total_cents == parts
      bad << index unless book.total.to_s.match?(/\A\$/)
    end
    assert_equal [], bad
  end

  def test_the_total_is_a_money_value
    order = Cafe::Order.new(items: [Cafe::LineItem.new("espresso", 1)], zone: "pickup",
                            coupon: "opening")
    assert_equal 299, order.total_cents
    assert_equal "$2.99", order.total.to_s
  end
end
