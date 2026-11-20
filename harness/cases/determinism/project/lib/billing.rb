# frozen_string_literal: true

module Billing
  # Refund arithmetic for the determinism case. Enough branches for a handful of
  # mutants, and one tier boundary the suite never touches: `handling_fee` compares
  # the total against SMALL_TOTAL, but no test ever passes exactly SMALL_TOTAL.
  class Refund
    SMALL_TOTAL = 25
    MAX_REFUND = 500
    SMALL_FEE = 5

    attr_reader :total

    def initialize(total)
      @total = total
    end

    # The untested boundary. A test that only checks a total below the tier and a
    # total above it cannot tell `>` from `>=`, so that mutant survives until the
    # suite gains a test at exactly SMALL_TOTAL.
    def handling_fee
      total > SMALL_TOTAL ? 0 : SMALL_FEE
    end

    def refundable?
      total.positive? && total <= MAX_REFUND
    end

    def amount
      return 0 unless refundable?

      total - handling_fee
    end

    def receipt
      "total=#{total} fee=#{handling_fee} refund=#{amount}"
    end
  end
end
