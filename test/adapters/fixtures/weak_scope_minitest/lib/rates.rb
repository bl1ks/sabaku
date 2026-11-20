# frozen_string_literal: true

# One method the weak pass can probe (two locals under an arithmetic operator)
# and one method with no weak-eligible expression at all, so a test of the
# second stays out of the probe run.
class Rates
  def scaled(quantity, unit)
    quantity * unit
  end

  def label
    "rates"
  end
end
