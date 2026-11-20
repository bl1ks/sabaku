# frozen_string_literal: true

require "minitest/autorun"
require "receipt"

class ReceiptTest < Minitest::Test
  def test_a_pickup_order_prints_items_tax_and_total
    order = Cafe::Order.new(items: [Cafe::LineItem.new("espresso", 2)], zone: "pickup")
    assert_equal ["espresso      2 x $6.40",
                  "subtotal     $6.40",
                  "tax          $0.64",
                  "total        $7.04"], Cafe::Receipt.new(order).lines
  end

  def test_text_joins_the_lines
    order = Cafe::Order.new(items: [Cafe::LineItem.new("filter", 1)], zone: "pickup")
    receipt = Cafe::Receipt.new(order)
    assert_equal receipt.lines.join("\n"), receipt.text
    assert_includes receipt.text, "filter"
  end
end
