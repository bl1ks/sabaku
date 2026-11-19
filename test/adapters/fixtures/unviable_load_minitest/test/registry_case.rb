# frozen_string_literal: true

require "minitest/autorun"
require "registry"

class UnviableRegistryTest < Minitest::Test
  def test_find
    assert_equal 42, Registry.find("answer")
  end
end
