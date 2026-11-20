# frozen_string_literal: true

require_relative "replacement"
require_relative "support"
require_relative "../aridity"

module Sabaku
  module Operator
    # Statement Block Removal: delete one statement from a multi-statement list. The last
    # statement of a method body is kept because removing it would change the return value.
    module Sbr
      def self.id
        :sbr
      end

      def self.node_types
        [Prism::StatementsNode]
      end

      def self.mutations(node, source)
        statements = node.body
        return [] if statements.length < 2

        parent = Support.parent_of(node, source)
        original = source.slice(node)
        aridity = Aridity.new
        removable_indices(parent, statements).reject do |index|
          aridity.arid?(statements[index], [node])
        end.map do |index|
          Replacement.new(
            original: original,
            replacement: rebuild(statements, index, node, source),
            line: statements[index].location.start_line
          )
        end
      end

      # Containers whose statements declare names rather than run behaviour. A mutant that
      # deletes a `def` there is unkillable by construction: the runner applies a mutation by
      # re-evaluating the file, and re-evaluating a class body redefines methods but never
      # undefines one, so the deleted definition is still there when the tests run.
      DECLARATION_CONTAINERS = [
        Prism::ProgramNode,
        Prism::ClassNode,
        Prism::ModuleNode,
        Prism::SingletonClassNode
      ].freeze

      def self.removable_indices(parent, statements)
        return [] if DECLARATION_CONTAINERS.any? { |klass| parent.is_a?(klass) }

        indices = (0...statements.length).to_a
        indices = indices[0...-1] if parent.is_a?(Prism::DefNode)
        indices
      end

      def self.rebuild(statements, index, node, source)
        kept = statements.each_with_index.filter_map { |statement, i| statement unless i == index }
        indent = " " * node.location.start_column
        rebuilt = source.slice(kept.first).dup
        kept.drop(1).each do |statement|
          rebuilt << "\n" << indent << source.slice(statement)
        end
        rebuilt
      end

      private_class_method :removable_indices, :rebuild
    end
  end
end
