# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support"

class SourceTest < Minitest::Test
  include CoreTestSupport

  TEXT = "total = price * 0.15\nputs total\n"

  def setup
    @source = source(TEXT, "lib/pricing.rb")
  end

  def test_exposes_path_text_and_root
    assert_equal "lib/pricing.rb", @source.rel_path
    assert_equal TEXT, @source.text
    assert @source.text.frozen?
    assert @source.frozen?
    assert_instance_of Prism::ProgramNode, @source.ast
    assert_same @source.ast, @source.ast
  end

  def test_text_is_a_copy_of_the_input
    mutable = +"a = 1\n"
    built = source(mutable)
    mutable << "b = 2\n"
    assert_equal "a = 1\n", built.text
  end

  def test_slice_returns_exact_source_text
    call = @source.flat_nodes.find { |node| node.is_a?(Prism::CallNode) && node.name == :* }
    assert_equal "price * 0.15", @source.slice(call)
    assert_equal "total = price * 0.15\nputs total", @source.slice(@source.ast.statements)
  end

  def test_line_of_is_one_based
    assert_equal 1, @source.line_of(0)
    assert_equal 1, @source.line_of(TEXT.index("price"))
    assert_equal 2, @source.line_of(TEXT.index("puts"))
  end

  def test_line_of_counts_bytes_not_characters
    text = "π = 1\ntotal = 2\n"
    built = source(text)
    assert_equal 2, built.line_of("π = 1\n".bytesize)
    assert_equal 2, built.line_of(text.bytesize - 1)
  end

  def test_flat_nodes_is_preorder_and_excludes_root
    enumerator = @source.flat_nodes
    assert_instance_of Enumerator, enumerator

    nodes = @source.flat_nodes.to_a
    refute(nodes.any? { |node| node.is_a?(Prism::ProgramNode) })
    assert_equal [Prism::StatementsNode, Prism::LocalVariableWriteNode, Prism::CallNode],
                 nodes.first(3).map(&:class)
    assert_equal "total = price * 0.15\nputs total", nodes.first.location.slice
    assert_equal "0.15", nodes[5].location.slice
  end
end
