# frozen_string_literal: true

require_relative "../../lib/support"
require "json"
require "rbconfig"

# Helpers the case needs beyond Harness::Case. Splicing is the engine's own definition of a
# mutant (byte range replaced by the replacement text), so the probe below asks the same
# question a child asks: does the mutated file load at all?
module HostileProbe
  module_function

  def splice(text, mutant)
    spliced = text.dup
    start = Integer(mutant.fetch("start_offset"))
    length = Integer(mutant.fetch("end_offset")) - start
    spliced.bytesplice(start, length, mutant.fetch("replacement").to_s)
    spliced
  end

  # True when a fresh Ruby can execute the spliced file. Nothing from the project is
  # preloaded, so a raise here is the file's own load-time behaviour, which is what a child
  # sees when it applies the mutation before running any test.
  def loads?(root, source)
    directory = File.expand_path(".hostile-probe", root)
    FileUtils.mkdir_p(directory)
    path = File.expand_path("splice.rb", directory)
    File.write(path, source)
    _out, _err, status = Open3.capture3(RbConfig.ruby, path, chdir: root)
    status.success?
  end
end

# Claim: messy source and unloadable mutants degrade to an honest `skipped`, never to a
# crash or a free pass.
# Falsified by: a traceback, a skipped mutant counted in the score, or a mutant reported
# killed that never ran.
TRACEBACK = /Traceback|\.rb:\d+:in/
MESSY = {
  "lib/hostile/labels.rb" => "UTF-8 comments, strings, an emoji and an encoding comment",
  "lib/hostile/sql.rb" => "<<~SQL and <<-TEXT heredocs and an interpolated multi-line string",
  "lib/hostile/manual.rb" => "__END__ with a DATA read",
  "lib/hostile/geometry.rb" => "frozen_string_literal with a Struct definition",
  "lib/hostile/table.rb" => "a load-time constant whose mutant cannot load"
}.freeze

def clean?(text) = !TRACEBACK.match?(text.to_s)

def parse_json(text)
  JSON.parse(text.to_s.strip)
rescue JSON::ParserError
  nil
end

def counts_of(payload)
  payload.slice("killed", "survived", "timeout", "uncovered", "error", "skipped")
end

def score_from(counts)
  measured = counts["killed"] + counts["survived"] + counts["timeout"]
  return 0.0 if measured.zero?

  counts["killed"].fdiv(measured).round(4)
end

def assert_score(k, payload, label)
  counts = counts_of(payload)
  k.assert_equal("every result carries exactly one status (#{label})",
                 payload.fetch("mutants"), counts.values.sum)
  k.assert_equal("the score is killed/(killed+survived+timeout) (#{label})",
                 score_from(counts), payload.fetch("score").round(4))
  counts
end

practical_case("hostile") do |k|
  # ---- 1, 2, 3: the messy project, cold, at mutant depth ---------------------
  k.copy_project do |dir|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, code = k.run(dir, "run", "lib", "--per-line=all", "--report=json",
                           env: { "SABAKU_NO_CACHE" => "1" })
    cold_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    k.assert_equal("cold run exits 0", 0, code, "exit #{code}\n--- stderr\n#{err}")
    k.assert("cold stderr contains no traceback", clean?(err), err.to_s)
    k.assert("cold stdout contains no traceback", clean?(out), out.to_s.lines.last(6).join)

    payload = parse_json(out)
    k.assert("cold stdout is one valid JSON report", !payload.nil?, out.lines.last(6).join)
    next unless payload

    results = payload.fetch("results")
    k.assert_equal("the report lists as many results as it counted",
                   payload.fetch("mutants"), results.size)
    counts = assert_score(k, payload, "cold run")
    k.assert_operator("the campaign measured something", counts["killed"] + counts["survived"],
                      :>, 0, counts.inspect)

    # A free pass would be the skipped/uncovered statuses leaking into the denominator.
    scored_if_leaked = if counts["killed"].zero?
                         0.0
                       else
                         counts["killed"].fdiv(counts.values.sum).round(4)
                       end
    k.assert("the fixture has a non-counted status for the denominator to exclude",
             (counts["skipped"] + counts["uncovered"]).positive?, counts.inspect)
    k.assert("the score would change if skipped or uncovered were counted",
             scored_if_leaked != payload.fetch("score").round(4),
             "reported #{payload["score"]}, leaked #{scored_if_leaked}, #{counts.inspect}")

    # Item 1: every mutant the fixture intends as unloadable must be skipped, not killed.
    load_time = results.select do |result|
      mutant = result.fetch("mutant")
      mutant["path"].to_s.start_with?("lib/") && !mutant["scope"].to_s.include?("#")
    end
    k.assert_operator("the fixture has load-time mutants to judge", load_time.size, :>=, 5)

    texts = {}
    unloadable = load_time.reject do |result|
      mutant = result.fetch("mutant")
      text = (texts[mutant["path"]] ||= File.read(File.join(dir, mutant["path"])))
      HostileProbe.loads?(dir, HostileProbe.splice(text, mutant))
    end
    k.assert_operator("the fixture produces mutants that cannot be loaded",
                      unloadable.size, :>, 0,
                      "load-time mutants: #{load_time.size}, none failed to load")

    unloadable.each do |result|
      mutant = result.fetch("mutant")
      label = "#{mutant["path"]}:#{mutant["line"]} #{mutant["operator"]} " \
              "#{mutant["original"].inspect} -> #{mutant["replacement"].inspect}"
      k.assert("unloadable mutant is skipped or error, not #{result["status"]}: #{label}",
               %w[skipped error].include?(result["status"]), result["message"].to_s)
      k.assert("unloadable mutant says why it was not measured: #{label}",
               result["message"].to_s.match?(/load|measure|error|exception/i),
               result["message"].to_s)
    end
    k.assert("unloadable mutants are skipped, not errors",
             unloadable.any? { |result| result["status"] == "skipped" },
             unloadable.map { |result| [result["status"], result["message"]] }.first(3).inspect)
    k.assert("the table's unloadable mutants are reported",
             unloadable.any? { |result| result["mutant"]["path"] == "lib/hostile/table.rb" })

    skipped = results.select { |result| result["status"] == "skipped" }
    k.assert("every skipped mutant says why it was not measured",
             skipped.all? { |result| !result["message"].to_s.strip.empty? },
             skipped.reject { |result| !result["message"].to_s.strip.empty? }
                    .map { |result| [result["mutant"]["path"], result["mutant"]["line"]] }
                    .first(4).inspect)

    # Item 3: every messy file has to yield mutants. A file that yields none is real code
    # the engine silently ignored, and the note below says which file that was.
    per_file = results.group_by { |result| result["mutant"]["path"] }.transform_values(&:size)
    k.note("per-file mutants: #{per_file.sort.map { |path, size| "#{path}=#{size}" }.join(" ")}")
    MESSY.each do |path, construct|
      k.assert_operator("#{path} yields mutants (#{construct})", per_file.fetch(path, 0), :>, 0,
                        "files with mutants: #{per_file.keys.sort.inspect}")
    end

    labels = results.select { |r| r["mutant"]["path"] == "lib/hostile/labels.rb" }
    k.assert("the UTF-8 file yields mutants over non-ASCII source",
             labels.any? { |r| !r["mutant"]["original"].to_s.ascii_only? },
             labels.map { |r| r["mutant"]["original"] }.first(4).inspect)

    sql = results.select { |r| r["mutant"]["path"] == "lib/hostile/sql.rb" }
    k.assert("the heredoc file's ordinary code is mutated",
             sql.any? { |r| r["mutant"]["scope"].to_s.match?(/#(window_start|within\?)/) })

    manual_results = results.select { |r| r["mutant"]["path"] == "lib/hostile/manual.rb" }
    manual_text = File.read(File.join(dir, "lib/hostile/manual.rb"))
    data_offset = manual_text.b.index(/^__END__\s*$/).to_i
    k.assert_operator("the __END__ file's data marker is where the fixture put it",
                      data_offset, :>, 0)
    k.assert("the __END__ file yields mutants", manual_results.any?)
    k.assert("no mutant reaches into the section after __END__",
             manual_results.all? { |r| r["mutant"]["start_offset"].to_i < data_offset },
             manual_results.map { |r| [r["mutant"]["line"], r["mutant"]["start_offset"]] }
                           .select { |(_line, offset)| offset.to_i >= data_offset }.inspect)

    geometry = results.select { |r| r["mutant"]["path"] == "lib/hostile/geometry.rb" }
    k.assert("the Struct block yields a killed mutant",
             geometry.any? do |r|
               r["mutant"]["scope"].to_s.include?("#move") && r["status"] == "killed"
             end,
             geometry.map { |r| [r["mutant"]["scope"], r["mutant"]["line"], r["status"]] }
                     .first(6).inspect)

    # The other half of the claim: a kill is a test that ran and failed.
    killed = results.select { |r| r["status"] == "killed" }
    k.assert_operator("the run kills something", killed.size, :>, 0)
    nameless = killed.reject { |r| !r["failed_test"].to_s.strip.empty? }
    k.assert("every killed mutant names the test that failed", nameless.empty?,
             nameless.map { |r| [r["mutant"]["path"], r["mutant"]["line"]] }.first(5).inspect)
    k.note("cold (#{"%.1f" % cold_seconds}s) statuses #{counts.inspect} score #{payload["score"]}")
  end

  # ---- 4: a file that does not parse is a named error, not a traceback ------
  k.copy_project do |dir|
    path = File.join(dir, "lib/hostile/labels.rb")
    File.write(path, "#{File.read(path)}\nclass Hostile::Broken\n")

    out, err, code = k.run(dir, "run", "lib", "--report=json")
    k.assert_equal("a file that does not parse exits 2", 2, code,
                   "exit #{code}\n--- stderr\n#{err}")
    k.assert("stderr names the offending file",
             err.to_s.match?(%r{lib/hostile/labels\.rb:\d+}), err.to_s)
    k.assert("the parse error names a position", err.to_s.match?(/labels\.rb:\d+:.+/), err.to_s)
    k.assert("a parse error prints no backtrace on stdout", clean?(out), out.to_s)
    k.assert("a parse error prints no backtrace on stderr", clean?(err), err.to_s)
    k.assert("a parse error reports nothing that is not JSON",
             out.to_s.strip.empty? || !parse_json(out).nil?,
             out.to_s.lines.last(4).join)
  end

  # ---- 5: a red suite is refused by default and scored only on request ------
  k.copy_project do |dir|
    path = File.join(dir, "test/labels_test.rb")
    original = File.read(path)
    red = original.sub(
      'assert_equal "こんにちは, Ada 🎉", Hostile::Labels.title("Ada")',
      'assert_equal "the suite is red", Hostile::Labels.title("Ada")'
    )
    k.assert("the fixture has the assertion this copy reddens", red != original)
    next unless red != original

    File.write(path, red)
    failing_id = "HostileLabelsTest#test_title_is_the_utf8_greeting_plus_the_name_and_the_emoji"

    default_out, default_err, default_code = k.run(dir, "run", "lib", "--report=json")
    k.assert_equal("a red suite fails the baseline gate with exit 2", 2, default_code,
                   "exit #{default_code}\n--- stdout\n#{default_out}\n--- stderr\n#{default_err}")
    k.assert("the baseline error names the failing test",
             default_err.to_s.include?(failing_id), default_err.to_s)
    k.assert("the red-suite refusal prints no backtrace on stdout", clean?(default_out),
             default_out.to_s)
    k.assert("the red-suite refusal prints no backtrace on stderr", clean?(default_err),
             default_err.to_s)
    k.assert("the refused suite reports nothing that is not JSON",
             default_out.to_s.strip.empty? || !parse_json(default_out).nil?,
             default_out.to_s.lines.last(4).join)

    relaxed_out, relaxed_err, relaxed_code = k.run(dir, "run", "lib", "--no-baseline",
                                                   "--report=json")
    k.assert_equal("--no-baseline runs a red suite", 0, relaxed_code,
                   "exit #{relaxed_code}\n--- stderr\n#{relaxed_err}")
    relaxed = parse_json(relaxed_out)
    k.assert("--no-baseline prints valid JSON", !relaxed.nil?, relaxed_out.to_s.lines.last(4).join)
    next unless relaxed

    relaxed_counts = assert_score(k, relaxed, "--no-baseline red run")
    k.assert_operator("the red run has measured mutants",
                      relaxed_counts["killed"] + relaxed_counts["survived"] +
                      relaxed_counts["timeout"], :>, 0, relaxed_counts.inspect)
    k.note("red --no-baseline statuses #{relaxed_counts.inspect} score #{relaxed["score"]}")
  end
end
