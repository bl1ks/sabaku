# frozen_string_literal: true

require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_version_is_a_string
    assert_match(/\A\d+\.\d+\.\d+\z/, Sabaku::VERSION)
  end
end
