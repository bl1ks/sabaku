# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Sabaku
  module Operator
    # Unary Operator Insertion: wrap a condition predicate in !(...), and remove a leading
    # ! from a negated expression.
    module Uoi
      CONDITION_NODES = [
        Prism::IfNode,
        Prism::UnlessNode,
        Prism::WhileNode,
        Prism::UntilNode
      ].freeze

      def self.id
        :uoi
      end

      def self.node_types
        [*CONDITION_NODES, Prism::CallNode]
      end

      def self.mutations(node, source)
        if node.is_a?(Prism::CallNode)
          negation_mutations(node, source)
        else
          predicate_mutations(node, source)
        end
      end

      def self.negation_mutations(node, source)
        return [] unless negation?(node)

        [Replacement.new(original: source.slice(node), replacement: source.slice(node.receiver))]
      end

      def self.negation?(node)
        return false unless node.name == :! && !node.receiver.nil? && !node.message_loc.nil?
        return false unless node.arguments.nil? || node.arguments.arguments.empty?

        node.message_loc.slice == "not" || node.message_loc.start_offset == node.location.start_offset
      end

      def self.predicate_mutations(node, source)
        predicate = node.predicate
        return [] unless predicate

        original = source.slice(node)
        range = Support.unwrapped_range(predicate)
        wrapped = "!(#{Support.slice_range(original, node, range)})"
        [Replacement.new(
          original: original,
          replacement: Support.replace_range(original, node, range[0], range[1], wrapped)
        )]
      end

      private_class_method :negation?, :negation_mutations, :predicate_mutations
    end
  end
end
