# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Sabaku
  module Operator
    # Relational Operator Replacement: each of == != > >= < <= becomes every other relational
    # form, plus the whole expression becomes true and false.
    module Ror
      RELATIONAL = %i[== != > >= < <=].freeze

      def self.id
        :ror
      end

      def self.node_types
        [Prism::CallNode]
      end

      def self.mutations(node, source)
        return [] unless binary_call?(node)

        token = node.message_loc.slice
        return [] unless RELATIONAL.include?(token.to_sym)

        original = source.slice(node)
        replacements = (RELATIONAL - [token.to_sym]).map do |replacement|
          Replacement.new(
            original: original,
            replacement: Support.replace_token(original, node, node.message_loc, replacement.to_s)
          )
        end
        replacements << Replacement.new(original: original, replacement: "true")
        replacements << Replacement.new(original: original, replacement: "false")
        replacements
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
