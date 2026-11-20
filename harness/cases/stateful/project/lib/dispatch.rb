# frozen_string_literal: true

# One session of a courier desk. Every value depends on what earlier tests left
# behind: the ledger only grows, the desk carries the phase setup and teardown
# write, and the tariff is built once, from whichever tier was current then.
module Dispatch
  BASE_RATE = 2
  BULK_FACTOR = 4
  BULK_UNITS = 10

  # A module-level counter, bumped by every charge and read back by the tests.
  module Ledger
    class << self
      def entries
        @entries ||= 0
      end
      def record
        @entries = entries + 1
      end
    end
  end

  # One shared object. setup opens it, teardown closes it, and the phase the
  # teardown wrote is what the next setup reads.
  class Desk
    attr_accessor :phase, :tier, :last_phase

    def initialize = (@phase = :cold; @tier = :standard; @last_phase = nil)

    def advance!(phase) = (@last_phase = @phase; @phase = phase; self)
  end

  DESK = Desk.new

  # Built on first use and never rebuilt, so it bakes in the tier the first test
  # to ask saw. `forget!` is the only way to rebake it.
  module Tariff
    class << self
      def rate(kind)
        @table ||= { standard: BASE_RATE,
                     bulk: DESK.tier == :bulk ? BASE_RATE * BULK_FACTOR : BASE_RATE }
        @table.fetch(kind)
      end
      def forget!
        @table = nil
      end
    end
  end

  class Parcel
    attr_reader :units
    def initialize(units) = @units = units

    def charge = (Ledger.record; @units * Tariff.rate(:standard))
    def bulk_charge = (Ledger.record; @units * Tariff.rate(:bulk))

    def label = DESK.tier == :bulk ? "bulk" : "single"

    # The tiers agree on each boundary: the bulk desk takes the >= branch, the
    # standard desk the > branch, so a leak moves a mutant and never a test.
    def priority
      if DESK.tier == :bulk
        @units >= BULK_UNITS ? :express : :standard
      else
        @units > 9 ? :express : :standard
      end
    end

    def handling
      if DESK.tier == :bulk
        @units >= 5 ? :crate : :bag
      else
        @units > 4 ? :crate : :bag
      end
    end
    def tare
      @units * BASE_RATE
    end
  end
end
