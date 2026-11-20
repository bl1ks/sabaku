# frozen_string_literal: true

require_relative "money"

module Cafe
  # The printed slip. It is the only place that decides layout, so a change to
  # the numbers cannot change the text by accident.
  class Receipt
    def initialize(order)
      @order = order
    end

    def lines
      rows = @order.items.map do |item|
        format("%-12s %2d x %s", item.code, item.quantity, Money.new(item.subtotal_cents))
      end
      rows << "subtotal     #{Money.new(@order.subtotal_cents)}"
      rows << "discount     #{Money.new(@order.discount_cents)}" if @order.discount_cents.positive?
      rows << "tax          #{Money.new(@order.tax_cents)}"
      rows << "shipping     #{Money.new(@order.shipping_cents)}" unless @order.shipping_cents.zero?
      rows << "total        #{@order.total}"
      rows
    end

    def text
      lines.join("\n")
    end

    # A one-line version for the counter display. The shop has not asked for it
    # yet, so nothing tests it: it is here to keep coverage uneven.
    def summary
      discount = @order.discount_cents
      label = discount.positive? ? "saved #{Money.new(discount)}" : "no discount"
      "#{@order.units} items, #{label}, #{@order.total}"
    end
  end
end
