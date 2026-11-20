# frozen_string_literal: true

require "minitest/autorun"
require "money"

class MoneyTest < Minitest::Test
  def test_from_dollars_rounds_to_cents
    assert_equal 325, Cafe::Money.from_dollars(3.25).cents
  end

  def test_addition_and_subtraction_stay_in_cents
    five = Cafe::Money.new(500)
    one_twenty_five = Cafe::Money.new(125)
    assert_equal 625, (five + one_twenty_five).cents
    assert_equal 375, (five - one_twenty_five).cents
  end

  def test_scaling_rounds_to_the_nearest_cent
    assert_equal 500, (Cafe::Money.new(333) * 1.5).cents
  end

  # A sweep rather than three examples: every cent amount in the range has to
  # print with a sign only when negative and exactly two decimals.
  def test_formatting_carries_the_sign_and_two_decimals
    assert_equal "$12.34", Cafe::Money.new(1234).to_s
    assert_equal "-$0.05", Cafe::Money.new(-5).to_s
    assert Cafe::Money.new(0).zero?

    bad = []
    (-1500..1500).each do |cents|
      text = Cafe::Money.new(cents).to_s
      bad << [cents, text] unless text.match?(/\A-?\$\d+\.\d{2}\z/)
    end
    assert_equal [], bad
  end
end
