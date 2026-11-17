# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Mutation
  module Operator
    # Conditional replacement: a branch predicate becomes true and false. While
    # and until loops are excluded on purpose: `while true` never returns, so
    # its mutants would be killed by the clock and inflate the timeout count
    # instead of testing the suite.
    module Cond
      NODES = [Prism::IfNode, Prism::UnlessNode].freeze

      def self.id
        :cond
      end

      def self.node_types
        NODES
      end

      def self.mutations(node, source)
        predicate = node.predicate
        return [] if predicate.nil?

        original = source.slice(node)
        span = predicate.location
        %w[true false].map do |value|
          Replacement.new(
            original: original,
            replacement: Support.replace_range(original, node, span.start_offset,
                                               span.end_offset, value)
          )
        end
      end
    end
  end
end
