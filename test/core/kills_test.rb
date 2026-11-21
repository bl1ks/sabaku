# frozen_string_literal: true

require_relative "../test_helper"

class KillsTest < Minitest::Test
  def test_a_row_is_sorted_deduplicated_and_frozen
    kills = Sabaku::Kills.new(tested: ["B#t", :"A#t", "B#t"], killers: ["B#t"])

    assert_equal ["A#t", "B#t"], kills.tested
    assert_equal ["B#t"], kills.killers
    assert_predicate kills.tested, :frozen?
    assert_equal kills, Sabaku::Kills.new(tested: ["A#t", "B#t"], killers: ["B#t", "B#t"])
  end

  def test_a_killer_must_have_been_tested
    error = assert_raises(ArgumentError) { Sabaku::Kills.new(tested: ["A#t"], killers: ["B#t"]) }

    assert_match(/killers outside tested/, error.message)
  end

  def test_killed_means_a_killer
    refute_predicate Sabaku::Kills.new(tested: ["A#t"], killers: []), :killed?
    assert_predicate Sabaku::Kills.new(tested: ["A#t"], killers: ["A#t"]), :killed?
  end
end
