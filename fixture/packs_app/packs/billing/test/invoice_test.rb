# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/invoice"

class InvoiceTest < Minitest::Test
  def test_payable_when_covered
    assert Invoice.payable?(5, 5)
  end

  def test_not_payable_when_overdrawn
    refute Invoice.payable?(1, 5)
  end
end
