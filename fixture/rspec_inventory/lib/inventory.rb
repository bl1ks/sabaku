# frozen_string_literal: true

module Warehouse
  # Reservation bookkeeping: enough conditionals for relational and logical operators.
  class Inventory
    LOW_STOCK = 3

    # @return [Integer]
    attr_reader :on_hand

    def initialize(on_hand, reserved = 0)
      @on_hand = on_hand
      @reserved = reserved
    end

    def available
      on_hand - @reserved
    end

    def low_stock?
      available < LOW_STOCK && available >= 0
    end

    def reserve(quantity)
      return false if quantity <= 0
      return false if quantity > available

      @reserved += quantity
      true
    end

    def release(quantity)
      return 0 if quantity <= 0

      released = [quantity, @reserved].min
      @reserved -= released
      released
    end

    def restock(quantity)
      raise ArgumentError, "quantity must be positive" unless quantity.positive?

      @on_hand += quantity
      puts "restocked #{quantity}" if ENV["WAREHOUSE_DEBUG"]
      @on_hand
    end
  end
end
