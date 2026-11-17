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
    :output,
    :env,
    :requires,
    :setup,
    :setup_path,
    :fail_fast,
    :baseline
  ) do
    def initialize(paths: [], exclude: [], operators: Operator::Registry.defaults,
                   adapter: :minitest, jobs: 1, timeout: 5.0, seed: 0, per_line: 1,
                   diff_ranges: nil, coverage: true, isolation: :fork,
                   report: :terminal, output: nil, env: {}, requires: [], setup: nil, setup_path: nil,
                   fail_fast: false, baseline: true)
      super(
        paths: Array(paths).map(&:to_s).freeze,
        exclude: Array(exclude).map(&:to_s).freeze,
        operators: Array(operators).map(&:to_sym).freeze,
        adapter: adapter.to_sym,
        jobs: Integer(jobs),
        timeout: Float(timeout),
        seed: Integer(seed),
        per_line: normalize_per_line(per_line),
        diff_ranges: diff_ranges,
        coverage: coverage ? true : false,
        isolation: isolation.to_sym,
        report: report.to_sym,
        output: output,
        env: Hash(env).to_h { |key, value| [key.to_s.freeze, value.to_s.freeze] }.freeze,
        requires: Array(requires).map(&:to_s).freeze,
        setup: setup,
        setup_path: setup_path.nil? ? nil : setup_path.to_s.freeze,
        fail_fast: fail_fast ? true : false,
        baseline: baseline ? true : false
      )
    end

    # `--per-line=all` keeps every candidate on a line, which is the depth
    # mutant runs at. The paper's one-per-line stays the default.
    def per_line_all?
      per_line == Float::INFINITY
    end

    def self.default(**overrides)
      new(**overrides)
    end

    def with(**overrides)
      self.class.new(**to_h, **overrides)
    end

    private

    def normalize_per_line(value)
      return Float::INFINITY if value == :all || value == "all" || value == Float::INFINITY

      Integer(value)
    end
  end
end
