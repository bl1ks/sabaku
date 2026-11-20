# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Sabaku
  module Operator
    # Arithmetic Operator Replacement: binary + - * / % each become the other four. Only the
    # operator token changes, so the operands stay byte-identical.
    module Aor
      OPERATORS = %i[+ - * / %].freeze

      def self.id
        :aor
      end

      def self.node_types
        [Prism::CallNode]
      end

      def self.mutations(node, source)
        return [] unless binary_call?(node)

        token = node.message_loc.slice
        return [] unless OPERATORS.include?(token.to_sym)

        original = source.slice(node)
        (OPERATORS - [token.to_sym]).map do |replacement|
          Replacement.new(
            original: original,
            replacement: Support.replace_token(original, node, node.message_loc, replacement.to_s)
          )
        end
      end

      def self.binary_call?(node)
        node.is_a?(Prism::CallNode) &&
          !node.receiver.nil? &&
          !node.message_loc.nil? &&
          !node.arguments.nil? &&
          node.arguments.arguments.length == 1
      end

      private_class_method :binary_call?
    end
  end
end
