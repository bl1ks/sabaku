# frozen_string_literal: true

require "minitest/autorun"
require "ticker"

# Two of these tests are cheap and one is armed. The armed test passes a block
# that sleeps 30s: a mutant that lets the block run for a non-positive delay
# spends the rest of its deadline asleep instead of failing a test, and the
# campaign is what has to stop it.
class TickerTest < Minitest::Test
  def test_down_counts_to_zero
    assert_equal 0, Ticker::Counter.new.down(3)
  end

  def test_down_of_zero_stays_zero
    assert_equal 0, Ticker::Counter.new.down(0)
  end

  def test_total_sums_the_range
    assert_equal 6, Ticker::Counter.new.total(3)
  end

  # The armed test: the block only runs for a positive delay, so with the
  # library intact it never runs, and when a mutant lets it run it sleeps far
  # past every deadline this case uses.
  def test_after_negative_delay_runs_nothing
    ran = false
    assert_equal(-1, Ticker::Pacer.after(-1) { ran = true; sleep 30 })
    assert_equal false, ran
  end

  def test_after_positive_delay_runs_the_block
    runs = 0
    assert_equal 2, Ticker::Pacer.after(2) { runs += 1 }
    assert_equal 1, runs
  end
end
