# frozen_string_literal: true

require "minitest/autorun"
require "line_item"

class LineItemTest < Minitest::Test
  # Every product at every quantity in a range: the subtotal is the shelf price
  # times the count, never rounded on the way.
  def test_subtotal_multiplies_the_shelf_price
    assert_equal 640, Cafe::LineItem.new("espresso", 2).subtotal_cents

    bad = []
    %w[espresso filter oat-milk pastry-box cold-brew].each do |code|
      unit = Cafe::Catalog.price_cents(code)
      (1..200).each do |quantity|
        item = Cafe::LineItem.new(code, quantity)
        bad << [code, quantity] unless item.subtotal_cents == unit * quantity
      end
    end
    assert_equal [], bad
  end

  def test_a_dozen_or_more_is_wholesale
    refute Cafe::LineItem.new("espresso", 11).wholesale?
    assert Cafe::LineItem.new("espresso", 12).wholesale?
  end

  def test_packs_count_whole_shelf_slots
    assert_equal 2, Cafe::LineItem.new("espresso", 13).packs
  end
end
