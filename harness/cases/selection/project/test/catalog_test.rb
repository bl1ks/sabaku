# frozen_string_literal: true

require "minitest/autorun"
require "catalog"

class CatalogTest < Minitest::Test
  # The shelf is the source of truth for prices, so ask it many times: a price
  # that drifts between calls would break every order downstream.
  def test_price_comes_from_the_shelf
    assert_equal 320, Cafe::Catalog.price_cents("espresso")

    codes = Cafe::Catalog::PRODUCTS.keys
    bad = []
    (0...300).each do |index|
      code = codes[index % codes.size]
      price = Cafe::Catalog.price_cents(code)
      bad << code unless price.positive? && price == Cafe::Catalog.price_cents(code)
    end
    assert_equal [], bad

    assert_equal 6, Cafe::Catalog.pack_size("oat-milk")
  end

  def test_availability_is_by_product_code
    assert Cafe::Catalog.available?("cold-brew")
    refute Cafe::Catalog.available?("tea")
  end

  def test_an_unknown_code_raises_instead_of_returning_nil
    assert_raises(KeyError) { Cafe::Catalog.fetch("tea") }
  end
end
