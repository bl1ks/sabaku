# frozen_string_literal: true

module Cafe
  # Zone base rate plus a per-kilogram surcharge. Pickup is free, and a large
  # order ships free.
  module Shipping
    ZONES = { "pickup" => 0, "local" => 400, "kanto" => 600, "kansai" => 900 }.freeze
    FREE_OVER_CENTS = 10_000
    PER_KG_CENTS = 120

    def self.base_cents(zone)
      ZONES.fetch(zone.to_s, ZONES.fetch("kanto"))
    end

    def self.cents_for(zone:, grams:, subtotal_cents:)
      return 0 if subtotal_cents >= FREE_OVER_CENTS

      base = base_cents(zone)
      return 0 if base.zero?

      base + ((grams / 1000) * PER_KG_CENTS)
    end
  end
end
