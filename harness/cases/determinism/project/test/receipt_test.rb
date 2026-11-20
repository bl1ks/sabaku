# frozen_string_literal: true

require "minitest/autorun"
require "billing"

class ReceiptTest < Minitest::Test
  def test_names_the_total_it_was_built_with
    assert_includes Billing::Refund.new(10).receipt, "total=10"
  end

  def test_reports_a_large_refund_without_a_fee
    assert_equal "total=120 fee=0 refund=120", Billing::Refund.new(120).receipt
  end
end
