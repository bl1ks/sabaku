# frozen_string_literal: true

require "minitest/autorun"
require "pricing"

# Deliberately weak in places: the volume tiers, the free gift condition and the
# empty-cart discount guard are barely asserted, so mutants survive. That is the point.
class PricingTest < Minitest::Test
  def setup
    @shop = Shop::Pricing.new([{ price: 10.0, quantity: 2 }, { price: 5.0, quantity: 1 }])
  end

  def test_subtotal
    assert_equal 25.0, @shop.subtotal
  end

  def test_tax
    assert_in_delta 2.5, @shop.tax, 0.01
  end

  def test_shipping_under_threshold
    assert_in_delta 4.95, @shop.shipping, 0.01
  end

  def test_total
    assert_in_delta 32.45, @shop.total, 0.01
  end

  def test_discount_for_bulk_order
    bulk = Shop::Pricing.new([{ price: 10.0, quantity: 10 }])
    assert_in_delta 15.0, bulk.discount, 0.01
  end

  def test_empty_cart
    assert_equal 0, Shop::Pricing.new.subtotal
  end
end
