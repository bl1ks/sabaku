# frozen_string_literal: true

require_relative "../test_helper"

class ReportTest < Minitest::Test
  FakeMutant = Struct.new(:path, :line, :column, :operator, :node_kind,
                          :original, :replacement, :description, keyword_init: true)

  def mutant(path: "lib/pricing.rb", line: 10, operator: :aor,
             description: "AOR: 1 + 2 -> 1 - 2")
    FakeMutant.new(path: path, line: line, column: 0, operator: operator, node_kind: "CallNode",
                   original: "1 + 2", replacement: "1 - 2", description: description)
  end

  def result(status, **kwargs)
    Sabaku::Result.new(mutant: mutant(**kwargs), status: status, duration: 0.01)
  end

  def report(results, overrides = {})
    Sabaku::Report.new(results, Sabaku::Config.default(**overrides))
  end

  def test_score_counts_only_killed_survived_and_timeout
    results = [result(:killed), result(:killed), result(:survived),
               result(:uncovered), result(:error)]
    assert_in_delta 2.0 / 3.0, report(results).score, 0.0001
  end

  def test_uncovered_and_error_never_enter_the_denominator
    only_uncovered = [result(:uncovered), result(:error)]
    assert_equal 0.0, report(only_uncovered).score
    assert_equal 0, report(only_uncovered).run_count
  end

  def test_empty_report_scores_zero_without_dividing_by_zero
    assert_equal 0.0, report([]).score
  end

  def test_the_printed_percentage_and_the_gate_use_one_rounding
    results = Array.new(3999) { result(:killed) } + Array.new(1001) { result(:survived) }

    doc = report(results)

    assert_in_delta 0.7998, doc.score, 1e-9
    assert_equal 80.0, doc.score_pct
    assert_includes doc.status_lines, "80.0%"
  end

  def test_terminal_names_the_survivors_with_their_location
    results = [result(:killed), result(:survived, line: 42)]
    text = report(results).to_terminal
    assert_includes text, "lib/pricing.rb:42"
    assert_includes text, "AOR: 1 + 2 -> 1 - 2"
    assert_includes text, "50.0%"
  end

  def test_terminal_hides_uncovered_and_error_when_zero
    text = report([result(:killed)]).to_terminal
    refute_includes text, "uncovered"
    refute_includes text, "error"
  end

  def test_terminal_names_every_error_with_its_cause
    errored = Sabaku::Result.new(
      mutant: mutant(line: 7), status: :error,
      message: "LoadError: cannot load such file -- nope"
    )
    text = report([result(:killed), errored]).to_terminal

    assert_includes text, "errors (not scored):"
    assert_includes text, "lib/pricing.rb:7  LoadError: cannot load such file -- nope"
    refute_includes text, "could not be applied"
  end

  def test_terminal_lists_at_most_ten_errors
    errored = Array.new(12) do |index|
      Sabaku::Result.new(mutant: mutant(line: index + 1), status: :error, message: "boom")
    end
    text = report(errored).to_terminal

    assert_includes text, "... and 2 more"
  end

  def test_json_carries_the_survivor_detail_a_ci_job_needs
    payload = JSON.parse(report([result(:survived, line: 7)]).to_json)
    assert_equal 1, payload["mutants"]
    assert_equal 0, payload["killed"]
    assert_in_delta 0.0, payload["score"]
    survivor = payload["survivors"].first
    assert_equal "lib/pricing.rb", survivor["path"]
    assert_equal 7, survivor["line"]
    assert_equal "1 + 2", survivor["original"]
    assert_equal "1 - 2", survivor["replacement"]
  end

  def test_survivors_are_split_by_why_they_survived
    results = [
      result(:survived, line: 1),
      Sabaku::Result.new(mutant: mutant(line: 2), status: :survived, reason: :not_infected)
    ]
    doc = report(results)

    assert_includes doc.status_lines, "not detected 1, not infected 1"
    assert_includes doc.to_terminal, "(not infected)"
    payload = JSON.parse(doc.to_json)
    assert_equal({ "not_detected" => 1, "not_infected" => 1 }, payload["survived_reasons"])
  end

  def reasoned(status, reason, line: 1, message: nil)
    Sabaku::Result.new(mutant: mutant(line: line), status: status, reason: reason, message: message)
  end

  def test_every_unscored_status_is_split_by_its_reason
    results = [
      reasoned(:skipped, :fail_fast, message: "not run: --fail-fast stopped at the first survivor"),
      reasoned(:skipped, :mutation_unloadable, line: 2, message: "the mutated file does not load (boom)"),
      reasoned(:timeout, :deadline, line: 3),
      reasoned(:error, :unverified_kill, line: 4, message: "unverified kill: A#t fails")
    ]
    doc = report(results)

    assert_includes doc.status_lines, "fail-fast 1, mutation does not load 1"
    assert_includes doc.status_lines, "deadline 1"
    assert_includes doc.status_lines, "unverified kill 1"
    payload = JSON.parse(doc.to_json)
    assert_equal({ "skipped" => { "fail_fast" => 1, "mutation_unloadable" => 1 },
                   "timeout" => { "deadline" => 1 }, "error" => { "unverified_kill" => 1 } },
                 payload["reasons"])
  end

  def test_not_measured_groups_by_reason_and_leaves_fail_fast_to_the_count
    results = [
      reasoned(:skipped, :fail_fast, message: "not run: --fail-fast stopped at the first survivor"),
      reasoned(:skipped, :suite_unloadable, line: 2, message: "the suite could not load (boom)")
    ]
    text = report(results).unmeasured_lines

    assert_includes text, "not measured (not scored):"
    assert_includes text, "lib/pricing.rb:2  the suite could not load (boom)"
    refute_includes text, "--fail-fast"
  end

  def test_uncovered_mutants_are_split_by_why_no_test_ran_them
    results = [
      Sabaku::Result.new(mutant: mutant(path: "lib/a.rb"), status: :uncovered, reason: :uninstrumented),
      Sabaku::Result.new(mutant: mutant(path: "lib/b.rb"), status: :uncovered, reason: :not_reached),
      Sabaku::Result.new(mutant: mutant(path: "lib/b.rb"), status: :killed)
    ]
    files = { "lib/a.rb" => Sabaku::CoverageMap::FileCoverage.new(path: "lib/a.rb", state: :uninstrumented),
              "lib/c.rb" => Sabaku::CoverageMap::FileCoverage.new(path: "lib/c.rb", state: :instrumented) }
    doc = Sabaku::Report.new(results, Sabaku::Config.default, coverage_files: files)

    assert_includes doc.status_lines, "uninstrumented 1, not reached 1"
    assert_match(%r{lib/a.rb\s+0/0\s+0.0%  \(uninstrumented\)}, doc.file_lines)
    payload = JSON.parse(doc.to_json)
    assert_equal [{ "path" => "lib/a.rb", "state" => "uninstrumented", "boot_lines" => [], "loaded_by" => nil }],
                 payload["coverage_files"]
  end

  MatrixMutant = Struct.new(:id, :path, :line, :column, :operator, :node_kind, :original,
                            :replacement, :description, keyword_init: true)

  def scored(id, status, killers: nil, tested: nil)
    mutant = MatrixMutant.new(id: id, path: "lib/calc.rb", line: 1, column: 0, operator: :aor,
                              node_kind: "CallNode", original: "a + b", replacement: "a - b",
                              description: "AOR: a + b -> a - b")
    kills = tested && Sabaku::Kills.new(tested: tested, killers: killers || [])
    Sabaku::Result.new(mutant: mutant, status: status, failed_test: killers&.min, kills: kills)
  end

  def matrix_report
    results = [
      scored("m1", :killed, killers: %w[C#strong C#twin C#weak], tested: %w[C#strong C#twin C#weak]),
      scored("m2", :killed, killers: %w[C#strong C#twin], tested: %w[C#strong C#twin C#weak]),
      scored("m3", :survived, tested: %w[C#smoke]),
      scored("m4", :killed, killers: %w[C#edge])
    ]
    matrix = Sabaku::KillMatrix.from(results, universe: %w[C#idle],
                                              selected: { "m4" => %w[C#edge C#weak] })
    report(results).class.new(results, Sabaku::Config.default, kill_matrix: matrix)
  end

  def test_without_a_matrix_the_report_has_no_section_and_no_rows
    doc = report([result(:killed), result(:survived)])

    refute_includes doc.to_terminal, "kill matrix"
    refute doc.to_h.key?(:kill_matrix)
    assert(doc.to_h[:results].none? { |row| row.key?(:kills) })
  end

  def test_terminal_names_zero_redundant_and_unique_tests
    text = matrix_report.to_terminal

    assert_includes text, "kill matrix: 3 of 4 killed+survived mutants have a complete row"
    assert_includes text, "1 incomplete"
    assert_includes text, "tests 6: kept 1, subsumed 1, duplicate 1, zero kills 2, idle 1"
    assert_match(/C#smoke\s+ran against 1 mutant, killed none/, text)
    assert_match(/C#idle\s+never selected/, text)
    assert_match(/C#edge\s+\?\s+selected only for mutants without a complete row/, text)
    assert_match(/C#twin\s+same 2 kills as C#strong/, text)
    assert_match(/C#weak\s+\? 1 kill, all also killed by C#strong/, text)
    assert_match(/top unique killers:\n\s+C#strong\s+unique 0  kills 2/, text)
  end

  def test_json_lists_tests_by_id_with_rows_on_results
    payload = JSON.parse(matrix_report.to_json)
    matrix = payload["kill_matrix"]

    assert_equal 3, matrix["rows"]
    assert_equal [{ "mutant" => "m4", "status" => "killed", "tested" => 2 }], matrix["incomplete"]
    assert_equal %w[C#edge C#idle C#smoke C#strong C#twin C#weak], matrix["tests"].map { |t| t["id"] }
    weak = matrix["tests"].find { |t| t["id"] == "C#weak" }
    assert_equal({ "id" => "C#weak", "verdict" => "subsumed", "kills" => 1, "unique" => 0,
                   "tested" => 2, "by" => "C#strong", "provisional" => true }, weak)
    assert_equal({ "kept" => 1, "subsumed" => 1, "duplicate" => 1, "zero" => 2, "idle" => 1,
                   "provisional" => 2 }, matrix["summary"])
    assert_equal %w[C#strong C#twin C#weak], payload["results"].first["kills"]["killers"]
    assert_nil payload["results"].last["kills"]
  end

  def test_matrix_lists_are_capped
    results = Array.new(25) { |index| scored("m#{index}", :survived, tested: ["Z#t#{index}"]) }
    matrix = Sabaku::KillMatrix.from(results, universe: [])
    text = report(results).class.new(results, Sabaku::Config.default, kill_matrix: matrix).to_terminal

    assert_includes text, "... and 5 more"
  end

  def test_per_file_groups_and_rates
    results = [result(:killed, path: "lib/a.rb"), result(:survived, path: "lib/a.rb"),
               result(:killed, path: "lib/b.rb")]
    files = report(results).per_file.to_h { |f| [f[:path], f] }
    assert_equal 2, files["lib/a.rb"][:counted]
    assert_equal 1, files["lib/a.rb"][:killed]
    assert_in_delta 0.5, files["lib/a.rb"][:rate]
    assert_in_delta 1.0, files["lib/b.rb"][:rate]
  end
end
