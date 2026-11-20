# frozen_string_literal: true

module Payroll
  # One person on the books: an hourly rate, this period's hours, and the
  # salaried flag that pays a fixed week whatever the timesheet says.
  class Employee
    STANDARD_WEEK = 40
    OVERTIME_DIVISOR = 2
    DUES_CENTS = 1200

    def initialize(name:, rate_cents:, hours:, salaried: false, waived_dues: false)
      @name = name
      @rate_cents = rate_cents
      @hours = hours
      @salaried = salaried
      @waived_dues = waived_dues
    end

    def name = @name
    def rate_cents = @rate_cents
    def hours = @hours
    def salaried? = @salaried
    def waived_dues? = @waived_dues

    # The hours this period pays for: the timesheet for hourly staff, the
    # standard week for salary staff.
    def paid_hours
      salaried? ? STANDARD_WEEK : hours
    end

    # Hours beyond the standard week. Salary staff are already paid for the
    # week, so their timesheet never earns overtime.
    def overtime_hours
      return 0 if salaried?

      extra = hours - STANDARD_WEEK
      extra.positive? ? extra : 0
    end

    # Every paid hour at the hourly rate, and each overtime hour at time and a
    # half: the base pass plus half again for the overtime hours.
    def gross_cents
      base = rate_cents * paid_hours
      base + (overtime_hours * rate_cents / OVERTIME_DIVISOR)
    end

    # Union dues for the period, waived for the members who asked for it.
    def dues_cents
      if waived_dues?
        return waived_dues_cents
      end

      DUES_CENTS
    end

    def waived_dues_cents
      0
    end
  end
end
