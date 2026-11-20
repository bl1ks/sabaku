# frozen_string_literal: true

# A small project whose mutants can cost more than a verdict.
#
#   * Counter#down counts down to zero with one arithmetic operator. AOR turns
#     `n - 1` into `n + 1` (or `n * 1`), so the loop never reaches its guard and
#     the child spins forever.
#   * Pacer.after runs a block only for a positive delay, and the suite arms that
#     block with `sleep 30`. A flipped guard or an inverted comparison reaches the
#     sleep, which outlives any sane --timeout.
#
# Neither mechanism puts a sleep in the library: the hang is in the mutated
# control flow and the sleep is in the test that trusts it.
module Ticker
  # Counts down to zero; the decrement is the only thing between the loop and
  # an infinite one.
  class Counter
    def down(from)
      n = from
      while n > 0
        n = n - 1
      end
      n
    end

    def total(limit)
      sum = 0
      (1..limit).each { |i| sum = sum + i }
      sum
    end
  end

  module Pacer
    # Runs the block after `delay` only when the delay is positive. The block the
    # suite passes sleeps far longer than the deadline, so a mutant that lets it
    # run for a non-positive delay hangs the child instead of failing a test.
    def self.after(delay)
      yield if delay > 0
      delay
    end
  end
end
