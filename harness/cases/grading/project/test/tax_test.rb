# frozen_string_literal: true

require "minitest/autorun"
require "payroll/tax"

class TaxTest < Minitest::Test
  def test_a_light_period_is_withheld_at_the_light_rate
    assert_equal 10, Payroll::Tax.rate_for(50_000)
    assert_equal 5_000, Payroll::Tax.due_cents(50_000)
  end

  def test_a_heavy_period_is_withheld_at_the_heavy_rate
    assert_equal 25, Payroll::Tax.rate_for(150_000)
    assert_equal 37_500, Payroll::Tax.due_cents(150_000)
  end
end
