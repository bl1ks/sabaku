# frozen_string_literal: true

require "minitest/autorun"
require "loyalty"

class LoyaltyTest < Minitest::Test
  def test_points_accrue_per_hundred_cents
    assert_equal 10, Cafe::Loyalty.new(5).earn(543)
    assert_equal 17, Cafe::Loyalty.new(5).earn(1200)
    assert_equal 29, Cafe::Loyalty.new(5, tier: :gold).earn(1200)
  end

  def test_points_are_worth_five_cents_each
    card = Cafe::Loyalty.new(40)
    assert_equal 200, card.value_cents
    assert_equal 40, card.points
  end
end
