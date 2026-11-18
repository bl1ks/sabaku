# frozen_string_literal: true

require_relative "replacement"

module Mutation
  module Operator
    # Loop control swap: `break` becomes `next` and `next` becomes `break`. They
    # leave the same block in different ways, so a test that only checks the
    # collected output after the loop can miss which one ran.
    module Control
      def self.id
        :control
      end

      def self.node_types
        [Prism::BreakNode, Prism::NextNode]
      end

      def self.mutations(node, source)
        replacement = node.is_a?(Prism::NextNode) ? "break" : "next"
        [Replacement.new(original: source.slice(node), replacement: replacement)]
      end
    end
  end
end
