# frozen_string_literal: true

require "minitest/autorun"
require "loop"

class LoopTest < Minitest::Test
  def test_spin
    assert_equal 1, Loop.new.spin
  end
end
