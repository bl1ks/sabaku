# frozen_string_literal: true

module Shipping
  # Flat rate with one weight tier. The tier boundary is deliberately untested: a campaign
  # must find that survivor, and the CI case needs both a kill and a survivor to gate on.
  class Rate
    BASE = 500
    LIGHT = 20
    HEAVY = 50

    def cost(weight)
      return 0 if weight <= 0

      per_kg = weight > 10 ? HEAVY : LIGHT
      BASE + (per_kg * weight)
    end

    # A killable line after the untested boundary, so --fail-fast has a mutant left to skip.
    def bulk(units)
      units * LIGHT
    end
  end
end
