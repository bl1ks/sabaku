# frozen_string_literal: true

module Payroll
  # Withholding for one period. The rate steps once, at the light-pay ceiling;
  # the tests bracket that ceiling with a light period and a heavy one and
  # never pay it exactly.
  module Tax
    LIGHT_CEILING_CENTS = 100_000
    LIGHT_RATE = 10
    HEAVY_RATE = 25
    PERCENT = 100

    module_function

    def rate_for(gross_cents)
      return LIGHT_RATE if gross_cents <= LIGHT_CEILING_CENTS

      HEAVY_RATE
    end

    def due_cents(gross_cents)
      gross_cents * rate_for(gross_cents) / PERCENT
    end
  end
end
