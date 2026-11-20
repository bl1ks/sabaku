# frozen_string_literal: true

require "minitest/autorun"
require "units"

class UnitsTest < Minitest::Test
  def test_a_dozen_is_twelve
    assert_equal 36, Cafe::Units.dozens(3)
  end

  # Whole packs, checked as an invariant over a range: never short, never a
  # spare pack.
  def test_packs_round_up_and_respect_an_exact_multiple
    assert_equal 2, Cafe::Units.packs(13, 12)
    assert_equal 2, Cafe::Units.packs(24, 12)

    bad = []
    (1..400).each do |count|
      [4, 6, 12].each do |per_pack|
        packs = Cafe::Units.packs(count, per_pack)
        next if packs * per_pack >= count && (packs - 1) * per_pack < count

        bad << [count, per_pack]
      end
    end
    assert_equal [], bad
  end

  def test_grams_become_kilograms
    assert_equal 2.5, Cafe::Units.grams_to_kg(2500)
  end
end
