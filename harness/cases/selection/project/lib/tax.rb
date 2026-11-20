# frozen_string_literal: true

module Cafe
  # Consumption tax by shop region. An unknown region falls back to the head
  # office rate rather than silently charging nothing.
  module Tax
    HEAD_OFFICE_REGION = "tokyo"
    RATES = { "tokyo" => 0.10, "osaka" => 0.08, "sapporo" => 0.08 }.freeze

    def self.rate_for(region)
      RATES.fetch(region.to_s, RATES.fetch(HEAD_OFFICE_REGION))
    end

    def self.cents_for(cents, region)
      (cents * rate_for(region)).round
    end
  end
end
