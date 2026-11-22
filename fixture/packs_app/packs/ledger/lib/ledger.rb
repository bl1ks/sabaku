# frozen_string_literal: true

module Bookkeeping
  def self.balance(credits, debits)
    credits - debits
  end

  # Only packs/billing tests this, so a ledger-only run leaves it uncovered.
  def self.overdrawn?(credits, debits)
    balance(credits, debits) < 0
  end
end
