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
    Mutation::Result.new(mutant: mutant(**kwargs), status: status, duration: 0.01)
  end

  def report(results, overrides = {})
    Mutation::Report.new(results, Mutation::Config.default(**overrides))
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
    errored = Mutation::Result.new(
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
      Mutation::Result.new(mutant: mutant(line: index + 1), status: :error, message: "boom")
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
      Mutation::Result.new(mutant: mutant(line: 2), status: :survived, reason: :not_infected)
    ]
    doc = report(results)

    assert_includes doc.status_lines, "not detected 1, not infected 1"
    assert_includes doc.to_terminal, "(not infected)"
    payload = JSON.parse(doc.to_json)
    assert_equal({ "not_detected" => 1, "not_infected" => 1 }, payload["survived_reasons"])
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
