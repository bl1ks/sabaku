# frozen_string_literal: true

require_relative "../test_helper"

require "json"
require "set"

class CoverageMapTest < Minitest::Test
  def test_empty_map_has_no_tests
    map = Sabaku::CoverageMap.empty

    assert map.empty?
    assert_equal [], map.tests_for("lib/none.rb", 1)
    assert_equal 0, map.size
    assert_equal({ "tests" => {} }, map.to_h)
  end

  def file_coverage(path, state, boot_lines: [], loaded_by: nil)
    Sabaku::CoverageMap::FileCoverage.new(path: path, state: state, boot_lines: boot_lines,
                                          loaded_by: loaded_by)
  end

  def test_a_line_only_the_boot_ran_is_load_time_only
    map = Sabaku::CoverageMap.empty
    map.describe(file_coverage("lib/a.rb", :instrumented, boot_lines: [3, 1]))
    map.record("A#test_a", { "lib/a.rb" => [3] })

    assert map.load_time_only?("lib/a.rb", 1)
    refute map.load_time_only?("lib/a.rb", 3), "a test also ran it"
    refute map.load_time_only?("lib/a.rb", 2), "the boot never ran it"
    refute map.load_time_only?("lib/other.rb", 1)
    assert_equal [1, 3], map.file("lib/a.rb").boot_lines
  end

  def test_file_states_survive_the_json_round_trip
    map = Sabaku::CoverageMap.empty
    map.describe(file_coverage("lib/a.rb", :loaded_during_test, loaded_by: "A#test_a"))
    map.record("A#test_a", { "lib/a.rb" => [3] })

    copy = Sabaku::CoverageMap.from_h(JSON.parse(JSON.generate(map.to_h)))

    assert_equal map, copy
    assert_equal :loaded_during_test, copy.file("lib/a.rb").state
    assert_equal "A#test_a", copy.file("lib/a.rb").loaded_by
  end

  def test_a_file_state_is_a_closed_set
    assert_raises(ArgumentError) { file_coverage("lib/a.rb", :mystery) }
  end

  def test_record_and_tests_for_are_sorted
    map = Sabaku::CoverageMap.empty
    map.record("Zeta#test_z", { "lib/a.rb" => [3, 1, 2] })
    map.record("Alpha#test_a", { "lib/a.rb" => Set[2] })

    assert_equal %w[Alpha#test_a Zeta#test_z], map.tests_for("lib/a.rb", 2)
    assert_equal %w[Zeta#test_z], map.tests_for("lib/a.rb", 3)
    assert_equal [], map.tests_for("lib/a.rb", 99)
    assert_equal [], map.tests_for("lib/other.rb", 2)
  end

  def test_ordering_prefers_the_test_that_walks_more_of_the_file
    map = Sabaku::CoverageMap.empty
    map.record("Narrow#test", { "lib/a.rb" => [2] })
    map.record("Broad#test", { "lib/a.rb" => [1, 2, 3] })
    map.record("Medium#test", { "lib/a.rb" => [2, 3] })

    assert_equal %w[Broad#test Medium#test Narrow#test],
                 map.ordered_tests_for_span("lib/a.rb", 2, 2)
    assert_equal 3, map.reach("lib/a.rb", "Broad#test")
    assert_equal 0, map.reach("lib/b.rb", "Broad#test")
    # The plain query stays sorted by id so callers that do not care about
    # order are unaffected.
    assert_equal %w[Broad#test Medium#test Narrow#test], map.tests_for("lib/a.rb", 2)
  end

  def test_recording_the_same_test_twice_unions_hits
    map = Sabaku::CoverageMap.empty
    map.record("T#one", { "lib/a.rb" => [1] })
    map.record("T#one", { "lib/a.rb" => [2], "lib/b.rb" => [7] })

    assert_equal ["T#one"], map.tests_for("lib/a.rb", 1)
    assert_equal ["T#one"], map.tests_for("lib/a.rb", 2)
    assert_equal ["T#one"], map.tests_for("lib/b.rb", 7)
  end

  def test_merge_is_non_destructive
    left = Sabaku::CoverageMap.empty
    left.record("A#a", { "lib/x.rb" => [1, 2] })
    right = Sabaku::CoverageMap.empty
    right.record("B#b", { "lib/x.rb" => [2, 3] })

    merged = left.merge(right)

    assert_equal %w[A#a B#b], merged.tests_for("lib/x.rb", 2)
    assert_equal %w[A#a], merged.tests_for("lib/x.rb", 1)
    assert_equal %w[B#b], merged.tests_for("lib/x.rb", 3)
    assert_equal ["A#a"], left.tests_for("lib/x.rb", 2)
    assert_equal ["B#b"], right.tests_for("lib/x.rb", 2)
  end

  def test_json_round_trip
    map = Sabaku::CoverageMap.empty
    map.record("../outside.rb", { "lib/foo.rb" => [10, 4], "lib/bar.rb" => Set[1] })
    map.record("Other#test", { "lib/bar.rb" => [1, 2] })

    json = JSON.generate(map.to_h)
    restored = Sabaku::CoverageMap.from_h(JSON.parse(json))

    assert_equal map, restored
    assert_equal map.to_h, restored.to_h
    assert_equal ["../outside.rb", "Other#test"], restored.tests_for("lib/bar.rb", 1)
    assert_equal ["../outside.rb"], restored.tests_for("lib/foo.rb", 10)
  end

  def test_from_h_accepts_bare_hash
    map = Sabaku::CoverageMap.from_h("T#test" => { "lib/a.rb" => [5] })

    assert_equal ["T#test"], map.tests_for("lib/a.rb", 5)
  end

  def test_merge_rejects_non_map
    assert_raises(ArgumentError) { Sabaku::CoverageMap.empty.merge({}) }
  end
end
