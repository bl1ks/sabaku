# frozen_string_literal: true

require_relative "../test_helper"

class KillMatrixTest < Minitest::Test
  Mutant = Struct.new(:id)

  def killed(id, killers, tested: killers)
    Sabaku::Result.new(mutant: Mutant.new(id), status: :killed, failed_test: killers.min,
                       kills: Sabaku::Kills.new(tested: tested, killers: killers))
  end

  def survived(id, tested)
    Sabaku::Result.new(mutant: Mutant.new(id), status: :survived,
                       kills: Sabaku::Kills.new(tested: tested, killers: []))
  end

  # The dominance algebra below is about one group, so the plain ids share the suite's.
  def matrix(results, universe: [], selected: {}, scope: :suite)
    Sabaku::KillMatrix.from(results, universe: universe, selected: selected, scope: scope)
  end

  def kind(matrix, test) = matrix.verdict(test).kind

  def test_each_verdict_kind
    m = matrix(
      [killed("m1", %w[strong weak], tested: %w[smoke strong weak]),
       killed("m2", %w[strong], tested: %w[smoke strong weak]),
       killed("m3", %w[only], tested: %w[only])],
      universe: %w[idle only smoke strong weak]
    )

    assert_equal :kept, kind(m, "strong")
    assert_equal :subsumed, kind(m, "weak")
    assert_equal "strong", m.verdict("weak").by
    assert_equal :kept, kind(m, "only")
    assert_equal 1, m.verdict("only").unique
    assert_equal :zero, kind(m, "smoke")
    assert_equal :idle, kind(m, "idle")
  end

  def test_equal_kill_sets_keep_the_smallest_id
    m = matrix([killed("m1", %w[a b c]), killed("m2", %w[a b c])])

    assert_equal :kept, kind(m, "a")
    assert_equal [:duplicate, "a"], [kind(m, "b"), m.verdict("b").by]
    assert_equal [:duplicate, "a"], [kind(m, "c"), m.verdict("c").by]
  end

  def test_a_chain_points_at_its_strongest_test
    m = matrix([killed("m1", %w[a b c]), killed("m2", %w[b c]), killed("m3", %w[c])])

    assert_equal "c", m.verdict("a").by
    assert_equal "c", m.verdict("b").by
    assert_equal :kept, kind(m, "c")
  end

  def test_by_prefers_more_kills_over_a_smaller_id
    m = matrix([killed("m1", %w[a t z]), killed("m2", %w[a]), killed("m3", %w[z]),
                killed("m4", %w[z])])

    assert_equal [:subsumed, "z"], [kind(m, "t"), m.verdict("t").by]
    assert_equal :kept, kind(m, "a")
  end

  def test_incomplete_rows_are_excluded_and_mark_their_tests_provisional
    incomplete = Sabaku::Result.new(mutant: Mutant.new("m2"), status: :killed, failed_test: "a")
    m = matrix([killed("m1", %w[a b]), incomplete, survived("m3", %w[c])],
               universe: %w[a b c d], selected: { "m2" => %w[a d] })

    assert_equal %w[m1 m3], m.rows.keys
    assert_equal [%w[a d]], m.incomplete.map(&:tested)
    assert m.verdict("a").provisional
    assert m.verdict("d").provisional
    refute m.verdict("b").provisional
    assert_equal :zero, kind(m, "d")
    assert_equal :zero, kind(m, "c")
  end

  def test_unscored_results_are_outside_the_matrix
    timeout = Sabaku::Result.new(mutant: Mutant.new("m2"), status: :timeout)
    m = matrix([killed("m1", %w[a]), timeout], universe: %w[a])

    assert_empty m.incomplete
    assert_equal 1, m.rows.size
  end

  def test_ranking_orders_kept_tests_by_unique_then_kills
    m = matrix([killed("m1", %w[a]), killed("m2", %w[b]), killed("m3", %w[b]),
                killed("m4", %w[a c]), killed("m5", %w[c])])

    assert_equal %w[b a c], m.ranking.map(&:test)
  end

  def test_to_h_lists_tests_by_id
    m = matrix([killed("m1", %w[b a])], universe: %w[c])

    assert_equal %w[a b c], m.to_h[:tests].map { |test| test[:id] }
    assert_equal({ kept: 1, subsumed: 0, duplicate: 1, zero: 0, idle: 1, provisional: 0,
                   actionable: 0, artifact: 1 }, m.to_h[:summary])
  end

  def test_a_test_class_is_its_own_dominance_group
    rows = [killed("m1", %w[LibTest#test_a RequestTest#test_b RequestTest#test_c]),
            killed("m2", %w[RequestTest#test_b])]

    by_class = Sabaku::KillMatrix.from(rows, universe: [])
    assert_equal :kept, kind(by_class, "LibTest#test_a")
    assert_equal "LibTest", by_class.verdict("LibTest#test_a").group
    assert_equal [:subsumed, "RequestTest#test_b"],
                 [kind(by_class, "RequestTest#test_c"), by_class.verdict("RequestTest#test_c").by]

    suite = matrix(rows, scope: :suite)
    assert_equal [:subsumed, "RequestTest#test_b"],
                 [kind(suite, "LibTest#test_a"), suite.verdict("LibTest#test_a").by]
    assert_equal "", suite.verdict("LibTest#test_a").group
  end

  def test_the_group_is_the_id_before_the_last_hash
    assert_equal "Pack::WidgetTest", Sabaku::KillMatrix.group_of("Pack::WidgetTest#test_a")
    assert_equal "loose", Sabaku::KillMatrix.group_of("loose")
  end

  def test_to_h_names_the_scope_and_counts_the_groups
    m = Sabaku::KillMatrix.from([killed("m1", %w[A#test_x B#test_y])], universe: %w[C#test_z])

    assert_equal [:class, 3], m.to_h.values_at(:scope, :groups)
    assert_equal [:suite, 1], matrix([killed("m1", %w[A#test_x B#test_y])]).to_h.values_at(:scope, :groups)
  end

  # S: a lookup every test hits, so every S test kills m1 and that row tells them apart not at all.
  # P: a real subset. Q: a subset whose test also sits on an incomplete row.
  def test_redundant_verdicts_are_tiered
    incomplete = Sabaku::Result.new(mutant: Mutant.new("m7"), status: :killed, failed_test: "Q#q")
    m = Sabaku::KillMatrix.from(
      [killed("m1", %w[S#a S#b S#c]),
       killed("m3", %w[P#x P#y], tested: %w[P#x P#y P#z]),
       killed("m4", %w[P#x], tested: %w[P#x P#y P#z]),
       killed("m5", %w[Q#p Q#q], tested: %w[Q#p Q#q Q#r]),
       killed("m6", %w[Q#p], tested: %w[Q#p Q#q Q#r]),
       killed("m8", %w[L#solo]),
       incomplete],
      universe: [], selected: { "m7" => %w[Q#q] }
    )

    tiers = m.verdicts.to_h { |verdict| [verdict.test, [verdict.kind, verdict.tier]] }
    assert_equal({ "L#solo" => %i[kept none], "P#x" => %i[kept none], "P#y" => %i[subsumed actionable],
                   "P#z" => %i[zero none], "Q#p" => %i[kept none], "Q#q" => %i[subsumed provisional],
                   "Q#r" => %i[zero none], "S#a" => %i[kept none], "S#b" => %i[duplicate artifact],
                   "S#c" => %i[duplicate artifact] }, tiers)
    assert_equal :artifact, m.verdict("S#a").confidence
    assert_equal :strong, m.verdict("L#solo").confidence
    assert_equal({ actionable: 1, artifact: 2 }, m.summary.slice(:actionable, :artifact))
    assert_equal({ confidence: :artifact, tier: :artifact }, m.verdict("S#b").to_h.slice(:confidence, :tier))
  end

  def test_a_row_is_broad_only_inside_the_group_that_all_killed_it
    m = Sabaku::KillMatrix.from(
      [killed("m1", %w[A#x A#y B#u], tested: %w[A#x A#y B#u B#v]),
       killed("m2", %w[B#u B#v])],
      universe: []
    )

    assert_equal %i[duplicate artifact], [m.verdict("A#y").kind, m.verdict("A#y").tier]
    assert_equal :strong, m.verdict("B#u").confidence
  end

  def test_an_unknown_scope_is_refused
    assert_raises(Sabaku::Error) { Sabaku::KillMatrix.from([], universe: [], scope: :pack) }
  end

  # The definitions straight from the Lean model, with no bitmasks and no candidate filter.
  def oracle(rows, tests)
    kills = tests.to_h { |t| [t, rows.each_index.select { |i| rows[i].include?(t) }] }
    dom = lambda do |other, t|
      sub = (kills[t] - kills[other]).empty?
      back = (kills[other] - kills[t]).empty?
      other != t && sub && (!back || other < t)
    end
    tests.to_h do |t|
      next [t, [:zero, nil]] if kills[t].empty?

      by = tests.select { |other| dom.call(other, t) }.min_by { |other| [-kills[other].size, other] }
      next [t, [:kept, nil]] if by.nil?

      [t, [kills[by] == kills[t] ? :duplicate : :subsumed, by]]
    end
  end

  def test_class_scope_is_the_suite_verdict_within_each_class_on_random_graphs
    random = Random.new(20_261_122)
    200.times do |round|
      tests = Array.new(random.rand(1..6)) { |i| "#{%w[A B].sample(random: random)}#t#{i}" }.uniq
      rows = Array.new(random.rand(1..8)) { tests.select { random.rand < 0.4 } }
      results = rows.each_with_index.map do |killers, i|
        killers.empty? ? survived("m#{i}", tests) : killed("m#{i}", killers, tested: tests)
      end
      by_class = Sabaku::KillMatrix.from(results, universe: tests)

      tests.group_by { |t| t[0] }.each_value do |group|
        expected = oracle(rows.map { |killers| killers & group }, group)
        group.each do |t|
          assert_equal expected[t], [kind(by_class, t), by_class.verdict(t).by], "round #{round}, test #{t}"
        end
      end
    end
  end

  def test_matches_the_definitions_and_keeps_every_kill_on_random_graphs
    random = Random.new(20_261_121)
    200.times do |round|
      tests = Array.new(random.rand(1..6)) { |i| "T#{i}" }
      rows = Array.new(random.rand(1..8)) { tests.select { random.rand < 0.4 } }
      rows << rows.first.dup if random.rand < 0.5
      results = rows.each_with_index.map do |killers, i|
        killers.empty? ? survived("m#{i}", tests) : killed("m#{i}", killers, tested: tests)
      end
      m = matrix(results, universe: tests)

      expected = oracle(rows, tests)
      tests.each do |t|
        assert_equal expected[t], [kind(m, t), m.verdict(t).by], "round #{round}, test #{t}"
      end
      kept = m.verdicts.select { |v| v.kind == :kept }.map(&:test)
      rows.each do |killers|
        assert_equal killers.any?, killers.intersect?(kept), "round #{round}: a kill was lost"
      end
      m.verdicts.select(&:redundant?).each do |verdict|
        assert_equal :kept, kind(m, verdict.by), "round #{round}: by #{verdict.by} is not kept"
      end
    end
  end
end
