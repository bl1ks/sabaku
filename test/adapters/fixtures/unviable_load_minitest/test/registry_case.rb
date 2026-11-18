# frozen_string_literal: true

require "minitest/autorun"
require "registry"

class RegistryTest < Minitest::Test
  def test_find
    assert_equal 42, Registry.find("answer")
  end
end
