# frozen_string_literal: true

module Hostile
  # A value object built from Struct. This file is load-sensitive: re-executing it builds a
  # fresh class object, which is exactly what fork isolation does to apply a mutant, so every
  # kill from here is checked against a reload with no mutation applied.
  Point = Struct.new(:x, :y) do
    def move(dx, dy)
      Point.new(x + dx, y + dy)
    end

    def manhattan
      x.abs + y.abs
    end
  end

  module Geometry
    ORIGIN = Point.new(0, 0)

    def self.distance(a, b)
      Math.sqrt(((a.x - b.x)**2) + ((a.y - b.y)**2))
    end

    def self.inside?(point, limit)
      point.manhattan <= limit
    end
  end
end
