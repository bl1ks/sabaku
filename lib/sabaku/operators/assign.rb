# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Sabaku
  module Operator
    # Compound assignment to plain assignment: `x += 1` becomes `x = 1`, and the
    # same for `||=` and `&&=`. The operand stays, so the mutation asks whether
    # a test notices that the accumulator stopped accumulating.
    #
    # Every write target Prism models has an `operator_loc`; the list below is
    # the operator, or, and and write forms of each target, not the plain
    # assignment ones.
    module Assign
      NODES = [
        Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode,
        Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableOrWriteNode,
        Prism::ClassVariableAndWriteNode,
        Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode,
        Prism::GlobalVariableAndWriteNode,
        Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode,
        Prism::ConstantAndWriteNode,
        Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode,
        Prism::ConstantPathAndWriteNode,
        Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode,
        Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode
      ].freeze

      def self.id
        :assign
      end

      def self.node_types
        NODES
      end

      # `x += 1` has both an `operator_loc` and a `binary_operator_loc`;
      # Prism deprecates the first for the operator-write nodes.
      def self.operator_location(node)
        node.respond_to?(:binary_operator_loc) ? node.binary_operator_loc : node.operator_loc
      end

      def self.mutations(node, source)
        operator = operator_location(node)
        return [] if operator.nil?

        original = source.slice(node)
        [Replacement.new(
          original: original,
          replacement: Support.replace_token(original, node, operator, "=")
        )]
      end

      private_class_method :operator_location
    end
  end
end
