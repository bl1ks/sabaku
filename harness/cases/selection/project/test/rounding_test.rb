# frozen_string_literal: true

require "minitest/autorun"
require "rounding"

class RoundingTest < Minitest::Test
  # Every amount in the range has to land on the five cent step and stay
  # within two cents of where it started.
  def test_a_total_rounds_to_the_five_cent_step
    assert_equal 1235, Cafe::Rounding.to_step(1233)

    bad = []
    (0..4000).each do |cents|
      rounded = Cafe::Rounding.to_step(cents)
      bad << [cents, rounded] unless (rounded % 5).zero? && (rounded - cents).abs <= 2
    end
    assert_equal [], bad
  end

  def test_a_total_already_on_the_step_is_unchanged
    assert_equal 1235, Cafe::Rounding.to_step(1235)
    assert_equal 1235, Cafe::Rounding.to_step(1236)
  end

  def test_a_step_of_one_is_the_identity
    assert_equal 1233, Cafe::Rounding.to_step(1233, 1)
    assert_equal 1235, Cafe::Rounding.cash_total(1237)
  end
end
