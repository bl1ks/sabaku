# frozen_string_literal: true

require "minitest/autorun"
require "discount"

class DiscountTest < Minitest::Test
  def test_no_volume_discount_below_a_dozen
    assert_equal 0, Cafe::Discount.volume_percent(11)
  end

  # The tiers are checked across the whole range, not at three points: a unit
  # count must map to exactly one of the three rates.
  def test_five_percent_starts_at_a_dozen
    assert_equal 5, Cafe::Discount.volume_percent(12)
    assert_equal 5, Cafe::Discount.volume_percent(47)

    bad = []
    (0..240).each do |units|
      percent = Cafe::Discount.volume_percent(units)
      expected = if units < 12
                   0
                 elsif units < 48
                   5
                 else
                   10
                 end
      bad << [units, percent, expected] unless percent == expected
    end
    assert_equal [], bad
  end

  def test_ten_percent_starts_at_four_dozen
    assert_equal 10, Cafe::Discount.volume_percent(48)
    assert_equal 10, Cafe::Discount.volume_percent(60)
  end

  def test_coupons_are_case_insensitive_and_unknown_codes_are_zero
    assert_equal 10, Cafe::Discount.coupon_percent("beans10")
    assert_equal 15, Cafe::Discount.coupon_percent("OPENING")
    assert_equal 0, Cafe::Discount.coupon_percent("nope")
    assert_equal 0, Cafe::Discount.coupon_percent(nil)
  end

  def test_a_percentage_becomes_cents_and_rounds
    assert_equal 100, Cafe::Discount.cents_for(1000, 10)
    assert_equal 50, Cafe::Discount.cents_for(999, 5)
  end
end
