# frozen_string_literal: true

require "minitest/autorun"
require "thing"

class ThingTest < Minitest::Test
  def test_broken
    assert_equal 2, Thing.new.value
  end

  def test_value
    assert_equal 1, Thing.new.value
  end
end
