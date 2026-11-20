# frozen_string_literal: true

require "minitest/autorun"
require "billing"

class RefundTest < Minitest::Test
  def test_charges_the_fee_below_the_tier
    assert_equal 5, Billing::Refund.new(10).handling_fee
  end

  def test_waives_the_fee_above_the_tier
    assert_equal 0, Billing::Refund.new(120).handling_fee
  end
end
