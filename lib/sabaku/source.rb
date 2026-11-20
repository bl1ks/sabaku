# frozen_string_literal: true

require "prism"

require_relative "errors"

module Sabaku
  # One Ruby file: its path, its exact text, and the Prism tree parsed once. Every operator
  # works in offsets into #text, so this is the only place the source is tokenized.
  class Source
    attr_reader :rel_path, :text, :ast

    def initialize(rel_path, text)
      @rel_path = rel_path.to_s.freeze
      @text = text.dup.freeze
      result = Prism.parse(@text)
      @ast = result.value
      @line_starts = build_line_starts
      reject_parse_errors(result)
      freeze
    end

    # A file the parser rejects cannot be mutated: every candidate would fail to
    # apply, and the mutant would be reported as an error or as an uncovered
    # line instead of as the broken file it is. Naming the file and the first
    # error here is the only place that knows both.
    def reject_parse_errors(result)
      first = result.errors.first
      return if first.nil?

      line = @text.byteslice(0, first.location.start_offset).to_s.count("\n") + 1
      raise Sabaku::Error,
            "#{@rel_path}:#{line}: #{first.message} (the file does not parse, so it " \
            "cannot be mutated; pass --exclude to skip it)"
    end

    # Maps [start_offset, end_offset] of every node to the span of the statement
    # that contains it. Built once per file with one AST walk.
    def self.statement_spans(ast)
      map = {}
      stack = [[ast, nil]]
      until stack.empty?
        node, statement = stack.pop
        span = [node.location.start_offset, node.location.end_offset]
        map[span] ||= statement || span
        if node.is_a?(Prism::StatementsNode)
          node.compact_child_nodes.each do |child|
            stack.push([child, [child.location.start_offset, child.location.end_offset]])
          end
        else
          node.compact_child_nodes.each { |child| stack.push([child, statement]) }
        end
      end
      map
    end

    def line_of(offset)
      @line_starts.bsearch_index { |start| start > offset } || @line_starts.length
    end

    def slice(node)
      node.location.slice
    end

    def flat_nodes
      return enum_for(:flat_nodes) unless block_given?

      stack = ast.compact_child_nodes.reverse
      until stack.empty?
        node = stack.pop
        yield node
        node.compact_child_nodes.reverse_each { |child| stack << child }
      end
    end

    private

    def build_line_starts
      starts = [0]
      text.b.each_byte.with_index do |byte, index|
        starts << index + 1 if byte == 10
      end
      starts.freeze
    end
  end
end
