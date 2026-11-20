# frozen_string_literal: true

module Cafe
  # The shelf. Prices are cents and never move at runtime; the hash and its
  # entries are frozen so one test cannot change the catalog for the next.
  module Catalog
    PRODUCTS = {
      "espresso" => { name: "Espresso beans", cents: 320, pack: 12 }.freeze,
      "filter" => { name: "Filter roast", cents: 280, pack: 12 }.freeze,
      "oat-milk" => { name: "Oat milk", cents: 240, pack: 6 }.freeze,
      "pastry-box" => { name: "Pastry box", cents: 1500, pack: 4 }.freeze,
      "cold-brew" => { name: "Cold brew concentrate", cents: 450, pack: 6 }.freeze
    }.freeze

    def self.fetch(code)
      PRODUCTS.fetch(code.to_s)
    end

    def self.price_cents(code)
      fetch(code)[:cents]
    end

    def self.pack_size(code)
      fetch(code)[:pack]
    end

    def self.available?(code)
      PRODUCTS.key?(code.to_s)
    end
  end
end
