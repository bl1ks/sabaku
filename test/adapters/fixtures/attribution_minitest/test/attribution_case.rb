# frozen_string_literal: true

require "minitest/autorun"
require "eager"
require "contract"

class AttributionTest < Minitest::Test
  def test_contract
    assert_equal 10, Contract.limit
  end

  def test_check
    assert Eager.check(1)
  end

  def test_lazy
    require "lazy"
    assert_equal 2, Lazy.value
  end
end
