# frozen_string_literal: true

require_relative "catalog"

module Cafe
  # The rules a shopkeeper would check by eye before accepting an order.
  module Validation
    MAX_UNITS = 200

    def self.errors(order)
      errors = []
      errors << "empty order" if order.items.empty?
      errors << "too many units" if order.units > MAX_UNITS
      order.items.each do |item|
        errors << "unknown product #{item.code}" unless Catalog.available?(item.code)
        errors << "bad quantity #{item.quantity}" if item.quantity <= 0
      end
      errors
    end

    def self.valid?(order)
      errors(order).empty?
    end
  end
end
