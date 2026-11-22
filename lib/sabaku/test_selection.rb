# frozen_string_literal: true

require_relative "coverage_map"
require_relative "source"

module Sabaku
  # Which tests a mutant needs, from what the coverage pass measured.
  #
  # One rule, two callers: the runner picks the tests it will run for a mutant,
  # and the sampler asks for the union of those selections to scope the weak
  # pass. Two copies of this rule would drift, and a missing test would turn a
  # probe decision into :unknown.
  class TestSelection
    def initialize(coverage_map)
      @coverage_map = coverage_map
      @statement_spans = {}
      @endless_def_lines = {}
    end

    # -> Array[String], ordered by reach then id. Empty when no test covers it.
    def tests_for(mutant, source)
      last_line = source.line_of(mutant.end_offset - 1)
      tests = @coverage_map.ordered_tests_for_span(mutant.path, mutant.line, last_line)
      return tests unless tests.empty?

      # Ruby's line coverage is coarse inside one expression: a five-line
      # `a && b && c` chain reports its first and last line only.
      span = statement_spans(source)[[mutant.start_offset, mutant.end_offset]]
      unless span.nil?
        tests = @coverage_map.ordered_tests_for_span(mutant.path, source.line_of(span[0]),
                                                     source.line_of(span[1] - 1))
        return tests unless tests.empty?
      end

      # A line only the boot ran (a class body DSL, a schema block) is owned by no single
      # test; a test that reached the file is the one that can observe what it built.
      return [] unless (mutant.line..last_line).any? { |line| @coverage_map.load_time_only?(mutant.path, line) }

      @coverage_map.ordered_tests_for_file(mutant.path)
    end

    # True when a mutant's line exists but Ruby's line counters cannot attribute it to any
    # test. An endless method (`def m = expr`) marks its own line while the class body runs
    # and a call never increments it again, so no per-test delta will ever name a test. The
    # runner runs every test for such a mutant: slower, and the only honest alternative to
    # declaring `uncovered` a line the suite does execute.
    def unattributable?(mutant, source)
      endless_def_lines(source).key?(mutant.line)
    end

    # Why `tests_for` came back empty: one of Result::REASONS[:uncovered], or nil when
    # the coverage pass did not describe the file.
    def uncovered_reason(mutant, source)
      file = @coverage_map.file(mutant.path)
      return nil if file.nil?
      return file.state if %i[not_loaded uninstrumented].include?(file.state)

      lines = mutant.line..source.line_of(mutant.end_offset - 1)
      lines.any? { |line| @coverage_map.load_time_only?(mutant.path, line) } ? :load_time_only : :not_reached
    end

    private

    # DefNode#endless? is not in every Prism this gem runs on; a missing `end` keyword is
    # what "endless" means and it is present everywhere.
    def endless_def_lines(source)
      @endless_def_lines[source.rel_path] ||= begin
        lines = {}
        stack = [source.ast]
        until stack.empty?
          node = stack.pop
          if node.is_a?(Prism::DefNode) && node.end_keyword_loc.nil?
            lines[node.location.start_line] = true
          end
          stack.concat(node.compact_child_nodes)
        end
        lines
      end
    end

    def statement_spans(source)
      @statement_spans[source.rel_path] ||= Source.statement_spans(source.ast)
    end
  end
end
