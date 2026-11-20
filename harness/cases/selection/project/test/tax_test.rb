# frozen_string_literal: true

require "minitest/autorun"
require "tax"

class TaxTest < Minitest::Test
  # Every region, over a range of amounts: the same rate has to apply to cents
  # as to whole dollars, and the rounding has to stay within one cent.
  def test_tokyo_charges_ten_percent
    assert_equal 0.10, Cafe::Tax.rate_for("tokyo")
    assert_equal 100, Cafe::Tax.cents_for(1000, "tokyo")

    bad = []
    %w[tokyo osaka sapporo].each do |region|
      rate = Cafe::Tax.rate_for(region)
      (0..400).each do |cents|
        tax = Cafe::Tax.cents_for(cents, region)
        expected = (cents * rate).round
        bad << [region, cents, tax, expected] unless tax == expected
      end
    end
    assert_equal [], bad

    assert_equal 0.08, Cafe::Tax.rate_for("osaka")
    assert_equal 80, Cafe::Tax.cents_for(1000, "osaka")
  end

  def test_an_unknown_region_falls_back_to_the_head_office
    assert_equal 0.10, Cafe::Tax.rate_for("atlantis")
    assert_equal 33, Cafe::Tax.cents_for(333, "atlantis")
  end
end
