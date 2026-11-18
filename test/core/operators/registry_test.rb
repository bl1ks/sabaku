# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class RegistryTest < Minitest::Test
  include CoreTestSupport

  def test_exposes_the_operators_in_stable_order
    expected = %i[aor ror lcr sbr uoi bool str literal selector call cond assign return control]
    assert_equal expected, Mutation::Operator::Registry.ids
    assert_equal expected, Mutation::Operator::Registry.defaults
    assert_equal 14, Mutation::Operator::Registry.all.size
  end

  def test_fetch_returns_the_operator_and_its_metadata
    Mutation::Operator::Registry.ids.each do |id|
      found = Mutation::Operator::Registry.fetch(id)
      assert_equal id, found.id
      refute_empty found.node_types
      assert(found.respond_to?(:mutations))
    end
    assert_equal :aor, Mutation::Operator::Registry.fetch("aor").id
  end

  def test_fetch_rejects_unknown_operators
    assert_raises(KeyError) { Mutation::Operator::Registry.fetch(:nope) }
  end

  def test_operator_ids_are_unique
    ids = Mutation::Operator::Registry.all.map(&:id)
    assert_equal ids.uniq, ids
  end
end
