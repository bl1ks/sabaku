# frozen_string_literal: true

module Cafe
  # An amount in integer cents. Floats are allowed only at the edge, where a
  # decimal literal from a menu becomes a whole number of cents.
  class Money
    attr_reader :cents

    def self.from_dollars(amount)
      new((amount * 100).round)
    end

    def initialize(cents)
      @cents = Integer(cents)
    end

    def +(other)
      Money.new(cents + other.cents)
    end

    def -(other)
      Money.new(cents - other.cents)
    end

    def *(factor)
      Money.new((cents * factor).round)
    end

    def zero?
      cents.zero?
    end

    def to_s
      sign = cents.negative? ? "-" : ""
      dollars, remainder = cents.abs.divmod(100)
      format("%s$%d.%02d", sign, dollars, remainder)
    end
  end
end
