# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Mutation
  module Operator
    # Call-shape mutations: drop the receiver, drop the receiver and message so
    # the call goes to self, or drop arguments. These are the mutations that
    # turn "this helper is wired up wrong" into a failure, and they are what a
    # reviewer asks about a call site.
    #
    # Calls are rebuilt from source slices instead of patched in place. A
    # trailing comma, a block argument, or a multi-line argument list makes an
    # in-place span replacement emit broken Ruby, and a mutation that does not
    # parse is not a mutation.
    module Call
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*[?!]?\z/.freeze

      # Ruby keywords that can never stand as a naked message. `x.class` is the
      # common one in real code.
      KEYWORDS = %w[
        alias and begin break case class def defined? do else elsif end ensure
        false for if in module next nil not or redo rescue retry return self
        super then true undef unless until when while yield
      ].freeze

      def self.id
        :call
      end

      def self.node_types
        [Prism::CallNode]
      end

      def self.mutations(node, source)
        return [] unless safe?(node)

        arguments = node.arguments ? node.arguments.arguments : []
        return [] if arguments.any?(Prism::MissingNode)

        original = source.slice(node)
        mutations = []
        mutations.concat(receiver_removal(node, source, original))
        mutations.concat(naked_selector(node, source, arguments))
        mutations.concat(argument_removals(node, source, arguments, original))
        mutations
      end

      # `a&.b` rewrites into a different control flow when the receiver is
      # dropped, and a naked `b` would lose the safe navigation entirely.
      def self.safe?(node)
        node.call_operator_loc.nil? || node.call_operator_loc.slice == "."
      end

      def self.receiver_removal(node, source, original)
        return [] if node.receiver.nil?

        # The block is dropped with the message: `x` with a block attached is
        # not Ruby.
        [Replacement.new(original: original, replacement: source.slice(node.receiver))]
      end

      def self.naked_selector(node, source, arguments)
        name = node.name.to_s
        return [] unless IDENTIFIER.match?(name)
        return [] if KEYWORDS.include?(name)
        # A receiverless call with no arguments and no block is already naked.
        return [] if node.receiver.nil? && arguments.empty? && node.block.nil?

        original = source.slice(node)
        text = rebuild(node, source, arguments.map { |a| source.slice(a) }, receiver: false)
        return [] if text == original

        [Replacement.new(original: original, replacement: text)]
      end

      def self.argument_removals(node, source, arguments, original)
        name = node.name.to_s
        return [] unless IDENTIFIER.match?(name)
        return [] if arguments.empty?
        return [] unless arguments.all? { |argument| simple?(argument) }

        slices = arguments.map { |argument| source.slice(argument) }
        removals = [Replacement.new(original: original,
                                    replacement: rebuild(node, source, [], receiver: true))]
        if block_pass?(node)
          removals << Replacement.new(
            original: original,
            replacement: rebuild(node, source, slices, receiver: true, keep_block_pass: false)
          )
        end
        arguments.each_index do |index|
          allocatable = slices.each_with_index.map { |slice, i| i == index ? "nil" : slice }
          removals << Replacement.new(
            original: original,
            replacement: rebuild(node, source, allocatable, receiver: true)
          )
        end
        if arguments.length > 1
          arguments.each_index do |index|
            kept = slices.each_with_index.filter_map { |slice, i| slice unless i == index }
            removals << Replacement.new(
              original: original,
              replacement: rebuild(node, source, kept, receiver: true)
            )
          end
        end
        removals
      end

      # A heredoc's node location covers only the opening marker, so splicing
      # its slice would leave the body behind.
      def self.simple?(argument)
        opening = argument.respond_to?(:opening_loc) ? argument.opening_loc : nil
        return true if opening.nil?

        !opening.slice.start_with?("<<")
      end

      # Appends the block back after the call. `node.block` covers `{ ... }`,
      # `do ... end`, and the block-pass form `&:sym` alike. A block-pass has to
      # stay inside the parentheses (`map(&:to_s)`), while a literal block goes
      # after them with a space.
      #
      # +arguments+ are already-rendered source strings, so a caller can pass
      # `"nil"` in place of one of them.
      def self.rebuild(node, source, arguments, receiver:, keep_block_pass: true)
        head = if receiver && node.receiver
                 "#{source.slice(node.receiver)}#{node.call_operator_loc.slice}"
               else
                 ""
               end
        if block_pass?(node)
          passed = keep_block_pass ? [*arguments, source.slice(node.block)] : arguments
          return "#{head}#{node.name}(#{passed.join(", ")})"
        end

        call = if arguments.empty?
                 node.name.to_s
               else
                 "#{node.name}(#{arguments.join(", ")})"
               end
        block = node.block ? " #{source.slice(node.block)}" : ""
        "#{head}#{call}#{block}"
      end

      def self.block_pass?(node)
        node.block.is_a?(Prism::BlockArgumentNode)
      end

      private_class_method :safe?, :receiver_removal, :naked_selector, :argument_removals,
                           :simple?, :rebuild, :block_pass?
    end
  end
end
