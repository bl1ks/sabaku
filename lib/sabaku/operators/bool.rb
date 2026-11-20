# frozen_string_literal: true

require_relative "replacement"

module Sabaku
  module Operator
    # Boolean literal flip: true becomes false and false becomes true.
    module Bool
      def self.id
        :bool
      end

      def self.node_types
        [Prism::TrueNode, Prism::FalseNode]
      end

      def self.mutations(node, source)
        replacement = node.is_a?(Prism::TrueNode) ? "false" : "true"
        [Replacement.new(original: source.slice(node), replacement: replacement)]
      end
    end
  end
end
