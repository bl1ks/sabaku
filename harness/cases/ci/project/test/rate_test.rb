# frozen_string_literal: true

require "minitest/autorun"
require "shipping"

class RateTest < Minitest::Test
  def test_charges_the_light_rate_below_the_tier
    assert_equal 540, Shipping::Rate.new.cost(2)
  end

  def test_free_for_a_non_positive_weight
    assert_equal 0, Shipping::Rate.new.cost(-1)
  end

  def test_bulk_charges_the_light_rate
    assert_equal 40, Shipping::Rate.new.bulk(2)
  end
end
