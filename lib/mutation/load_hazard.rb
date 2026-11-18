# frozen_string_literal: true

require "prism"

module Mutation
  # Whether loading a file can do more than define things. Fork isolation applies
  # a mutant by re-running the mutated file over the parent's already-loaded
  # copy, so a file that registers itself at load time runs that registration
  # twice inside every child. A test that counts the registrations then fails for
  # a reason the mutation did not cause.
  #
  # The screen is deliberately about *calls*: re-executing a class body made only
  # of `def`, `alias`, constants and the decorators below cannot be observed as a
  # second load, because each name is simply redefined to the value the file
  # already meant. Anything else is unknown code, and unknown code at load time is
  # what the runner has to check rather than assume.
  module LoadHazard
    # Decorators whose second run is a no-op. Everything else is unknown.
    IDEMPOTENT = %i[
      require require_relative load
      include extend prepend
      attr attr_reader attr_writer attr_accessor
      private protected public module_function
      private_constant public_constant private_class_method public_class_method
      alias_method define_method
    ].freeze

    # Constant writes whose value builds a new class or module object, so a second
    # load hands callers a different object than the one they captured.
    BUILDERS = %i[new define].freeze

    module_function

    def sensitive?(ast)
      return false if ast.nil?

      walk(ast)
    end

    def walk(node)
      case node
      when Prism::ProgramNode
        node.statements ? walk(node.statements) : false
      when Prism::DefNode, Prism::SingletonClassNode
        false
      when Prism::ClassNode
        return true if builder?(node.superclass)

        node.body ? walk(node.body) : false
      when Prism::ModuleNode
        node.body ? walk(node.body) : false
      when Prism::StatementsNode
        node.body.any? { |child| walk(child) }
      when Prism::CallNode
        return false if node.receiver.nil? && IDEMPOTENT.include?(node.name)

        true
      when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        builder?(node.value)
      when Prism::AliasMethodNode, Prism::AliasGlobalVariableNode
        false
      when Prism::BeginNode
        statements = node.statements
        statements ? statements.body.any? { |child| walk(child) } : false
      else
        # Anything that is not a definition runs at load time.
        true
      end
    end

    def builder?(node)
      return false unless node.is_a?(Prism::CallNode)
      return true unless node.block.nil?

      BUILDERS.include?(node.name)
    end
  end
end
