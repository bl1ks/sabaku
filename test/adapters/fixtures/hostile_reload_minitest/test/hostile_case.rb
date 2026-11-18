# frozen_string_literal: true

require "minitest/autorun"
require "hostile"

class HostileTest < Minitest::Test
  def test_value
    assert_equal 42, Hostile.value
  end
end
