# frozen_string_literal: true

require_relative "replacement"

module Sabaku
  module Operator
    # String literal replacement: any non-empty plain string literal becomes "". Heredocs are
    # left alone because Prism's node location covers only the opening marker.
    module Str
      def self.id
        :str
      end

      def self.node_types
        [Prism::StringNode]
      end

      def self.mutations(node, source)
        return [] if node.unescaped.empty?
        return [] unless standalone?(node)

        [Replacement.new(original: source.slice(node), replacement: '""')]
      end

      def self.standalone?(node)
        opening = node.opening_loc
        return false if opening.nil? || node.closing_loc.nil?

        !opening.slice.start_with?("<<")
      end

      private_class_method :standalone?
    end
  end
end
