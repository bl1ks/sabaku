# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ledger"

class BookkeepingTest < Minitest::Test
  def test_balance
    assert_equal 3, Bookkeeping.balance(5, 2)
  end
end
