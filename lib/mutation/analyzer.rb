# frozen_string_literal: true

require "prism"
require "zlib"
require_relative "errors"
require_relative "source"
require_relative "mutant"
require_relative "operators/registry"
require_relative "aridity"

module Mutation
  # Turns sources into the mutants that will be run: walk, drop arid nodes, ask operators,
  # filter by diff, keep a seeded subset per line, and emit in a stable order.
  class Analyzer
    attr_reader :sources, :config

    def initialize(sources, config)
      @sources = normalize_sources(sources)
      @config = config
      @operators = config.operators.map { |id| Operator::Registry.fetch(id) }
      @aridity = Aridity.new
    end

    def each
      return enum_for(:each) unless block_given?

      sorted_sources.each do |source|
        analyze_source(source).each { |mutant| yield mutant }
      end
      self
    end

    def mutants
      each.to_a
    end

    private

    def normalize_sources(sources)
      return sources.dup if sources.is_a?(Array)
      return [sources] if sources.is_a?(Source)
      return sources.to_a if sources.respond_to?(:to_a)

      [sources]
    end

    def sorted_sources
      @sources.each_with_index.sort_by { |source, index| [source.rel_path, index] }.map(&:first)
    end

    def analyze_source(source)
      candidates = []
      source.ast.compact_child_nodes.each do |child|
        walk(child, [source.ast], source, candidates)
      end
      select_per_line(source, candidates)
    end

    def walk(node, ancestors, source, candidates)
      return if @aridity.arid?(node, ancestors)

      applicable = @operators.select do |operator|
        operator.node_types.any? { |node_class| node.is_a?(node_class) }
      end

      unless applicable.empty?
        actual = source.slice(node)
        applicable.each do |operator|
          operator.mutations(node, source).each do |replacement|
            verify!(operator, replacement, actual, source, node)
            next unless diff_covers?(source, node.location.start_line)

            candidates << build_mutant(source, node, operator, replacement)
          end
        end
      end

      node.compact_child_nodes.each { |child| walk(child, ancestors + [node], source, candidates) }
    end

    def verify!(operator, replacement, actual, source, node)
      return if replacement.original == actual

      raise OperatorError,
            "#{operator.id} produced original #{replacement.original.inspect} for " \
            "#{source.rel_path}:#{node.location.start_line}, expected #{actual.inspect}"
    end

    def diff_covers?(source, line)
      ranges = config.diff_ranges
      return true if ranges.nil?

      file_ranges = ranges[source.rel_path]
      return false if file_ranges.nil?

      file_ranges.any? { |range| range.respond_to?(:cover?) && range.cover?(line) }
    end

    def build_mutant(source, node, operator, replacement)
      location = node.location
      Mutant.new(
        path: source.rel_path,
        operator: operator.id,
        line: location.start_line,
        column: location.start_column,
        node_kind: node.class.name.split("::").last,
        original: replacement.original,
        replacement: replacement.replacement,
        start_offset: location.start_offset,
        end_offset: location.end_offset
      )
    end

    def select_per_line(source, candidates)
      chosen = []
      candidates.uniq(&:id).group_by(&:line).each do |line, group|
        ordered = group.sort_by { |mutant| [mutant.start_offset, mutant.operator.to_s, mutant.replacement] }
        random = Random.new(config.seed ^ Zlib.crc32("#{source.rel_path}:#{line}"))
        [config.per_line, ordered.length].min.times do
          chosen << ordered.delete_at(random.rand(ordered.length))
        end
      end
      chosen.sort_by do |mutant|
        [mutant.path, mutant.start_offset, mutant.operator.to_s, mutant.replacement]
      end
    end
  end
end
