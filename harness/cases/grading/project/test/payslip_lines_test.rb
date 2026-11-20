# frozen_string_literal: true

require "minitest/autorun"
require "payroll/employee"
require "payroll/payslip"

class PayslipLinesTest < Minitest::Test
  def test_recorded_lines_are_kept_in_order
    payslip = Payroll::Payslip.new(
      Payroll::Employee.new(name: "Ada", rate_cents: 1000, hours: 30)
    )

    payslip.add_line("base", 30_000)
    payslip.add_line("dues", -1200)

    assert_equal %w[base dues], payslip.lines.map(&:label)
    assert_equal [30_000, -1200], payslip.lines.map(&:cents)
    assert_equal 28_800, payslip.total_cents
  end

  def test_a_single_line_totals_itself
    payslip = Payroll::Payslip.new(
      Payroll::Employee.new(name: "Ada", rate_cents: 1000, hours: 30)
    )

    payslip.add_line("base", 30_000)

    assert_equal 30_000, payslip.total_cents
  end
end
