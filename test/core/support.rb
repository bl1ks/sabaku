# frozen_string_literal: true

require "prism"

module CoreTestSupport
  def source(text, path = "test/subject.rb")
    Sabaku::Source.new(path, text)
  end

  def operator(id)
    Sabaku::Operator::Registry.fetch(id)
  end

  def analyze(sources, **overrides)
    list = sources.is_a?(Array) ? sources : [sources]
    Sabaku::Analyzer.new(list, Sabaku::Config.default(**overrides)).mutants
  end

  def build_mutant(source, node, operator, replacement)
    location = node.location
    Sabaku::Mutant.new(
      path: source.rel_path,
      operator: operator.id,
      line: replacement.line || location.start_line,
      column: location.start_column,
      node_kind: node.class.name.split("::").last,
      original: replacement.original,
      replacement: replacement.replacement,
      start_offset: location.start_offset,
      end_offset: location.end_offset
    )
  end

  def mutants_for(source, operator_id)
    selected = operator(operator_id)
    source.flat_nodes.flat_map do |node|
      next [] unless selected.node_types.any? { |node_class| node.is_a?(node_class) }

      selected.mutations(node, source).map do |replacement|
        build_mutant(source, node, selected, replacement)
      end
    end
  end

  def each_node_with_ancestors(source, node = source.ast, ancestors = [], &block)
    block.call(node, ancestors)
    node.compact_child_nodes.each do |child|
      each_node_with_ancestors(source, child, ancestors + [node], &block)
    end
  end

  def find_node(source, type, name: nil)
    each_node_with_ancestors(source) do |node, ancestors|
      next unless node.is_a?(type)
      next if name && !(node.respond_to?(:name) && node.name == name)

      return [node, ancestors]
    end
    raise "no #{type} node#{name ? " named #{name.inspect}" : ""} in source"
  end

  def assert_valid_ruby(text, message = nil)
    result = Prism.parse(text)
    assert_empty(result.errors.map(&:message), message || "expected valid Ruby:\n#{text}")
  end

  def assert_mutants_parse(source, mutants)
    mutants.each do |mutant|
      assert_valid_ruby(mutant.splice(source.text), "mutant did not re-parse: #{mutant.description}")
    end
  end
end
