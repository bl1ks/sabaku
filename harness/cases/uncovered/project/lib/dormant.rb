# frozen_string_literal: true

# Loaded by the test helper; no test calls a method.
module Dormant
  def self.fee(amount)
    if amount > 100
      amount * 2
    else
      amount + 1
    end
  end
end
