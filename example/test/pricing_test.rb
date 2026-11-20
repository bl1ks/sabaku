# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/pricing"

class PricingTest < Minitest::Test
  def test_total_below_the_bulk_threshold
    assert_equal 620, Shop::Pricing.new([300, 320]).total
  end

  def test_total_above_the_bulk_threshold_is_cheaper
    assert_operator Shop::Pricing.new([1_500]).total, :<, 1_500
  end
end
