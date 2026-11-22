# frozen_string_literal: true

require_relative "../../ledger/lib/ledger"

module Invoice
  def self.payable?(credits, debits)
    !Bookkeeping.overdrawn?(credits, debits)
  end
end
