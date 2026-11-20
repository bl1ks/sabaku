# frozen_string_literal: true

module Shop
  # A cart of prices. Below the bulk threshold the customer pays the sum. At or
  # above it the cart takes ten percent off. Shipping is free above a second
  # threshold.
  class Pricing
    BULK = 1_000
    FREE_SHIPPING = 5_000

    def initialize(prices)
      @prices = prices
    end

    def subtotal
      @prices.sum
    end

    def total
      return subtotal if subtotal < BULK

      subtotal - discount
    end

    def discount
      subtotal / 10
    end

    def shipping
      total < FREE_SHIPPING ? 500 : 0
    end
  end
end
