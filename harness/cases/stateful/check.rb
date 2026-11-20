# frozen_string_literal: true

require_relative "../../lib/support"

# Claim: on a suite that shares state between tests, the run is reproducible and a
# kill is never invented.
# Falsified by: two cheap runs that disagree on a status or the score, or a mutant
# the cheap path reports `killed` that survives when every test runs.
#
# The suite deliberately leaks state (a module counter, a shared desk object, a
# tariff baked on first use, and alphabetical order), so coverage selection can
# order the tests differently from the all-tests run. That makes a survivor
# optimistic at worst: a test the cheap path did not run before the leak can still
# kill a mutant on the oracle. A kill cannot be optimistic, so this case does not
# compare the two maps for identity; it compares the one direction that must hold
# and records the other as a note.
practical_case("stateful") do |k|
  k.copy_project do |dir|
    cold = { "SABAKU_NO_CACHE" => "1" }
    flags = %w[--per-line=all --timeout=30]

    first = k.campaign(dir, *flags, env: cold)
    second = k.campaign(dir, *flags, env: cold)
    oracle = k.campaign(dir, *flags, "--no-coverage", "--no-weak", env: cold)

    maps = [first, second, oracle].map { |payload| k.verdicts(payload) }
    reasons = [first, second].map do |payload|
      payload.fetch("results").to_h { |result| [result.fetch("mutant").fetch("id"), result["reason"]] }
    end
    info = first.fetch("results").to_h do |result|
      mutant = result.fetch("mutant")
      [mutant.fetch("id"), "#{mutant["operator"]} #{mutant["path"]}:#{mutant["line"]}"]
    end

    # ---- 1. the run is reproducible -----------------------------------------

    k.assert_equal("both cheap runs score the same", first["score"], second["score"])
    k.assert_equal("both cheap runs see the same mutants", maps[0].keys.sort, maps[1].keys.sort)

    drift = maps[0].keys.select { |id| maps[0][id] != maps[1][id] }
    k.assert("the two cheap runs agree on every mutant's status", drift.empty?,
             drift.first(5).map { |id| "#{info[id]}: #{maps[0][id]} then #{maps[1][id]}" }.join("; "))
    k.assert("the cheap path has verdicts to compare", !maps[0].empty?)

    killed = maps[0].select { |_id, status| status == "killed" }.keys
    survivors = maps[0].select { |_id, status| status == "survived" }.keys
    not_infected = survivors.select { |id| reasons[0][id] == "not_infected" }

    k.assert("the cheap path kills something", killed.any?, "a case with no kill tests nothing")
    k.assert("the cheap path leaves survivors", survivors.any?, "a 100% score would hide the probe pass")
    k.assert("the probe pass decides some survivors without a child", not_infected.any?,
             "no not_infected survivor: the probe pass is not being exercised")

    # ---- 2. a kill is never invented ----------------------------------------
    # Both sides cover every mutant here, so the uncovered exclusion the oracle
    # rules allow is not what keeps this comparison honest.


    invented = killed.reject { |id| maps[2][id] == "killed" }
    k.assert("every cheap kill is a kill when every test runs", invented.empty?,
             invented.first(8).map do |id|
               "invented kill #{info[id]} (#{id}): cheap=killed oracle=#{maps[2][id].inspect}"
             end.join("; "))

    # ---- 3. survivors may be optimistic, but not unstable -------------------

    unstable = not_infected.reject { |id| maps[1][id] == "survived" }
    k.assert("every not_infected survivor is stable across the cheap runs", unstable.empty?,
             unstable.first(5).map { |id| "#{info[id]}: #{maps[0][id]} then #{maps[1][id]}" }.join("; "))

    # A cheap survivor the all-tests run kills is the documented optimism, not a
    # failure: the cheap path ordered a test before the one that leaks the state
    # the kill depends on. Record it in the case line instead of hiding it.
    optimistic = survivors.select { |id| maps[2][id] == "killed" }
    if optimistic.any?
      shown = optimistic.first(4).map { |id| "#{info[id]} (#{reasons[0][id]})" }
      k.note("optimistic survivors the oracle kills: #{optimistic.size} - #{shown.join(", ")}")
    end

    # ---- 4. every run exits clean -------------------------------------------

    [first, second, oracle].each_with_index do |payload, index|
      run = index == 2 ? "oracle" : "cheap run #{index + 1}"
      k.assert_equal("#{run} reports no error mutant", 0, payload["error"])
      k.assert_equal("#{run} accounts for every mutant", payload["mutants"],
                     payload.slice("killed", "survived", "timeout", "uncovered", "error", "skipped").values.sum)
      k.assert_equal("#{run} excludes no mutant as uncovered", 0, payload["uncovered"])
    end
  end
end
