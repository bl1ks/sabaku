# frozen_string_literal: true

require "minitest/autorun"
require "odd"

# Active Support's isolation helper overrides `run` to fork the test, so a
# project can legitimately return something that is not a Minitest::Result.
class OddRunTest < Minitest::Test
  def run
    return "redirected" if Odd.value.zero?

    super
  end

  def test_value
    assert_equal 1, Odd.value
  end
end
