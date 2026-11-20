# frozen_string_literal: true

module Cafe
  # Cash rounding: the smallest coin is five cents, so a cash total lands on
  # that step. Card totals keep the exact amount.
  module Rounding
    STEP = 5

    def self.to_step(cents, step = STEP)
      return cents if step <= 1

      ((cents + (step / 2)) / step) * step
    end

    def self.cash_total(cents)
      to_step(cents)
    end

    def self.card_total(cents)
      Integer(cents)
    end
  end
end
