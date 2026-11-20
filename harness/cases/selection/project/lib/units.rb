# frozen_string_literal: true

module Cafe
  # The counting a café order needs: a dozen is a case, a pack is one shelf
  # slot, and delivery weight arrives in grams.
  module Units
    DOZEN = 12
    GRAMS_PER_KG = 1000

    def self.dozens(count)
      count * DOZEN
    end

    # Whole packs, rounded up: an order of thirteen bags needs two packs of twelve.
    def self.packs(count, per_pack)
      (count + per_pack - 1) / per_pack
    end

    def self.grams_to_kg(grams)
      grams / GRAMS_PER_KG.to_f
    end
  end
end
