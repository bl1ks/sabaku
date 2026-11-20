# frozen_string_literal: true

require "minitest/autorun"
require "billing"

# A batch big enough that a cold campaign, which re-runs the covering tests in a
# child for every mutant, costs visibly more than a warm one that answers from the
# cache. The batch sits entirely above the tier, so it cannot see the boundary the
# suite is missing.
class BatchTest < Minitest::Test
  BATCH = Array.new(120_000) { |index| 26 + (index % 4) }.freeze

  def test_every_batch_refund_keeps_its_whole_total
    refunded = BATCH.sum { |total| Billing::Refund.new(total).amount }
    assert_equal BATCH.sum, refunded
  end
end
