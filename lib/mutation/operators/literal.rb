# frozen_string_literal: true

require_relative "replacement"

module Mutation
  module Operator
    # Literal replacement: numbers step by one, and non-empty array and hash
    # literals collapse to empty. These are the mutations a reader would write
    # by hand when asking "is this value load bearing", and they cost one parse
    # each, so they stay cheap.
    module Literal
      def self.id
        :literal
      end

      def self.node_types
        [Prism::IntegerNode, Prism::FloatNode, Prism::ArrayNode, Prism::HashNode]
      end

      def self.mutations(node, source)
        original = source.slice(node)
        case node
        when Prism::IntegerNode then integer_mutations(node, original)
        when Prism::FloatNode then float_mutations(node, original)
        when Prism::ArrayNode then empty_mutation(node, original, "[]")
        when Prism::HashNode then empty_mutation(node, original, "{}")
        else []
        end
      end

      def self.integer_mutations(node, original)
        [node.value + 1, node.value - 1].uniq.map do |value|
          Replacement.new(original: original, replacement: value.to_s)
        end
      end

      def self.float_mutations(node, original)
        [node.value + 1.0, node.value - 1.0].map do |value|
          Replacement.new(original: original, replacement: value.to_s)
        end
      end

      # `%w[a b]` has no bracket to replace with `[]`, and rewriting it would
      # mean re-emitting the elements. Both node types carry the bracket
      # location, so an absent one is the whole guard.
      def self.empty_mutation(node, original, empty)
        return [] if node.elements.empty?
        return [] if node.opening_loc.nil? || node.closing_loc.nil?

        [Replacement.new(original: original, replacement: empty)]
      end

      private_class_method :integer_mutations, :float_mutations, :empty_mutation
    end
  end
end
