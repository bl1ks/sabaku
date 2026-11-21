# frozen_string_literal: true

require "minitest/autorun"
require "load_counter"

class LoadCounterTest < Minitest::Test
  def test_a_value
    assert_equal 42, LoadCounter.value
  end

  def test_b_loaded_once
    assert_equal 1, LoadCounter.loads
  end
end
