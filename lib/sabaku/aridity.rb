# frozen_string_literal: true

require "prism"

module Sabaku
  # Implements the paper's aridity rules for Ruby. A simple node is arid when one expert rule
  # matches; a compound node is arid when every child is arid.
  class Aridity
    OUTPUT_METHODS = %i[puts print p pp warn printf].freeze
    REQUIRE_METHODS = %i[require require_relative load autoload].freeze
    DECLARATION_METHODS = %i[
      attr_accessor attr_reader attr_writer include extend prepend private protected public
      module_function alias_method using
      sig abstract! interface! final! sealed! mixes_in_class_methods requires_ancestor
    ].freeze
    # `T.let(value, Type)` and its kind: the value is behaviour, the type only a runtime check.
    # `T.must` is absent on purpose, because dropping it removes a real nil check.
    TYPE_CALLS = %i[let cast bind assert_type! must_because].freeze
    STRUCT_FIELDS = %i[const prop].freeze
    STRUCT_SUPERCLASSES = %w[T::Struct T::InexactStruct ::T::Struct ::T::InexactStruct].freeze
    MUTABLE_FIELD_OPTIONS = %i[default factory].freeze
    SUPPRESSED_DEF_METHODS = %i[
      to_s inspect hash == eql? <=> method_missing respond_to_missing?
    ].freeze
    MAGIC_METHODS = %i[__method__ __dir__].freeze
    FROZEN_METHODS = %i[freeze frozen?].freeze
    IVAR_WRITE_NODES = [
      Prism::InstanceVariableWriteNode,
      Prism::InstanceVariableOperatorWriteNode,
      Prism::InstanceVariableOrWriteNode,
      Prism::InstanceVariableAndWriteNode
    ].freeze
    CONSTANT_WRITE_NODES = [
      Prism::ConstantWriteNode,
      Prism::ConstantOrWriteNode,
      Prism::ConstantAndWriteNode,
      Prism::ConstantOperatorWriteNode,
      Prism::ConstantPathWriteNode,
      Prism::ConstantPathOrWriteNode,
      Prism::ConstantPathAndWriteNode,
      Prism::ConstantPathOperatorWriteNode
    ].freeze
    LOGGER_RECEIVER = /\A(?:@?logger|Rails\.logger)(?:\.|\z)/.freeze
    UPPERCASE_CONSTANT = /\A[A-Z][A-Z0-9_]*\z/.freeze

    def self.type_call?(node)
      node.is_a?(Prism::CallNode) && TYPE_CALLS.include?(node.name) &&
        node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :T && !node.arguments.nil?
    end

    def arid?(node, ancestors = [])
      return true if suppressed_definition_ancestor?(ancestors)
      return true if type_argument?(node, ancestors)
      return true if expert_arid?(node, ancestors)

      children = node.compact_child_nodes
      return false if children.empty?

      children.all? { |child| arid?(child, ancestors + [node]) }
    end

    private

    def expert_arid?(node, ancestors)
      case node
      when Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode
        guarded_statement_arid?(node, ancestors)
      when Prism::CallNode
        call_arid?(node)
      when Prism::SourceFileNode
        true
      when Prism::StringNode, Prism::SymbolNode, Prism::InterpolatedStringNode
        argument_of_arid_call?(node, ancestors)
      when Prism::DefNode
        suppressed_definition?(node)
      else
        constant_write_arid?(node)
      end
    end

    def guarded_statement_arid?(node, ancestors)
      return false if node.respond_to?(:subsequent) && !node.subsequent.nil?
      return false if node.respond_to?(:else_clause) && !node.else_clause.nil?

      statements = node.statements
      body = statements.is_a?(Prism::StatementsNode) ? statements.body : Array(statements)
      return false if body.empty?

      body.all? { |statement| arid?(statement, ancestors + [node]) }
    end

    def call_arid?(node)
      return true if FROZEN_METHODS.include?(node.name)
      return true if MAGIC_METHODS.include?(node.name) && node.receiver.nil?
      return true if output_call?(node)
      return true if require_call?(node)
      return true if declaration_call?(node)

      logger_call?(node)
    end

    def output_call?(node)
      return true if node.receiver.nil? && OUTPUT_METHODS.include?(node.name)
      return true if kernel_receiver?(node.receiver) && OUTPUT_METHODS.include?(node.name)

      io_receiver?(node.receiver)
    end

    def require_call?(node)
      REQUIRE_METHODS.include?(node.name) &&
        (node.receiver.nil? || kernel_receiver?(node.receiver))
    end

    def declaration_call?(node)
      node.receiver.nil? && DECLARATION_METHODS.include?(node.name)
    end

    def logger_call?(node)
      receiver = node.receiver
      return false if receiver.nil?

      LOGGER_RECEIVER.match?(receiver.slice) || receiver.slice.include?("ActiveSupport::Logger")
    end

    def kernel_receiver?(receiver)
      receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Kernel
    end

    def io_receiver?(receiver)
      receiver.is_a?(Prism::GlobalVariableReadNode) &&
        %i[$stdout $stderr].include?(receiver.name)
    end

    def argument_of_arid_call?(node, ancestors)
      ancestors.reverse_each do |ancestor|
        next unless ancestor.is_a?(Prism::CallNode) && call_arid?(ancestor)

        arguments = ancestor.arguments
        next if arguments.nil?

        if node.location.start_offset >= arguments.location.start_offset &&
           node.location.end_offset <= arguments.location.end_offset
          return true
        end
      end
      false
    end

    # Both scans use `any?`, so the verdict does not depend on the order of the ancestors.
    # A `const` outside a `T::Struct` is someone else's helper and keeps its arguments.
    def type_argument?(node, ancestors)
      type_call = ancestors.any? do |ancestor|
        self.class.type_call?(ancestor) && within?(node, ancestor.arguments.arguments.drop(1))
      end
      return true if type_call

      ancestors.any? { |ancestor| struct_class?(ancestor) } &&
        ancestors.any? { |ancestor| struct_field?(ancestor) && within?(node, field_type_arguments(ancestor)) }
    end

    def struct_class?(node)
      node.is_a?(Prism::ClassNode) && STRUCT_SUPERCLASSES.include?(node.superclass&.slice)
    end

    def struct_field?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && STRUCT_FIELDS.include?(node.name) &&
        !node.arguments.nil?
    end

    def field_type_arguments(call)
      call.arguments.arguments.drop(1).flat_map do |argument|
        next [argument] unless argument.is_a?(Prism::KeywordHashNode)

        argument.elements.reject do |element|
          element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
            MUTABLE_FIELD_OPTIONS.include?(element.key.unescaped.to_sym)
        end
      end
    end

    def within?(node, arguments)
      arguments.any? do |argument|
        node.location.start_offset >= argument.location.start_offset &&
          node.location.end_offset <= argument.location.end_offset
      end
    end

    def suppressed_definition_ancestor?(ancestors)
      ancestors.any? do |ancestor|
        ancestor.is_a?(Prism::DefNode) && suppressed_definition?(ancestor)
      end
    end

    def suppressed_definition?(node)
      return true if SUPPRESSED_DEF_METHODS.include?(node.name)

      node.name == :initialize && ivar_only_body?(node.body)
    end

    def ivar_only_body?(body)
      return false if body.nil?

      statements = body.is_a?(Prism::StatementsNode) ? body.body : [body]
      !statements.empty? && statements.all? do |statement|
        IVAR_WRITE_NODES.any? { |node_class| statement.is_a?(node_class) }
      end
    end

    def constant_write_arid?(node)
      CONSTANT_WRITE_NODES.any? do |node_class|
        next false unless node.is_a?(node_class)

        name = node.respond_to?(:name) ? node.name : node.target.name
        UPPERCASE_CONSTANT.match?(name.to_s)
      end
    end
  end
end
