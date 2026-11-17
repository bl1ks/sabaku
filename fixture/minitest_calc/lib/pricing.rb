# frozen_string_literal: true

module Shop
  # Small pricing rules with just enough branching to be worth mutating.
  class Pricing
    TAX_RATE = 0.1
    FREE_SHIPPING_THRESHOLD = 50

    attr_reader :items

    def initialize(items = [])
      @items = items
    end

    def subtotal
      items.sum { |item| item[:price] * item[:quantity] }
    end

    def discount
      return 0 if items.empty?

      volume = items.sum { |item| item[:quantity] }
      if volume >= 10
        subtotal * 0.15
      elsif volume >= 5
        subtotal * 0.05
      else
        0
      end
    end

    def tax
      (subtotal - discount) * TAX_RATE
    end

    def shipping
      return 0 if subtotal >= FREE_SHIPPING_THRESHOLD

      4.95
    end

    def total
      subtotal - discount + tax + shipping
    end

    def eligible_for_free_gift?
      items.any? && subtotal > 100 && !items.all? { |item| item[:clearance] }
    end

    def to_s
      "Pricing(#{items.size} items, total=#{total})"
    end
  end
end
