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

  def matrix(results, universe: [], selected: {})
    Sabaku::KillMatrix.from(results, universe: universe, selected: selected)
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
    assert_equal({ kept: 1, subsumed: 0, duplicate: 1, zero: 0, idle: 1, provisional: 0 },
                 m.to_h[:summary])
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
