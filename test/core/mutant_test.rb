# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support"

class MutantTest < Minitest::Test
  include CoreTestSupport

  TEXT = "first = 1\ntotal = a + b\nlast = 2\n"

  def setup
    @source = source(TEXT, "lib/pricing.rb")
    @node = @source.flat_nodes.find { |node| node.is_a?(Prism::CallNode) && node.name == :+ }
  end

  def mutant(replacement: "a - b", start_offset: @node.location.start_offset,
             end_offset: @node.location.end_offset, path: "lib/pricing.rb", id: nil,
             scope: "top", ast_path: "1/1")
    Sabaku::Mutant.new(
      id: id,
      path: path,
      operator: :aor,
      line: @node.location.start_line,
      column: @node.location.start_column,
      node_kind: "CallNode",
      original: "a + b",
      replacement: replacement,
      start_offset: start_offset,
      end_offset: end_offset,
      scope: scope,
      ast_path: ast_path
    )
  end

  def test_id_is_stable_and_position_independent
    first = mutant
    second = mutant

    assert_match(/\A[0-9a-f]{16}\z/, first.id)
    assert_equal first.id, second.id
    refute_equal first.id, mutant(replacement: "a * b").id
    refute_equal first.id, mutant(path: "lib/other.rb").id
    assert_equal first.id, mutant(start_offset: 0, end_offset: 3).id,
                 "a move alone must not invalidate the cache entry"
    refute_equal first.id, mutant(scope: "Pricing#total").id
    refute_equal first.id, mutant(ast_path: "0/1").id
  end

  def test_explicit_id_is_kept
    built = mutant(id: "fixed-id")
    assert_equal "fixed-id", built.id
  end

  def test_splice_replaces_only_the_node_offsets
    spliced = mutant.splice(TEXT)

    assert_equal "first = 1\ntotal = a - b\nlast = 2\n", spliced
    assert_equal TEXT, @source.text
    assert_equal "first = 1\ntotal = a + b\nlast = 2\n", mutant.splice(TEXT).sub("a - b", "a + b")
  end

  def test_splice_produces_parseable_ruby
    assert_valid_ruby(mutant.splice(TEXT))
  end

  def test_splice_uses_byte_offsets
    text = "π = 1\ntotal = a + b\n"
    built = source(text, "lib/unicode.rb")
    node = built.flat_nodes.find { |candidate| candidate.is_a?(Prism::CallNode) && candidate.name == :+ }
    target = Sabaku::Mutant.new(
      path: built.rel_path,
      operator: :aor,
      line: node.location.start_line,
      column: node.location.start_column,
      node_kind: "CallNode",
      original: "a + b",
      replacement: "a % b",
      start_offset: node.location.start_offset,
      end_offset: node.location.end_offset
    )

    assert_equal "π = 1\ntotal = a % b\n", target.splice(text)
    assert_valid_ruby(target.splice(text))
  end

  def test_description_names_the_operator_and_both_sides
    assert_equal "AOR: a + b -> a - b", mutant.description
  end

  def test_to_h_carries_offsets_and_round_trips
    built = mutant
    hash = built.to_h

    assert_equal built.id, hash[:id]
    assert_equal "lib/pricing.rb", hash[:path]
    assert_equal :aor, hash[:operator]
    assert_equal 2, hash[:line]
    assert_equal @node.location.start_column, hash[:column]
    assert_equal "CallNode", hash[:node_kind]
    assert_equal built.start_offset, hash[:start_offset]
    assert_equal built.end_offset, hash[:end_offset]
    assert_equal built, Sabaku::Mutant.new(**hash)
  end

  def test_value_is_frozen
    assert_predicate mutant, :frozen?
  end
end
