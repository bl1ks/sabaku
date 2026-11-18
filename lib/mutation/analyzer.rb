# frozen_string_literal: true

require "prism"
require_relative "errors"
require_relative "source"
require_relative "mutant"
require_relative "operators/registry"
require_relative "aridity"
require_relative "weak"

module Mutation
  # Turns sources into the mutants that will be run: walk, drop arid nodes, ask operators,
  # filter by diff, keep the most productive subset per line, and emit in a stable order.
  #
  # Each candidate carries its identity coordinates: the enclosing scope, its path inside
  # that scope, the operator and the replacement. Offsets are kept for splicing but do not
  # take part in `Mutant#id`, so a method that moves keeps its cache entries.
  class Analyzer
    TOP_SCOPE = "top"

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
      @scope_ordinals = Hash.new(0)
      source.ast.compact_child_nodes.each_with_index do |child, index|
        walk(child, [source.ast], source, candidates,
             scope: TOP_SCOPE, path: index.to_s, in_def: false)
      end
      select_per_line(source, candidates)
    end

    def walk(node, ancestors, source, candidates, scope:, path:, in_def:)
      return if @aridity.arid?(node, ancestors)

      applicable = @operators.select do |operator|
        operator.node_types.any? { |node_class| node.is_a?(node_class) }
      end

      unless applicable.empty?
        actual = source.slice(node)
        applicable.each do |operator|
          operator.mutations(node, source).each do |replacement|
            verify!(operator, replacement, actual, source, node)
            # A rewrite that changes no bytes always survives and would score as
            # a test gap. Operators should not emit one; this is the net.
            next if replacement.replacement == actual
            line = replacement.line || node.location.start_line
            next unless diff_covers?(source, line)

            candidates << build_mutant(source, node, operator, replacement, line,
                                       scope: scope, path: path, in_def: in_def)
          end
        end
      end

      inner_scope, inner_def = descend_scope(node, source, scope, in_def)
      reset = inner_scope != scope || inner_def != in_def
      node.compact_child_nodes.each_with_index do |child, index|
        child_path = reset || path.empty? ? index.to_s : "#{path}/#{index}"
        walk(child, ancestors + [node], source, candidates,
             scope: inner_scope, path: child_path, in_def: inner_def)
      end
    end

    # The identity scope a node opens for its children. `in_def` tracks whether the
    # `def` body that encloses the node is a method, which is where weak probes can run.
    def descend_scope(node, source, scope, in_def)
      case node
      when Prism::DefNode
        base = "#{scope}##{node.name}"
        # A file may reopen a class and define the same method twice. The second body is a
        # different place, so it gets its own scope and its mutants keep distinct ids.
        count = (@scope_ordinals[base] += 1)
        [count == 1 ? base : "#{base}~#{count}", true]
      when Prism::ClassNode, Prism::ModuleNode
        ["#{scope}::#{source.slice(node.constant_path)}", false]
      when Prism::SingletonClassNode
        ["#{scope}::<singleton>", false]
      else
        [scope, in_def]
      end
    end

    def verify!(operator, replacement, actual, source, node)
      return if replacement.original == actual

      raise OperatorError,
            "#{operator.id} produced original #{replacement.original.inspect} for " \
            "#{source.rel_path}:#{node.location.start_line}, expected #{actual.inspect}"
    end

    # A candidate that does not re-parse can never be applied: every child would
    # fail to load it, so it would be scored as an error and, since an error now
    # fails the campaign, one heredoc-heavy file could block a gate. Dropping it
    # here keeps the line's next candidate and keeps the exit code about the
    # suite. Only mutants that are actually kept pay for the parse.
    def candidate_parses?(mutant, source)
      Prism.parse(mutant.splice(source.text)).errors.empty?
    rescue StandardError
      false
    end

    def diff_covers?(source, line)
      ranges = config.diff_ranges
      return true if ranges.nil?

      file_ranges = ranges[source.rel_path]
      return false if file_ranges.nil?

      file_ranges.any? { |range| range.respond_to?(:cover?) && range.cover?(line) }
    end

    def build_mutant(source, node, operator, replacement, line, scope:, path:, in_def:)
      location = node.location
      Mutant.new(
        path: source.rel_path,
        operator: operator.id,
        line: line,
        column: location.start_column,
        node_kind: node.class.name.split("::").last,
        original: replacement.original,
        replacement: replacement.replacement,
        start_offset: location.start_offset,
        end_offset: location.end_offset,
        scope: scope,
        ast_path: path,
        weak: in_def && Weak.eligible?(operator.id, node)
      )
    end

    # The per-line budget goes to the most productive operator first, then to the
    # earliest offset, with names as the final tie break. No draw and no seed: the
    # same code always keeps the same mutants, so cache entries stay usable.
    def select_per_line(source, candidates)
      chosen = []
      candidates.uniq(&:id).group_by(&:line).each do |_line, group|
        ordered = group.sort_by do |mutant|
          [Operator::Registry.rank(mutant.operator), mutant.start_offset,
           mutant.operator.to_s, mutant.replacement]
        end
        wanted = [config.per_line, ordered.length].min
        taken = 0
        ordered.each do |mutant|
          break if taken >= wanted
          next unless candidate_parses?(mutant, source)

          chosen << mutant
          taken += 1
        end
      end
      chosen.sort_by do |mutant|
        [mutant.path, mutant.start_offset, mutant.operator.to_s, mutant.replacement]
      end
    end
  end
end
