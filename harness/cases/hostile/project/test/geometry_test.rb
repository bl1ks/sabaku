# frozen_string_literal: true

require "minitest/autorun"
require "hostile/geometry"

class HostileGeometryTest < Minitest::Test
  def test_move_adds_the_delta
    point = Hostile::Point.new(1, 2).move(3, 4)
    assert_equal [4, 6], [point.x, point.y]
  end

  def test_manhattan_sums_the_absolute_members
    assert_equal 7, Hostile::Point.new(-3, 4).manhattan
  end

  def test_distance_uses_both_axes
    assert_equal 5.0, Hostile::Geometry.distance(Hostile::Point.new(0, 0), Hostile::Point.new(3, 4))
  end

  def test_inside_is_inclusive_at_the_limit
    assert Hostile::Geometry.inside?(Hostile::Point.new(1, 1), 2)
    refute Hostile::Geometry.inside?(Hostile::Point.new(2, 2), 3)
  end

  def test_origin_is_the_zero_point
    origin = Hostile::Geometry::ORIGIN
    assert_equal [0, 0], [origin.x, origin.y]
  end
end
