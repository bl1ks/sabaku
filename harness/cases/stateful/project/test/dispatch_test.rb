# frozen_string_literal: true

require "minitest/autorun"
require "dispatch"

# The suite shares one desk between its tests on purpose: the tariff is baked by
# whichever test asks first, and the bulk tier a test leaves set is seen by every
# test that follows. Order is alphabetical, so the case can say which test leaks
# into which.
class ParcelTest < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def setup
    @phase_before = Dispatch::DESK.last_phase
    Dispatch::DESK.advance!(:open)
  end

  def teardown
    Dispatch::DESK.advance!(:closed)
  end

  # Runs first on the cold desk, and sets the tier itself so it still holds if a
  # sibling test ran here first.
  def test_about_a_standard_desk
    Dispatch::DESK.tier = :standard
    assert_equal :cold, Dispatch::Desk.new.phase
    assert_equal "single", Dispatch::Parcel.new(2).label
    assert_equal :standard, Dispatch::Parcel.new(9).priority
    assert_equal :express, Dispatch::Parcel.new(10).priority
    assert_equal :bag, Dispatch::Parcel.new(4).handling
    assert_equal :crate, Dispatch::Parcel.new(5).handling
  end

  def test_bulk_charge_rebakes_the_tariff
    Dispatch::DESK.tier = :bulk
    Dispatch::Tariff.forget!
    assert_equal 8, Dispatch::Parcel.new(1).bulk_charge
    assert_equal 2, Dispatch::Parcel.new(1).charge
  end

  # Leaves the bulk tier set: every test after this one runs on a bulk desk.
  def test_bulk_desk_takes_the_bulk_tier
    Dispatch::DESK.tier = :bulk
    parcel = Dispatch::Parcel.new(4)
    assert_equal "bulk", parcel.label
    assert_equal :standard, parcel.priority
    assert_equal :bag, Dispatch::Parcel.new(2).handling
  end

  # Reads the counter relatively: earlier tests already charged, and the phase
  # check is the shared object setup and teardown pass between them.
  def test_charge_records_one_ledger_entry
    before = Dispatch::Ledger.entries
    assert_equal 6, Dispatch::Parcel.new(3).charge
    assert_equal before + 1, Dispatch::Ledger.entries
    assert_equal :open, Dispatch::DESK.phase
    assert_includes [nil, :open], @phase_before
  end

  # The bulk desk reaches this at units 5, so the leaked tier is what decides
  # whether the >= branch runs.
  def test_handling_matches_across_the_boundary
    assert_equal :crate, Dispatch::Parcel.new(5).handling
    assert_equal :bag, Dispatch::Parcel.new(4).handling
  end

  def test_priority_matches_across_the_boundary
    assert_equal :standard, Dispatch::Parcel.new(9).priority
    assert_equal :express, Dispatch::Parcel.new(10).priority
    assert_equal :bag, Dispatch::Parcel.new(4).handling
    assert_equal :crate, Dispatch::Parcel.new(5).handling
    assert_equal 0, Dispatch::Parcel.new(0).tare
    assert_equal 6, Dispatch::Parcel.new(3).charge
  end

  def test_tare_of_an_empty_parcel
    assert_equal 0, Dispatch::Parcel.new(0).tare
  end

  # The table is built once, so moving the tier does not move a rate that was
  # already baked. A rebuild on every read would.
  def test_tariff_is_baked_once
    baked = Dispatch::Tariff.rate(:bulk)
    previous = Dispatch::DESK.tier
    Dispatch::DESK.tier = previous == :bulk ? :standard : :bulk
    assert_equal baked, Dispatch::Tariff.rate(:bulk)
    Dispatch::DESK.tier = previous
  end
end
