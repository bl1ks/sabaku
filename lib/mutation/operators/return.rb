# frozen_string_literal: true

require_relative "replacement"
require_relative "support"
require_relative "../aridity"

module Mutation
  module Operator
    # Return value removal: the last expression of a method body becomes `nil`, so
    # the method keeps every side effect and loses only what it returns.
    #
    # This is the mutation a reader writes when asking "does anything use this
    # method's value". `Sbr` deliberately leaves the last statement alone, because
    # deleting it is not the same question: this operator keeps the call and
    # changes what the method hands back.
    module Return
      def self.id
        :return
      end

      def self.node_types
        [Prism::DefNode]
      end

      def self.mutations(node, source)
        body = node.body
        return [] unless body.is_a?(Prism::StatementsNode)

        last = body.body.last
        return [] if last.nil?
        # `nil` is already the mutation's image.
        return [] if last.is_a?(Prism::NilNode)
        return [] if Aridity.new.arid?(last, [node])
        # A heredoc's node location covers only the opening marker, so replacing
        # the statement would leave its body behind.
        return [] if heredoc?(last)

        original = source.slice(node)
        [Replacement.new(
          original: original,
          replacement: Support.replace_range(original, node, last.location.start_offset,
                                             last.location.end_offset, "nil"),
          line: last.location.start_line
        )]
      end

      def self.heredoc?(node)
        stack = [node]
        until stack.empty?
          current = stack.pop
          opening = current.respond_to?(:opening_loc) ? current.opening_loc : nil
          return true if opening && opening.slice.start_with?("<<")

          stack.concat(current.compact_child_nodes)
        end
        false
      end

      private_class_method :heredoc?
    end
  end
end
