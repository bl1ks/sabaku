# frozen_string_literal: true

# A test helper that requires minitest but not minitest/spec, which is what a
# Rails test_helper does. Minitest::Spec is therefore undefined at preload.
require "minitest"

class HiddenCaseTest < Minitest::Test
  def test_value
    assert_equal 1, 1
  end
end
