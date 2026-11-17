# frozen_string_literal: true

require "test_helper"

class PricingTest < ActiveSupport::TestCase
  test "five is bulk" do
    assert_equal :bulk, Pricing.new.tier(5)
  end

  test "four is single" do
    assert_equal :single, Pricing.new.tier(4)
  end

  test "eleven is a bulk label" do
    assert_equal "bulk", Pricing.new.label(11)
  end

  test "five is a single label" do
    assert_equal "single", Pricing.new.label(5)
  end
end
