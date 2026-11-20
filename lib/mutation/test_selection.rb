# frozen_string_literal: true

require_relative "coverage_map"
require_relative "source"

module Mutation
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
    end

    # -> Array[String], ordered by reach then id. Empty when no test covers it.
    def tests_for(mutant, source)
      tests = @coverage_map.ordered_tests_for_span(mutant.path, mutant.line,
                                                   source.line_of(mutant.end_offset - 1))
      return tests unless tests.empty?

      # Ruby's line coverage is coarse inside one expression: a five-line
      # `a && b && c` chain reports its first and last line only.
      span = statement_spans(source)[[mutant.start_offset, mutant.end_offset]]
      return [] if span.nil?

      @coverage_map.ordered_tests_for_span(mutant.path, source.line_of(span[0]),
                                           source.line_of(span[1] - 1))
    end

    private

    def statement_spans(source)
      @statement_spans[source.rel_path] ||= Source.statement_spans(source.ast)
    end
  end
end
