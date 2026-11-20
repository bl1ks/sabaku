# frozen_string_literal: true

require "minitest/autorun"
require "payroll/employee"

class OvertimeTest < Minitest::Test
  def build(hours:, salaried: false)
    Payroll::Employee.new(name: "Ada", rate_cents: 1000, hours: hours, salaried: salaried)
  end

  def test_a_long_week_earns_time_and_a_half_past_the_standard_week
    employee = build(hours: 45)

    assert_equal 5, employee.overtime_hours
    assert_equal 47_500, employee.gross_cents
  end

  def test_a_week_of_exactly_the_standard_hours_earns_no_overtime
    employee = build(hours: 40)

    assert_equal 0, employee.overtime_hours
    assert_equal 40_000, employee.gross_cents
  end

  def test_a_short_week_pays_its_hours_and_no_overtime
    employee = build(hours: 30)

    assert_equal 0, employee.overtime_hours
    assert_equal 30_000, employee.gross_cents
  end

  def test_salary_staff_are_paid_for_the_standard_week
    employee = build(hours: 60, salaried: true)

    assert_equal 40, employee.paid_hours
    assert_equal 0, employee.overtime_hours
    assert_equal 40_000, employee.gross_cents
  end
end
