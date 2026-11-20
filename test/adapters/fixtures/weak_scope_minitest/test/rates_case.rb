# frozen_string_literal: true

require "minitest/autorun"
require "rates"

class RatesTest < Minitest::Test
  def test_scaled
    assert_equal 6, Rates.new.scaled(2, 3)
  end

  def test_label
    assert_equal "rates", Rates.new.label
  end
end
