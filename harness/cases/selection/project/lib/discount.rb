# frozen_string_literal: true

module Cafe
  # Volume tiers and coupon codes. A coupon never stacks with a volume tier:
  # the order takes the better of the two percentages.
  module Discount
    WHOLESALE_UNITS = 12
    BULK_UNITS = 48
    COUPONS = { "BEANS10" => 10, "OPENING" => 15 }.freeze

    def self.coupon_percent(code)
      return 0 if code.nil?

      COUPONS.fetch(code.to_s.upcase, 0)
    end

    def self.volume_percent(total_units)
      return 0 if total_units < WHOLESALE_UNITS
      return 5 if total_units < BULK_UNITS

      10
    end

    def self.cents_for(subtotal_cents, percent)
      (subtotal_cents * percent / 100.0).round
    end
  end
end
