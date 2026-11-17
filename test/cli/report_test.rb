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
