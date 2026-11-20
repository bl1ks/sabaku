# frozen_string_literal: true

require_relative "catalog"
require_relative "units"

module Cafe
  # One product and a count. It deliberately knows nothing about orders,
  # discounts or tax: those are the order's questions, not the item's.
  class LineItem
    attr_reader :code, :quantity

    def initialize(code, quantity)
      @code = code.to_s
      @quantity = Integer(quantity)
    end

    def unit_cents
      Catalog.price_cents(@code)
    end

    def subtotal_cents
      unit_cents * @quantity
    end

    def wholesale?
      @quantity >= Units.dozens(1)
    end

    def packs
      Units.packs(@quantity, Catalog.pack_size(@code))
    end
  end
end
