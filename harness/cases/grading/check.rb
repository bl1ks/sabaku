# frozen_string_literal: true

require_relative "../../lib/support"
require "json"
require "open3"
require "rbconfig"

# Claim (harness/README.md, `grading`): the score is the number the report computes, and the
# survivor list names exactly the gaps the suite leaves.
# Falsified by: a score that does not follow from the statuses, a survivor that is not where
# the code says, or a killed mutant the suite does not actually notice.
#
# The fixture is a small payroll library whose suite leaves three gaps on purpose. Every other
# mutant is either killed by a test or sits on a line no test covers, so the survivor list is
# the whole story and every entry below is a gap no test closes.
EXPECTED_SURVIVORS = [
  # [path, line, operator] and one line on the test that should have caught it.
  # cond: test_dues_are_withheld_from_an_ordinary_period never waives dues, so `if false` keeps 1200.
  { path: "lib/payroll/employee.rb", line: 49, operator: "cond" },
  # sbr: that same test never waives, so deleting the waiver statement removes nothing it asserts.
  { path: "lib/payroll/employee.rb", line: 49, operator: "sbr" },
  # ror: test_a_heavy_period_is_withheld_at_the_heavy_rate pays 150_000, never the 100_000 ceiling where < and <= differ.
  { path: "lib/payroll/tax.rb", line: 16, operator: "ror" },
  # selector: that same test never crosses the ceiling, so rewriting <= as < changes nothing it asserts.
  { path: "lib/payroll/tax.rb", line: 16, operator: "selector" },
  # return: PayslipLinesTest asserts the stored rows and their total, never the row add_line returns.
  { path: "lib/payroll/payslip.rb", line: 45, operator: "return" }
].freeze

# Two mutants the report calls killed, pinned by the edit that should make the suite red.
# These check the third falsifier directly: a kill the suite does not actually notice.
KILLED_SPOT_CHECKS = [
  # paid_hours stops following the timesheet, so the hourly gross assertions break.
  { path: "lib/payroll/employee.rb", line: 28, operator: "cond",
    replacement: "true ? STANDARD_WEEK : hours" },
  # net adds withholding instead of subtracting it.
  { path: "lib/payroll/payslip.rb", line: 37, operator: "aor",
    replacement: "gross_cents + withholding_cents" }
].freeze

# Runs the project's suite the way its README tells a person to: minitest autorun over the
# files the engine's adapter globs, at the seed the adapter pins. Returns the process exit
# status, so 0 means green.
SUITE = lambda do |root|
  script = 'Dir.glob("test/**/*_test.rb").sort.each { |f| require File.expand_path(f) }'
  _out, _err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-Itest", "-e", script, "--",
                                      "--seed", "0", chdir: root)
  status.exitstatus
end

# Every run is cold: a warm cache would return verdicts this case did not measure, and the two
# report shapes must be derived from the same execution.
COLD = { "RUBY_MUTATION_NO_CACHE" => "1" }.freeze

# The text `mutation list` prints for a mutant, rebuilt from the fields the json report carries.
# Mutant#description is exactly this string, so a list row and a result row are comparable.
def mutation_description(mutant)
  "#{mutant.fetch('operator').upcase}: #{mutant.fetch('original')} -> #{mutant.fetch('replacement')}"
end

# `mutation list` prints one header per file and one row per mutant; a statement-block mutant's
# description spans several lines, so a row owns every line until the next row, header or count.
def parse_list(output)
  header = /\A(\S+)  \(\d+\)\z/
  row = /\A\s+(\d+)  (\S+)\s+(.*)\z/
  lines = output.lines.map(&:chomp)
  sections = {}
  lines.each_with_index do |line, index|
    match = header.match(line)
    sections[index] = match[1] unless match.nil?
  end

  starts = lines.each_index.select { |index| row.match?(lines[index]) }
  starts.each_with_index.map do |start, position|
    match = row.match(lines[start])
    path_index = sections.keys.select { |index| index < start }.max
    stop = starts[position + 1] || lines.size
    description = [match[3]]
    lines[(start + 1)...stop].each do |line|
      break if header.match?(line) || line.end_with?("mutants")

      description << line
    end
    [sections.fetch(path_index), match[1].to_i, match[2], description.join("\n").rstrip]
  end
end

practical_case("grading") do |k|
  k.copy_project do |dir|
    # ---- both report shapes, each on its own cold campaign -------------------------------
    term_out, term_err, term_code = k.run(dir, "run", "lib", "--per-line=all", env: COLD)
    k.assert_equal("terminal run exits 0", 0, term_code, term_err.to_s)
    k.assert("terminal run has no traceback", !term_err.to_s.include?("Traceback"), term_err.to_s)

    printed = term_out[/mutation score\s+([\d.]+)%/, 1]&.to_f
    k.assert("terminal prints a mutation score", !printed.nil?, term_out.lines.last(8).join)

    json_out, json_err, json_code = k.run(dir, "run", "lib", "--per-line=all", "--report=json",
                                         env: COLD)
    k.assert_equal("json run exits 0", 0, json_code, json_err.to_s)
    payload = k.parse_report(json_out)
    k.assert("json report parses", !payload.nil?, json_out.lines.last(3).join)
    next unless payload && printed

    results = payload.fetch("results")
    survivors = payload.fetch("survivors")
    statuses = results.map { |result| result.fetch("status") }.tally

    # ---- the score is the number the statuses compute ------------------------------------
    counted = statuses.fetch("killed", 0) + statuses.fetch("survived", 0) +
              statuses.fetch("timeout", 0)
    computed = counted.zero? ? 0.0 : statuses.fetch("killed", 0).fdiv(counted)
    k.assert_operator("the campaign measured something", counted, :>, 0, statuses.inspect)
    k.assert_equal("json score is killed/(killed+survived+timeout)",
                   computed.round(4), payload["score"])
    k.assert_equal("terminal prints that ratio to one decimal",
                   (computed * 100).round(1), printed)
    k.assert_equal("the two report shapes print the same score",
                   (payload["score"] * 100).round(1), printed)

    # ---- statuses: nothing half-measured, nothing counted that did not run ---------------
    k.assert_equal("no mutant produced an error", 0, payload["error"], payload.slice("error").inspect)
    k.assert_equal("no mutant errored", 0, statuses.fetch("error", 0))
    k.assert_equal("no mutant timed out", 0, statuses.fetch("timeout", 0))
    k.assert_equal("no mutant was skipped", 0, statuses.fetch("skipped", 0))
    unexpected = statuses.keys - %w[killed survived uncovered]
    k.assert_equal("every status is killed, survived or uncovered", [], unexpected.sort,
                   statuses.inspect)
    k.assert_equal("every mutant carries exactly one status", payload["mutants"], results.size)

    # ---- the survivor list is exactly the gaps the table names, at their lines -----------
    expected_coordinates = EXPECTED_SURVIVORS.map { |gap| [gap[:path], gap[:line]] }
    actual_coordinates = survivors.map { |survivor| [survivor["path"], survivor["line"]] }

    k.assert_equal("the report has exactly the predicted survivors", EXPECTED_SURVIVORS.size,
                   survivors.size)
    k.assert_equal("every predicted gap survives and no other coordinate does",
                   expected_coordinates.sort, actual_coordinates.sort)
    EXPECTED_SURVIVORS.each do |gap|
      k.assert("survivor at #{gap[:path]}:#{gap[:line]} (#{gap[:operator]})",
               survivors.any? { |survivor| survivor["path"] == gap[:path] &&
                                             survivor["line"] == gap[:line] &&
                                             survivor["operator"] == gap[:operator] },
               "no #{gap[:operator]} survivor at that coordinate")
    end
    k.assert_equal("the table names every surviving mutant, not just its line",
                   EXPECTED_SURVIVORS.map { |gap| [gap[:path], gap[:line], gap[:operator]] }.sort,
                   survivors.map do |survivor|
                     [survivor["path"], survivor["line"], survivor["operator"]]
                   end.sort)
    k.assert_equal("the survivor coordinates are the three the fixture plans",
                   expected_coordinates.uniq.sort, actual_coordinates.uniq.sort)

    # ---- the terminal survivor block is the json survivor list, in the same order --------
    block = term_out[/^survivors:\n(.*?)\n\n/m, 1]
    k.assert("terminal prints a survivor block", !block.nil?, term_out.lines.last(12).join)
    terminal_pairs = block.to_s.lines.filter_map do |line|
      match = line.match(/\A\s+(\S+):(\d+)\s/)
      match && [match[1], match[2].to_i]
    end
    json_pairs = survivors.map { |survivor| [survivor["path"], survivor["line"]] }
    k.assert_equal("terminal and json survivors are the same path:line pairs in the same order",
                   json_pairs, terminal_pairs)
    k.assert_equal("the terminal killed count is the json killed count",
                   statuses.fetch("killed", 0), term_out[/\bkilled\b\s+(\d+)/, 1]&.to_i)

    # ---- the gate follows the printed score, not a second rounding ------------------------
    tenths = (printed * 10).round
    at_score = format("%.1f", tenths / 10.0)
    above_score = format("%.1f", (tenths + 1) / 10.0)

    _out, at_err, at_code = k.run(dir, "run", "lib", "--per-line=all",
                                  "--min-score=#{at_score}", "--report=quiet", env: COLD)
    k.assert_equal("--min-score=#{at_score} (the printed score) exits 0", 0, at_code, at_err.to_s)

    _out, above_err, above_code = k.run(dir, "run", "lib", "--per-line=all",
                                        "--min-score=#{above_score}", "--report=quiet", env: COLD)
    k.assert_equal("--min-score=#{above_score} (one tenth more) exits 1", 1, above_code,
                   above_err.to_s)

    # ---- list and run describe the same mutants, in the same order -----------------------
    list_out, list_err, list_code = k.run(dir, "list", "lib", "--per-line=all")
    k.assert_equal("list exits 0", 0, list_code, list_err.to_s)

    listed = parse_list(list_out)
    k.assert_equal("list names as many mutants as the campaign ran", results.size, listed.size)
    k.assert_equal("list and run agree on every mutant, in order",
                   results.map do |result|
                     mutant = result.fetch("mutant")
                     [mutant["path"], mutant["line"], mutant["operator"],
                      mutation_description(mutant)]
                   end,
                   listed)
    k.assert_equal("every mutant id is unique", results.size,
                   results.map { |result| result["mutant"]["id"] }.uniq.size)
    k.assert_equal("list's own count agrees with the campaign", results.size,
                   list_out[/^(\d+) mutants$/, 1]&.to_i)

    # ---- the falsifiers the report cannot grade by itself --------------------------------
    # A survivor is only a gap if the suite really stays green with its edit applied, and a
    # kill is only a kill if the suite really goes red. Both are measured on a fresh copy by
    # running the tests directly, so the engine's verdict is checked against the suite rather
    # than against itself.
    k.copy_project do |root|
      survivors.each do |survivor|
        path = File.join(root, survivor.fetch("path"))
        text = File.read(path)
        occurrences = text.scan(survivor.fetch("original")).length
        k.assert_equal("the survivor at #{survivor['path']}:#{survivor['line']} names an edit " \
                       "that applies exactly once", 1, occurrences)
        next unless occurrences == 1

        File.write(path, text.sub(survivor.fetch("original"), survivor.fetch("replacement")))
        begin
          status = SUITE.call(root)
          k.assert_equal("the suite leaves the #{survivor['operator']} survivor at " \
                         "#{survivor['path']}:#{survivor['line']} alone", 0, status)
        ensure
          File.write(path, text)
        end
      end

      KILLED_SPOT_CHECKS.each do |spot|
        matches = results.select do |result|
          mutant = result.fetch("mutant")
          mutant["path"] == spot[:path] && mutant["line"] == spot[:line] &&
            mutant["operator"] == spot[:operator] && mutant["replacement"] == spot[:replacement]
        end
        k.assert_equal("the report has the #{spot[:operator]} mutant the kill check names", 1,
                       matches.size)
        next unless matches.size == 1

        result = matches.first
        k.assert_equal("the report calls it killed", "killed", result["status"])
        mutant = result.fetch("mutant")
        path = File.join(root, mutant.fetch("path"))
        text = File.read(path)
        occurrences = text.scan(mutant.fetch("original")).length
        k.assert_equal("the killed mutant at #{mutant['path']}:#{mutant['line']} names an edit " \
                       "that applies exactly once", 1, occurrences)
        next unless occurrences == 1

        File.write(path, text.sub(mutant.fetch("original"), mutant.fetch("replacement")))
        begin
          status = SUITE.call(root)
          k.assert_equal("the suite notices the kill at #{mutant['path']}:#{mutant['line']}",
                         1, status)
        ensure
          File.write(path, text)
        end
      end
    end

    k.note(format("%d mutants: %d killed, %d survived, %d uncovered, score %.1f%%",
                  payload["mutants"], statuses.fetch("killed", 0), statuses.fetch("survived", 0),
                  statuses.fetch("uncovered", 0), printed))
  end
end
