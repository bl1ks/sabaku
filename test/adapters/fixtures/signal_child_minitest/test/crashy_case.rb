# frozen_string_literal: true

require "minitest/autorun"
require "crashy"

class CrashyTest < Minitest::Test
  def test_value
    # A native extension that segfaults, or the OOM killer, ends the child with a
    # signal long before its deadline.
    Process.kill(:KILL, Process.pid) if Crashy.value.zero?
    assert_equal 1, Crashy.value
  end
end
