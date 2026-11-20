# frozen_string_literal: true

require_relative "discount"
require_relative "line_item"
require_relative "money"
require_relative "shipping"
require_relative "tax"

module Cafe
  # A cart. Every number is derived on demand from the items, so two orders
  # built the same way cannot disagree and no state is shared between tests.
  class Order
    attr_reader :items, :zone, :region, :coupon, :grams

    def initialize(items:, zone: "local", region: "tokyo", coupon: nil, grams: 0)
      @items = items
      @zone = zone
      @region = region
      @coupon = coupon
      @grams = Integer(grams)
    end

    def subtotal_cents
      items.sum(&:subtotal_cents)
    end

    def units
      items.sum(&:quantity)
    end

    def discount_percent
      [Discount.volume_percent(units), Discount.coupon_percent(coupon)].max
    end

    def discount_cents
      Discount.cents_for(subtotal_cents, discount_percent)
    end

    def taxable_cents
      subtotal_cents - discount_cents
    end

    def tax_cents
      Tax.cents_for(taxable_cents, region)
    end

    def shipping_cents
      Shipping.cents_for(zone: zone, grams: grams, subtotal_cents: taxable_cents)
    end

    def total_cents
      taxable_cents + tax_cents + shipping_cents
    end

    def total
      Money.new(total_cents)
    end
  end
end
