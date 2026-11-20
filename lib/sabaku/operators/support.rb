# frozen_string_literal: true

require "prism"

module Sabaku
  module Operator
    # Offset arithmetic shared by the operators that rewrite one token or one sub-range of a
    # node, plus the parent lookup SBR needs because the operator contract passes no ancestors.
    module Support
      module_function

      def replace_range(slice, node, start_offset, end_offset, text)
        start = start_offset - node.location.start_offset
        stop = end_offset - node.location.start_offset
        out = slice.dup
        out.bytesplice(start, stop - start, text)
        out
      end

      def replace_token(slice, node, token_location, token)
        replace_range(slice, node, token_location.start_offset, token_location.end_offset, token)
      end

      # The offsets a rewrite of +node+ must occupy. `return 1 if(x > 0)` parses
      # as an IfNode whose predicate is the whole `(x > 0)`, so replacing the
      # predicate's own range deletes the parentheses and fuses the keyword with
      # the replacement (`iftrue`, which does not parse). A parenthesised
      # operand is therefore rewritten inside the parentheses.
      def unwrapped_range(node)
        if node.is_a?(Prism::ParenthesesNode) && node.body
          [node.body.location.start_offset, node.body.location.end_offset]
        else
          [node.location.start_offset, node.location.end_offset]
        end
      end

      def slice_range(slice, node, range)
        start = range[0] - node.location.start_offset
        slice.byteslice(start, range[1] - range[0])
      end

      def parent_of(node, source)
        stack = [source.ast]
        until stack.empty?
          current = stack.pop
          return current if current.compact_child_nodes.any? { |child| child.equal?(node) }

          stack.concat(current.compact_child_nodes)
        end
        nil
      end
    end
  end
end
