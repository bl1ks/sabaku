# frozen_string_literal: true

require_relative "../test_helper"

class ResultTest < Minitest::Test
  Mutant = Struct.new(:id) do
    def to_h = { id: id }
  end

  def row(tested, killers) = Sabaku::Kills.new(tested: tested, killers: killers)

  def build(status, **kwargs) = Sabaku::Result.new(mutant: Mutant.new("m"), status: status, **kwargs)

  def test_a_killed_row_names_its_failed_test
    result = build(:killed, failed_test: "A#t", kills: row(%w[A#t B#t], %w[A#t B#t]))

    assert_equal %w[A#t B#t], result.kills.killers
  end

  def test_a_killed_row_must_contain_the_failed_test
    assert_raises(ArgumentError) { build(:killed, failed_test: "A#t", kills: row(%w[A#t B#t], %w[B#t])) }
  end

  def test_a_killed_row_without_a_killer_is_illegal
    assert_raises(ArgumentError) { build(:killed, kills: row(%w[A#t], [])) }
  end

  def test_a_killed_row_may_lack_a_failed_test_when_the_child_died_before_reporting
    result = build(:killed, kills: row(%w[A#t], %w[A#t]))

    assert_nil result.failed_test
  end

  def test_a_survivor_row_has_no_killers
    assert build(:survived, kills: row(%w[A#t], [])).kills
    assert_raises(ArgumentError) { build(:survived, kills: row(%w[A#t], %w[A#t])) }
  end

  def test_an_unscored_status_has_no_row
    %i[timeout error uncovered skipped].each do |status|
      assert_raises(ArgumentError) { build(status, kills: row(%w[A#t], [])) }
    end
  end

  def test_with_kills_changes_nothing_else
    result = build(:killed, duration: 0.5, failed_test: "A#t", message: "boom")

    swept = result.with_kills(row(%w[A#t B#t], %w[A#t]))

    assert_equal result.to_h, swept.to_h.except(:kills)
    assert_equal({ tested: %w[A#t B#t], killers: %w[A#t] }, swept.to_h[:kills])
  end

  def test_to_h_has_no_kills_key_without_a_row
    refute build(:survived).to_h.key?(:kills)
  end
end
