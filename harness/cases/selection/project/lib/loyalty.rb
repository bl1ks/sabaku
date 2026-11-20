# frozen_string_literal: true

require_relative "money"

module Cafe
  # Loyalty points: one point per hundred cents spent, and every point is
  # worth five cents. Earning is live; spending, expiry, transfers, statements
  # and redemption are on the roadmap and the shop has not asked for them yet,
  # so no test exercises them. That is deliberate: the case needs a file whose
  # coverage is uneven.
  class Loyalty
    ACCRUAL_CENTS = 100
    POINT_VALUE_CENTS = 5
    EXPIRY_MONTHS = 12

    attr_reader :points

    def initialize(points, tier: :standard)
      @points = Integer(points)
      @tier = tier
    end

    # Gold members earn twice as fast. Returns the new balance.
    def earn(cents)
      earned = cents / ACCRUAL_CENTS
      points + (@tier == :gold ? earned * 2 : earned)
    end

    def value_cents
      points * POINT_VALUE_CENTS
    end

    def redeem(cents)
      cost = (cents / POINT_VALUE_CENTS.to_f).ceil
      if cost > points
        [0, cost - points]
      else
        [points - cost, 0]
      end
    end

    def redeem!(cents)
      left, shortfall = redeem(cents)
      @points = left
      shortfall.zero?
    end

    def expire(months)
      return points if months < EXPIRY_MONTHS
      return 0 if months >= EXPIRY_MONTHS * 2

      points / 2
    end

    def transfer(receiver, amount)
      return false unless amount.positive?
      return false if amount > points

      receiver.receive(amount)
      true
    end

    def history(entries)
      entries.map do |entry|
        sign = entry.negative? ? "-" : "+"
        "#{sign}#{Money.new(entry.abs)}"
      end
    end
  end
end
