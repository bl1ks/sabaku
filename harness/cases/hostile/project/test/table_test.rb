# frozen_string_literal: true

require "minitest/autorun"
require "hostile"

class HostileTableTest < Minitest::Test
  def test_lookup_is_the_fetched_value
    assert_equal 1, Hostile::Table.value
    assert_equal 1, Hostile::Table::Lookup
  end

  def test_describe_adds_one
    assert_equal 2, Hostile::Table.describe
  end
end
