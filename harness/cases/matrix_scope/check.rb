# frozen_string_literal: true

require_relative "../../lib/support"

# Claim: under the default class scope, the kill matrix never lists a test as redundant
# because a test of another class kills the same mutants, and it still lists a real
# duplicate inside one class.
#
# Falsified by: an actionable verdict whose `by` names a test of another class; no
# actionable verdict at all on a fixture that plants an in-class duplicate; or a fixture on
# which `--kill-matrix-scope=suite` reports no cross-class redundancy, since then the class
# scope had nothing to remove and the first check proves nothing. The matrix must not move
# the score.
#
# The project has unit tests (TillTest, with test_total_again a copy of test_total, and
# test_total_is_a_number, which runs total but misses most of its mutants, so the pair's rows
# are not ones every TillTest test kills) and one request-style test (CheckoutTest) that
# drives every method of the same class.
practical_case("matrix_scope") do |k|
  cold = { "SABAKU_NO_CACHE" => "1" }
  args = ["lib", "--per-line=all", "--timeout=30", "--kill-matrix"]
  group = ->(id) { id.rpartition("#").first }

  k.copy_project do |dir|
    plain = k.campaign(dir, "lib", "--per-line=all", "--timeout=30", env: cold)
    scoped = k.campaign(dir, *args, env: cold)
    suite = k.campaign(dir, *args, "--kill-matrix-scope=suite", env: cold)

    k.assert_equal("the matrix does not move the score", plain["score"], scoped["score"])
    k.assert_equal("the default scope is class", "class", scoped.dig("kill_matrix", "scope"))

    tests = scoped.dig("kill_matrix", "tests")
    actionable = tests.select { |test| test["tier"] == "actionable" }
    crossing = actionable.reject { |test| group.call(test["by"].to_s) == group.call(test["id"]) }
    k.assert("no actionable verdict crosses a test class", crossing.empty?,
             crossing.map { |test| "#{test['id']} by #{test['by']}" }.join("; "))
    k.assert("every verdict is judged inside its own class",
             tests.all? { |test| test["group"] == group.call(test["id"]) },
             tests.reject { |test| test["group"] == group.call(test["id"]) }.map { |t| t["id"] }.inspect)
    k.assert("the planted in-class duplicate is actionable and names its twin",
             actionable.any? { |test| test["verdict"] == "duplicate" && %w[TillTest#test_total TillTest#test_total_again].include?(test["by"]) },
             actionable.map { |t| t.slice("id", "verdict", "by") }.inspect)

    suite_tests = suite.dig("kill_matrix", "tests")
    crossed = suite_tests.select do |test|
      %w[subsumed duplicate].include?(test["verdict"]) && test["by"] && group.call(test["by"]) != group.call(test["id"])
    end
    k.assert_operator("suite scope finds cross-class redundancy on this fixture", crossed.size, :>=, 1)
    k.assert("the cross-class verdicts are absent under class scope",
             crossed.none? { |test| actionable.any? { |a| a["id"] == test["id"] && a["by"] == test["by"] } },
             crossed.map { |t| t["id"] }.inspect)

    k.note("actionable=#{actionable.size} suite_cross_class=#{crossed.size} tests=#{tests.size}")
  end
end
