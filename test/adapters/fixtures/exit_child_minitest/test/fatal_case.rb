# frozen_string_literal: true

require "minitest/autorun"
require "fatal"

class FatalTest < Minitest::Test
  def test_value
    # A test helper that ends the process on failure (Active Support's
    # parallelization and isolation helpers call exit!) leaves no summary
    # behind. The exit status is the only evidence the suite stopped.
    Process.exit!(1) if Fatal.value.zero?
    assert_equal 1, Fatal.value
  end
end
