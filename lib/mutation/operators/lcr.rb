# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Mutation
  module Operator
    # Logical Connector Replacement: && / || / and / or (and the & / | call forms) become the
    # other connector, the left operand, the right operand, true, or false.
    module Lcr
      CONNECTORS = {
        "&&" => "||",
        "||" => "&&",
        "and" => "or",
        "or" => "and",
        "&" => "|",
        "|" => "&"
      }.freeze

      def self.id
        :lcr
      end

      def self.node_types
        [Prism::AndNode, Prism::OrNode, Prism::CallNode]
      end

      def self.mutations(node, source)
        case node
        when Prism::AndNode, Prism::OrNode
          connector_mutations(node, source, node.left, node.right, node.operator_loc)
        when Prism::CallNode
          return [] unless call_connector?(node)

          connector_mutations(node, source, node.receiver, node.arguments.arguments.first,
                              node.message_loc)
        else
          []
        end
      end

      def self.call_connector?(node)
        %i[& |].include?(node.name) &&
          !node.receiver.nil? &&
          !node.message_loc.nil? &&
          !node.arguments.nil? &&
          node.arguments.arguments.length == 1
      end

      def self.connector_mutations(node, source, left, right, token_location)
        other = CONNECTORS[token_location.slice]
        return [] unless other

        original = source.slice(node)
        [
          Replacement.new(original: original, replacement: source.slice(left)),
          Replacement.new(original: original, replacement: source.slice(right)),
          Replacement.new(
            original: original,
            replacement: Support.replace_token(original, node, token_location, other)
          ),
          Replacement.new(original: original, replacement: "true"),
          Replacement.new(original: original, replacement: "false")
        ].uniq(&:replacement)
      end

      private_class_method :call_connector?, :connector_mutations
    end
  end
end
