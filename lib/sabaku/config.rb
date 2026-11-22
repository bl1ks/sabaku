# frozen_string_literal: true

module Sabaku
  # Every knob the CLI can turn, as one frozen value. Built once per run and passed down;
  # nothing below reads ENV or ARGV.
  Config = Data.define(
    :paths,
    :exclude,
    :operators,
    :jobs,
    :timeout,
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
    :baseline,
    :weak,
    :kill_matrix,
    :kill_matrix_scope,
    :kill_matrix_focus,
    :sweep_timeout,
    :test_globs
  ) do
    def initialize(paths: [], exclude: [], operators: Operator::Registry.defaults,
                   jobs: 1, timeout: 5.0, per_line: 1,
                   diff_ranges: nil, coverage: true, isolation: :fork,
                   report: :terminal, output: nil, env: {}, requires: [], setup: nil, setup_path: nil,
                   fail_fast: false, baseline: true, weak: true, kill_matrix: false, kill_matrix_scope: :class,
                   kill_matrix_focus: [], sweep_timeout: nil, test_globs: [])
      focus = Array(kill_matrix_focus).map(&:to_s).freeze
      # A focus is exact because dominance never crosses a class; under :suite it would not be.
      if focus.any? && kill_matrix_scope.to_sym == :suite
        raise Sabaku::Error, "a kill-matrix focus needs --kill-matrix-scope=class"
      end

      super(
        paths: Array(paths).map(&:to_s).freeze,
        exclude: Array(exclude).map(&:to_s).freeze,
        operators: Array(operators).map(&:to_sym).freeze,
        jobs: Integer(jobs),
        timeout: Float(timeout),
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
        baseline: baseline ? true : false,
        weak: weak ? true : false,
        kill_matrix: kill_matrix ? true : false,
        kill_matrix_scope: kill_matrix_scope.to_sym,
        kill_matrix_focus: focus,
        sweep_timeout: sweep_timeout.nil? ? nil : Float(sweep_timeout),
        test_globs: Array(test_globs).map(&:to_s).freeze
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
