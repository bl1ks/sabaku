# frozen_string_literal: true

require "minitest/autorun"

class BootedTest < Minitest::Test
  def test_value
    assert_equal 1, Booted.value
  end
end
