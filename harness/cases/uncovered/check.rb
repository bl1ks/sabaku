# frozen_string_literal: true

require_relative "../../lib/support"

# Claim: every mutant the report leaves uncovered says why, and the reason is true.
#
# Falsified by: an uncovered mutant without a reason from the closed set; a file the report
# scores 0/0 that the coverage section does not describe, or whose terminal row names no
# reason; a reason that contradicts the file's state; a planted file reported with the wrong
# reason; or a mutant called `not_loaded` or `not_reached` that the whole-suite oracle kills,
# since both say no test ever ran the line.
#
# The project plants one file per cause: lib/orphan.rb no test loads, lib/audit_form.rb the
# boot loads and only its class-body DSL line ran, lib/dormant.rb loaded with no method
# called, lib/lazy_report.rb required inside one test, and lib/signup_form.rb whose DSL line
# the boot ran and whose methods a test calls.
practical_case("uncovered") do |k|
  cold = { "SABAKU_NO_CACHE" => "1" }
  reasons = %w[not_loaded uninstrumented load_time_only not_reached]
  states = %w[not_loaded uninstrumented loaded_during_test instrumented]
  args = ["lib", "--per-line=all", "--timeout=30"]

  k.copy_project do |dir|
    report = k.campaign(dir, *args, env: cold)
    oracle = k.campaign(dir, *args, "--no-coverage", "--no-weak", env: cold)
    terminal, err, code = k.run(dir, "run", *args, env: cold)
    k.assert_equal("terminal run exits 0", 0, code, err.lines.last(4).join)

    k.assert_equal("no mutant errored", 0, report["error"])
    uncovered = report["results"].select { |result| result["status"] == "uncovered" }
    k.assert_operator("the fixture leaves mutants uncovered", uncovered.size, :>=, 8)

    unreasoned = uncovered.reject { |result| reasons.include?(result["reason"]) }
    k.assert("every uncovered mutant has a reason", unreasoned.empty?,
             unreasoned.first(3).map { |r| "#{r['mutant']['path']}:#{r['mutant']['line']} #{r['reason'].inspect}" }.join("; "))

    described = report["coverage_files"].to_h { |file| [file["path"], file] }
    empty = report["files"].select { |file| file["counted"].zero? }.map { |file| file["path"] }
    k.assert_operator("the fixture has 0/0 files", empty.size, :>=, 3)
    empty.each do |path|
      state = described.dig(path, "state")
      k.assert("#{path} (0/0) is described with a state", states.include?(state), "state #{state.inspect}")
      row = terminal.lines.find { |line| line.match?(%r{^\s+#{Regexp.escape(path)}\s+0/0}) }
      k.assert("#{path} (0/0) names its reason in the terminal", row&.match?(/\((?:#{reasons.map { |r| r.tr('_', ' ') }.join('|')})\)/),
               row.inspect)
    end

    by_path = uncovered.group_by { |result| result["mutant"]["path"] }
    by_path.each do |path, list|
      seen = list.map { |result| result["reason"] }.uniq
      case described.dig(path, "state")
      when "not_loaded"
        k.assert_equal("#{path}: a file nothing loaded has only not_loaded mutants", ["not_loaded"], seen)
      when "instrumented", "loaded_during_test"
        k.assert("#{path}: a measured file never says not_loaded or uninstrumented",
                 (seen & %w[not_loaded uninstrumented]).empty?, seen.inspect)
      end
    end

    k.assert_equal("lib/orphan.rb is not loaded", "not_loaded", described.dig("lib/orphan.rb", "state"))
    k.assert_includes("lib/audit_form.rb has a load-time-only mutant",
                      by_path.fetch("lib/audit_form.rb", []).map { |r| r["reason"] }, "load_time_only")
    k.assert_includes("lib/dormant.rb has a not-reached mutant",
                      by_path.fetch("lib/dormant.rb", []).map { |r| r["reason"] }, "not_reached")
    k.assert_equal("lib/lazy_report.rb was loaded by the one test that requires it",
                   ["loaded_during_test", "LazyReportTest#test_summary"],
                   described.fetch("lib/lazy_report.rb", {}).values_at("state", "loaded_by"))
    signup = report["results"].select { |result| result["mutant"]["path"] == "lib/signup_form.rb" }
    k.assert_operator("lib/signup_form.rb yields mutants", signup.size, :>=, 2)
    k.assert_equal("a class-body line in a file a test reached is never uncovered",
                   [], signup.select { |result| result["status"] == "uncovered" }.map { |r| r["mutant"]["line"] })

    oracle_status = k.verdicts(oracle)
    lied = uncovered.select do |result|
      %w[not_loaded not_reached].include?(result["reason"]) && oracle_status[result["mutant"]["id"]] == "killed"
    end
    k.assert("no mutant said to be unreached is killed by the whole suite", lied.empty?,
             lied.first(3).map { |r| "#{r['mutant']['path']}:#{r['mutant']['line']} #{r['reason']}" }.join("; "))

    k.note("uncovered=#{uncovered.size} reasons=#{uncovered.map { |r| r['reason'] }.tally} zero_files=#{empty.size}")
  end
end
