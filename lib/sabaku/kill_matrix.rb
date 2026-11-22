# frozen_string_literal: true

require_relative "kills"

module Sabaku
  # Test redundancy over the kill graph the --kill-matrix sweep wrote onto each Result.
  # formal/lean/Sabaku/KillMatrix.lean states the same definitions and proves what the report
  # claims about them; the replay checks this file against Lean.
  #
  #   kept       no other test kills a superset of what it kills
  #   subsumed   kills ⊂ kills(by)
  #   duplicate  kills = kills(by), and by sorts first, so each equal-kill class keeps one test
  #   zero       selected for a scored mutant, killed none
  #   idle       never selected for a scored mutant
  #
  # Only complete rows count. A scored mutant without a row is incomplete, and every test it
  # selected is provisional: completing that row could still change the test's verdict.
  #
  # Dominance holds only inside a group. Under scope :class the group is the test class, so a
  # unit test is never reported redundant because a request test happens to hit the same
  # mutants; under :suite every test shares one group.
  #
  # A row is broad for a group when every test of the group that ran it killed it (at least
  # two did). A broad row cannot tell the group's tests apart: a constant table nobody mutates
  # leaves only the lookup, and breaking the lookup fails every test. A test whose kills are
  # all broad rows has confidence :artifact.
  #
  # tier sorts redundant verdicts by what a reader can do with them:
  #   actionable   a real subset or duplicate, on complete rows
  #   provisional  an incomplete row selected the test, so the verdict may still change
  #   artifact     only broad rows say it is redundant
  class KillMatrix
    VERDICTS = %i[kept subsumed duplicate zero idle].freeze
    SCOPES = %i[class suite].freeze
    TIERS = %i[actionable provisional artifact].freeze

    Verdict = Data.define(:test, :kind, :kills, :unique, :tested, :by, :provisional, :group,
                          :confidence) do
      def redundant? = %i[subsumed duplicate].include?(kind)

      def tier
        return :none unless redundant?
        return :provisional if provisional

        confidence == :artifact ? :artifact : :actionable
      end

      def to_h
        { id: test, verdict: kind, kills: kills, unique: unique, tested: tested, by: by,
          provisional: provisional, group: group, confidence: confidence, tier: tier }
      end
    end

    Incomplete = Data.define(:mutant, :status, :tested)

    # universe: every test id the campaign knows. selected: {mutant id => selected test ids},
    # the only source for an incomplete row's tested set.
    def self.from(results, universe:, selected: {}, scope: :class)
      new(results, universe: universe, selected: selected, scope: scope)
    end

    # A minitest id is "Klass#method", and Klass may hold "::".
    def self.group_of(test)
      cut = test.rindex("#")
      cut ? test[0, cut] : test
    end

    attr_reader :rows, :incomplete, :verdicts, :scope

    def initialize(results, universe:, selected: {}, scope: :class)
      @scope = scope.to_sym
      raise Sabaku::Error, "kill-matrix scope must be one of #{SCOPES.join(", ")}" unless SCOPES.include?(@scope)

      @rows = {}
      @incomplete = []
      results.each do |result|
        next unless result.killed? || result.survived?

        if result.kills
          @rows[result.mutant.id] = result.kills
        else
          tested = Array(selected[result.mutant.id]).map(&:to_s).uniq.sort
          @incomplete << Incomplete.new(mutant: result.mutant, status: result.status, tested: tested)
        end
      end
      tests = Array(universe).map(&:to_s) + @rows.values.flat_map(&:tested) +
              @incomplete.flat_map(&:tested)
      tally(@rows.values)
      provisional = @incomplete.flat_map(&:tested).to_h { |test| [test, true] }
      @verdicts = tests.uniq.sort.map { |test| verdict_for(test, provisional) }.freeze
      @by_test = @verdicts.to_h { |verdict| [verdict.test, verdict] }
    end

    def verdict(test) = @by_test.fetch(test.to_s)

    def ranking
      verdicts.select { |verdict| verdict.kind == :kept }
              .sort_by { |verdict| [-verdict.unique, -verdict.kills, verdict.test] }
    end

    def summary
      counts = VERDICTS.to_h { |kind| [kind, verdicts.count { |verdict| verdict.kind == kind }] }
      counts.merge(provisional: verdicts.count(&:provisional),
                   actionable: verdicts.count { |verdict| verdict.tier == :actionable },
                   artifact: verdicts.count { |verdict| verdict.tier == :artifact })
    end

    def to_h
      {
        rows: rows.size,
        scope: scope,
        groups: verdicts.map(&:group).uniq.size,
        incomplete: incomplete.map do |row|
          { mutant: row.mutant.id, status: row.status, tested: row.tested.size }
        end,
        tests: verdicts.map(&:to_h),
        summary: summary
      }
    end

    private

    # One bitmask per test over complete-row indices, so a subset check is `a & ~b == 0`.
    def tally(rows)
      @row_list = rows
      @row_killers = rows.map(&:killers)
      @mask = Hash.new(0)
      @kills = Hash.new(0)
      @tested = Hash.new(0)
      @unique = Hash.new(0)
      rows.each_with_index do |row, index|
        row.killers.each do |test|
          @mask[test] |= 1 << index
          @kills[test] += 1
        end
        row.tested.each { |test| @tested[test] += 1 }
        @unique[row.killers.first] += 1 if row.killers.size == 1
      end
    end

    def verdict_for(test, provisional)
      kind, by = classify(test, provisional)
      Verdict.new(test: test, kind: kind, kills: @kills[test], unique: @unique[test],
                  tested: @tested[test], by: by, provisional: provisional.key?(test), group: group(test),
                  confidence: confidence(test))
    end

    def confidence(test)
      mask = @mask[test]
      return :strong if mask.zero?

      killed = @row_list.each_index.select { |index| mask[index] == 1 }
      killed.all? { |index| broad?(@row_list[index], group(test)) } ? :artifact : :strong
    end

    def broad?(row, group)
      ran = row.tested.select { |test| group(test) == group }
      ran.size >= 2 && ran.all? { |test| row.killers.include?(test) }
    end

    def group(test) = scope == :suite ? "" : self.class.group_of(test)

    def classify(test, provisional)
      return [:idle, nil] unless @tested[test].positive? || provisional.key?(test)

      mask = @mask[test]
      return [:zero, nil] if mask.zero?

      # The strongest dominator, not the first by id: it is the most useful test to point at,
      # and Lean proves it is always kept.
      by = dominators(test, mask).min_by { |other| [-@kills[other], other] }
      return [:kept, nil] if by.nil?

      [@mask[by] == mask ? :duplicate : :subsumed, by]
    end

    # A superset of this test's kills also kills its rarest mutant, so that row's killers are
    # the only candidates worth a mask check.
    def dominators(test, mask)
      rarest = @row_killers.each_index.select { |index| mask[index] == 1 }
                           .min_by { |index| @row_killers[index].size }
      @row_killers[rarest].select { |other| group(other) == group(test) && dominates?(other, test) }
    end

    def dominates?(other, test)
      return false if other == test

      mine = @mask[test]
      theirs = @mask[other]
      return false unless (mine & ~theirs).zero?

      !(theirs & ~mine).zero? || other < test
    end
  end
end
