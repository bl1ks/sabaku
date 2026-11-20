# frozen_string_literal: true

require "minitest/autorun"
require "payroll/employee"

class EmployeeTest < Minitest::Test
  def build(hours: 30, salaried: false)
    Payroll::Employee.new(name: "Ada", rate_cents: 1000, hours: hours, salaried: salaried)
  end

  def test_reads_back_the_person_it_was_given
    employee = build

    assert_equal "Ada", employee.name
    assert_equal 1000, employee.rate_cents
    assert_equal 30, employee.hours
    assert_equal false, employee.salaried?
    assert_equal false, employee.waived_dues?
  end

  def test_a_short_week_earns_its_hours
    assert_equal 30_000, build.gross_cents
  end

  def test_dues_are_withheld_from_an_ordinary_period
    assert_equal 1200, build.dues_cents
  end
end
