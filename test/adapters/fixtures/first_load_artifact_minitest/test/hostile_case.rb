# frozen_string_literal: true

require "minitest/autorun"
require "hostile"

class HostileTest < Minitest::Test
  def test_value
    # The fork parent loaded the file once before forking, so a fork child sees
    # two loads and a first-load child sees one. The test passes only on the
    # fork surface, so a kill here is the surface's, not the mutation's.
    assert_equal 2, Hostile.loads
    assert_equal 42, Hostile.value
  end
end
