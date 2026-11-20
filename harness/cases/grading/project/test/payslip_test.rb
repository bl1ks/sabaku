# frozen_string_literal: true

require "minitest/autorun"
require "payroll/employee"
require "payroll/payslip"

class PayslipTest < Minitest::Test
  def build(hours: 45, salaried: false)
    employee = Payroll::Employee.new(name: "Ada", rate_cents: 1000, hours: hours, salaried: salaried)
    Payroll::Payslip.new(employee)
  end

  def test_a_long_week_carries_gross_withholding_and_net
    payslip = build

    assert_equal 47_500, payslip.gross_cents
    assert_equal 4_750, payslip.withholding_cents
    assert_equal 41_550, payslip.net_cents
  end

  def test_a_salaried_period_withholds_on_the_standard_week
    payslip = build(hours: 60, salaried: true)

    assert_equal 40_000, payslip.gross_cents
    assert_equal 4_000, payslip.withholding_cents
    assert_equal 34_800, payslip.net_cents
  end

  def test_a_new_payslip_has_no_lines
    payslip = build

    assert_equal "Ada", payslip.employee.name
    assert_equal [], payslip.lines
  end
end
