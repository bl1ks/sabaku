# frozen_string_literal: true

require_relative "tax"

module Payroll
  # One printed row of a payslip: the label the clerk typed and the amount.
  class Line
    def initialize(label, cents)
      @label = label
      @cents = cents
    end

    def label = @label
    def cents = @cents
  end

  # One period's pay for one employee. A payslip carries the three numbers
  # everybody asks for and collects the rows a clerk prints.
  class Payslip
    def initialize(employee)
      @employee = employee
      @lines = []
    end

    def employee = @employee
    def lines = @lines

    def gross_cents
      employee.gross_cents
    end

    def withholding_cents
      Tax.due_cents(gross_cents)
    end

    def net_cents
      gross_cents - withholding_cents - employee.dues_cents
    end

    # Records one row and hands back the row it stored. The clerk only prints
    # `lines`, so nothing reads the value back.
    def add_line(label, cents)
      line = Line.new(label, cents)
      @lines << line
      line
    end

    def total_cents
      @lines.sum(&:cents)
    end
  end
end
