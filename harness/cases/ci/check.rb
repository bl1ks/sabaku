# frozen_string_literal: true

require_relative "../../lib/support"
require "json"

# Claim: a team can gate on the exit code, the score threshold and the diff allowlist.
# Falsified by: exit codes that disagree with the printed score, --diff leaking outside its
# allowlist, --report=quiet printing, or the cheap commands running the suite.
practical_case("ci") do |k|
  k.copy_project do |dir|
    term_out, term_err, term_code = k.run(dir, "run", "lib")
    k.assert_equal("terminal run exits 0", 0, term_code)
    k.assert("terminal run mentions the verifier", !term_err.to_s.include?("Traceback"))
    printed = term_out[/mutation score\s+([\d.]+)%/, 1]&.to_f
    k.assert("terminal prints a score", !printed.nil?, term_out.lines.last(26).join)

    json_out, _json_err, json_code = k.run(dir, "run", "lib", "--report=json")
    payload = k.parse_report(json_out)
    k.assert_equal("json run exits 0", 0, json_code)
    k.assert("json report parses", !payload.nil?, json_out.lines.last(3).join)
    next unless payload

    counts = payload.slice("killed", "survived", "timeout", "uncovered", "error", "skipped")
    counted = counts["killed"] + counts["survived"] + counts["timeout"]
    computed = counted.zero? ? 0.0 : (counts["killed"].fdiv(counted) * 100).round(1)

    k.assert_equal("printed score is the score the payload computes", printed, computed)
    k.assert_equal("the payload reports that same score", computed, (payload["score"] * 100).round(1))
    k.assert_equal("every mutant carries exactly one status", payload["mutants"], counts.values.sum)
    k.assert_equal("the run measured something", true, counted.positive?, counts.inspect)
    k.assert_equal("the fixture leaves a survivor to find", true, counts["survived"].positive?, counts.inspect)

    at_threshold, _err, threshold_code = k.run(dir, "run", "lib", "--min-score=#{printed}", "--report=quiet")
    k.assert_equal("min-score at the printed value passes", 0, threshold_code)
    k.assert_equal("min-score at the printed value stays quiet", "", at_threshold)

    _out, _err, below_code = k.run(dir, "run", "lib", "--min-score=#{printed + 0.1}", "--report=quiet")
    k.assert_equal("one tenth above the printed value fails", 1, below_code)

    quiet_out, _err, quiet_code = k.run(dir, "run", "lib", "--report=quiet")
    k.assert_equal("quiet run exits 0", 0, quiet_code)
    k.assert_equal("quiet prints nothing", "", quiet_out)

    sample = payload["results"].find { |result| result["mutant"]["operator"] == "ror" }
    k.assert("the fixture has a relational mutant to aim --diff at", !sample.nil?)
    if sample
      path = sample["mutant"]["path"]
      line = sample["mutant"]["line"]
      k.write(dir, "diff.json", JSON.generate(path => [line]))
      diff_out, diff_err, diff_code = k.run(dir, "run", "lib", "--diff=diff.json", "--report=json")
      diff = k.parse_report(diff_out)
      k.assert_equal("diff run exits 0", 0, diff_code)
      k.assert("diff report parses", !diff.nil?, diff_err.to_s)
      if diff
        k.assert_equal("diff mutates the allowed line", 1, diff["mutants"])
        k.assert_equal("diff stays inside its allowlist", [[path, line]],
                       diff["results"].map { |r| [r["mutant"]["path"], r["mutant"]["line"]] }.uniq)
      end
    end

    limit_out, _err, limit_code = k.run(dir, "run", "lib", "--limit=1", "--report=json")
    limited = k.parse_report(limit_out)
    k.assert_equal("limit run exits 0", 0, limit_code)
    k.assert_equal("limit caps the mutant count", 1, limited && limited["mutants"])

    operator_out, _err, operator_code = k.run(dir, "run", "lib", "--operators=ror", "--report=json")
    narrowed = k.parse_report(operator_out)
    k.assert_equal("operator run exits 0", 0, operator_code)
    k.assert_equal("operators restricts to the named operator", ["ror"],
                   narrowed && narrowed["results"].map { |r| r["mutant"]["operator"] }.uniq)

    # The tier boundary is the first survivor, and it is one the probe pass decides without a
    # child. The bulk method below it is killable, so a working --fail-fast stops between them.
    # Both runs are cold: a warm cache would return the later verdicts for free, and a halt
    # that costs nothing has nothing left to skip.
    cold = { "SABAKU_NO_CACHE" => "1" }
    cold_out, _err, cold_code = k.run(dir, "run", "lib", "--report=json", env: cold)
    cold_run = k.parse_report(cold_out)
    k.assert_equal("cold run exits 0", 0, cold_code)

    fast_out, _err, fast_code = k.run(dir, "run", "lib", "--fail-fast", "--min-score=100",
                                      "--report=json", env: cold)
    stopped = k.parse_report(fast_out)
    k.assert_equal("fail-fast on a survivor fails the gate", 1, fast_code)
    k.assert("fail-fast still reports", !stopped.nil?, fast_out.to_s)
    k.assert_operator("fail-fast leaves the rest unrun", stopped && stopped["skipped"], :>, 0)
    k.assert_operator("fail-fast measures less than a full run",
                      stopped && (stopped["mutants"] - stopped["skipped"]), :<, cold_run && cold_run["mutants"])

    list_seconds = k.elapsed { @list = k.run(dir, "list", "lib") }
    list_out, _err, list_code = @list
    k.assert_equal("list exits 0", 0, list_code)
    k.assert_operator("list does not boot the suite", list_seconds, :<, 20)
    k.assert("list names the mutants", list_out.include?("lib/shipping.rb"))

    doctor_seconds = k.elapsed { @doctor = k.run(dir, "doctor") }
    doctor_out, doctor_err, doctor_code = @doctor
    k.assert_equal("doctor exits 0", 0, doctor_code)
    k.assert_operator("doctor does not boot the suite", doctor_seconds, :<, 20)
    k.assert("doctor reports the ruby it found", "#{doctor_out}#{doctor_err}".include?("ruby"))
  end
end
