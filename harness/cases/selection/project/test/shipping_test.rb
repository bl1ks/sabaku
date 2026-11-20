# frozen_string_literal: true

require "minitest/autorun"
require "shipping"

class ShippingTest < Minitest::Test
  def test_pickup_is_free
    assert_equal 0, Cafe::Shipping.cents_for(zone: "pickup", grams: 2000, subtotal_cents: 3000)
  end

  def test_a_large_order_ships_free
    assert_equal 0, Cafe::Shipping.cents_for(zone: "local", grams: 2000, subtotal_cents: 12_000)
  end

  # Every zone over every half kilogram: the base rate plus a whole-kilogram
  # surcharge, and pickup never pays either.
  def test_a_surcharge_follows_the_weight
    assert_equal 640, Cafe::Shipping.cents_for(zone: "local", grams: 2500, subtotal_cents: 3000)

    bad = []
    Cafe::Shipping::ZONES.each_key do |zone|
      (0..20).each do |half_kilos|
        grams = half_kilos * 500
        cents = Cafe::Shipping.cents_for(zone: zone, grams: grams, subtotal_cents: 3000)
        base = Cafe::Shipping.base_cents(zone)
        expected = base.zero? ? 0 : base + ((grams / 1000) * Cafe::Shipping::PER_KG_CENTS)
        bad << [zone, grams, cents, expected] unless cents == expected
      end
    end
    assert_equal [], bad
  end

  def test_an_unknown_zone_defaults_to_kanto
    assert_equal 600, Cafe::Shipping.cents_for(zone: "atlantis", grams: 500, subtotal_cents: 3000)
  end
end
