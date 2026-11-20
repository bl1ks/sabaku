# frozen_string_literal: true

require "minitest/autorun"
require "billing"

class AmountTest < Minitest::Test
  def test_subtracts_the_fee_from_a_small_refund
    assert_equal 5, Billing::Refund.new(10).amount
  end

  def test_refuses_a_refund_the_cap_rejects
    assert_equal 0, Billing::Refund.new(-1).amount
  end
end
