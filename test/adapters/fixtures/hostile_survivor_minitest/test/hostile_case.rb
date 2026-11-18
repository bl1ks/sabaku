# frozen_string_literal: true

require "minitest/autorun"
require "hostile"

class HostileTest < Minitest::Test
  def test_value
    assert_equal 1, Hostile.loads, "the file must be loaded exactly once"
    assert_operator Hostile.value, :>, 0
  end
end
