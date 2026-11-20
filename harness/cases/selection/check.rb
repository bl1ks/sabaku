# frozen_string_literal: true

require_relative "../../lib/support"

# Claim: coverage-guided selection never changes a verdict on a suite whose tests are
# independent.
#
# Falsified by: one mutant whose status differs from the whole-suite oracle, or a
# `not_infected` survivor the oracle kills. The run is also required to be cheaper than
# the oracle by at least 2x, because a "cheap" path that selects every test would pass
# the status comparison without exercising selection at all.
#
# The oracle is the engine's own expensive path, `--no-coverage --no-weak`: it runs every
# test for every mutant. Both sides are cold and share `--per-line=all --timeout=30`, so
# neither the cache nor the deadline can explain a difference.
practical_case("selection") do |k|
  cold = { "RUBY_MUTATION_NO_CACHE" => "1" }
  # One candidate set, two ways to measure it. The oracle differs only in how it selects.
  run_args = ["run", "lib", "--per-line=all", "--timeout=30", "--report=json"]

  k.copy_project do |dir|
    cheap_seconds = k.elapsed do
      @cheap_out, @cheap_err, @cheap_code = k.run(dir, *run_args, env: cold)
    end
    oracle_seconds = k.elapsed do
      @oracle_out, @oracle_err, @oracle_code = k.run(dir, *run_args, "--no-coverage", "--no-weak",
                                                    env: cold)
    end

    k.assert_equal("cheap run exits 0", 0, @cheap_code, @cheap_err.to_s.lines.last(6).join)
    k.assert_equal("oracle run exits 0", 0, @oracle_code, @oracle_err.to_s.lines.last(6).join)

    cheap = k.parse_report(@cheap_out)
    oracle = k.parse_report(@oracle_out)
    k.assert("cheap report parses", !cheap.nil?, @cheap_out.to_s.lines.last(6).join)
    k.assert("oracle report parses", !oracle.nil?, @oracle_out.to_s.lines.last(6).join)
    next if cheap.nil? || oracle.nil?

    # A readable table of every row that differs: this diagnostic is the point of the case.
    mutants = [cheap, oracle].each_with_object({}) do |payload, index|
      payload["results"].each { |result| index[result["mutant"]["id"]] ||= result["mutant"] }
    end
    table = lambda do |rows|
      header = format("%-16s  %-22s  %-8s  %-38s  %-16s  %-10s",
                      "id", "path:line", "operator", "replacement", "cheap", "oracle")
      body = rows.map do |id, cheap_status, oracle_status|
        mutant = mutants[id] || {}
        replacement = mutant["replacement"].to_s.gsub(/\s+/, " ")
        replacement = "#{replacement[0, 35]}..." if replacement.length > 38
        format("%-16s  %-22s  %-8s  %-38s  %-16s  %-10s",
               id, "#{mutant['path']}:#{mutant['line']}", mutant["operator"], replacement,
               cheap_status, oracle_status)
      end
      ([header, "-" * header.length] + body).join("\n")
    end

    k.assert_equal("cheap run reports no error", 0, cheap["error"], cheap["error"].to_s)
    k.assert_equal("oracle run reports no error", 0, oracle["error"], oracle["error"].to_s)
    k.assert_operator("the fixture yields at least 60 mutants", cheap["mutants"], :>=, 60)
    k.assert_equal("both sides mutate the same candidate set", cheap["mutants"], oracle["mutants"])

    # 2. Status identity per mutant id, excluding anything either side leaves uncovered.
    rows = k.comparable(cheap, oracle)
    diffs = k.diff_rows(rows)
    k.assert_operator("the cheap path selected tests for a real share of the mutants",
                      rows.size, :>=, 60, "#{rows.size} comparable of #{cheap['mutants']}")
    k.assert("status identity on comparable mutants", diffs.empty?,
             "#{diffs.size} of #{rows.size} comparable mutants disagree:\n#{table.call(diffs)}")

    statuses = k.verdicts(cheap).values.tally
    oracle_statuses = k.verdicts(oracle).values.tally
    k.assert_operator("the cheap run has kills to compare", statuses.fetch("killed", 0), :>=, 30,
                      statuses.inspect)
    k.assert_operator("the cheap run has survivors to compare", statuses.fetch("survived", 0), :>=, 1,
                      statuses.inspect)
    k.assert_operator("the oracle has survivors to compare",
                      oracle_statuses.fetch("survived", 0), :>=, 1, oracle_statuses.inspect)

    # 3. The one asymmetry the probe pass can create: a survivor it decided without a
    # child must also survive every test. A kill here is a false survivor.
    oracle_verdicts = k.verdicts(oracle)
    not_infected = cheap["results"].select do |result|
      result["status"] == "survived" && result["reason"] == "not_infected"
    end
    false_survivors = not_infected.reject do |result|
      %w[survived uncovered].include?(oracle_verdicts[result["mutant"]["id"]])
    end
    k.assert_operator("the probe pass decided some survivors without a child",
                      not_infected.size, :>=, 1, "item 3 would be vacuous")
    k.assert("no not_infected survivor is killed by the oracle", false_survivors.empty?,
             "#{false_survivors.size} of #{not_infected.size} probe-decided survivors disagree:\n" +
             table.call(false_survivors.map do |result|
               [result["mutant"]["id"], "survived (not_infected)",
                oracle_verdicts[result["mutant"]["id"]] || "missing"]
             end))

    # 4. Two cold cheap runs have to agree, or the comparison above means nothing.
    second_out, second_err, second_code = k.run(dir, *run_args, env: cold)
    second = k.parse_report(second_out)
    k.assert_equal("the repeat cheap run exits 0", 0, second_code, second_err.to_s.lines.last(6).join)
    k.assert("the repeat report parses", !second.nil?, second_out.to_s.lines.last(6).join)
    if second
      first = k.verdicts(cheap)
      repeat = k.verdicts(second)
      unstable = (first.keys | repeat.keys).select { |id| first[id] != repeat[id] }
      k.assert_equal("two cheap runs agree on every mutant id", first, repeat,
                     "#{unstable.size} ids differ:\n#{table.call(unstable.map do |id|
                       [id, first[id] || "missing", repeat[id] || "missing"]
                     end)}")
    end

    # 5. Selection has to be worth its own cost: at least 2x faster than running every
    # test for every mutant. Without this, item 2 could pass because nothing selected.
    ratio = cheap_seconds.positive? ? oracle_seconds / cheap_seconds : 0.0
    k.assert_operator("the cheap run is at least twice as fast as the oracle",
                      oracle_seconds, :>=, cheap_seconds * 2,
                      format("cheap %.2fs, oracle %.2fs, %.2fx", cheap_seconds, oracle_seconds,
                             ratio))

    k.note(format("mutants=%d comparable=%d diffs=%d not_infected=%d cheap=%.2fs oracle=%.2fs %.2fx",
                  cheap["mutants"], rows.size, diffs.size, not_infected.size, cheap_seconds,
                  oracle_seconds, ratio))
  end
end
