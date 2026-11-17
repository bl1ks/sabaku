# frozen_string_literal: true

require "minitest/autorun"
require "chain"

class ChainTest < Minitest::Test
  def test_open_when_positive_even_and_allowed
    assert Chain::Gate.new(4).open?
  end

  def test_closed_when_negative
    refute Chain::Gate.new(-1).open?
  end

  def test_closed_when_odd
    refute Chain::Gate.new(3).open?
  end
end
