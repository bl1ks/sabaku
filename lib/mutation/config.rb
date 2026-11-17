# frozen_string_literal: true

module Mutation
  # Every knob the CLI can turn, as one frozen value. Built once per run and passed down;
  # nothing below reads ENV or ARGV.
  Config = Data.define(
    :paths,
    :exclude,
    :operators,
    :adapter,
    :jobs,
    :timeout,
    :seed,
    :per_line,
    :diff_ranges,
    :coverage,
    :isolation,
    :report,
    :output
  ) do
    def initialize(paths: [], exclude: [], operators: Operator::Registry.defaults,
                   adapter: :minitest, jobs: 1, timeout: 5.0, seed: 0, per_line: 1,
                   diff_ranges: nil, coverage: true, isolation: :fork,
                   report: :terminal, output: nil)
      super(
        paths: Array(paths).map(&:to_s).freeze,
        exclude: Array(exclude).map(&:to_s).freeze,
        operators: Array(operators).map(&:to_sym).freeze,
        adapter: adapter.to_sym,
        jobs: Integer(jobs),
        timeout: Float(timeout),
        seed: Integer(seed),
        per_line: Integer(per_line),
        diff_ranges: diff_ranges,
        coverage: coverage ? true : false,
        isolation: isolation.to_sym,
        report: report.to_sym,
        output: output
      )
    end

    def self.default(**overrides)
      new(**overrides)
    end

    def with(**overrides)
      self.class.new(**to_h, **overrides)
    end
  end
end
