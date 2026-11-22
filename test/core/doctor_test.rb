# frozen_string_literal: true

require_relative "../test_helper"

class DoctorTest < Minitest::Test
  def facts(**overrides)
    Sabaku::Doctor::Facts.new(**{ boot_error: nil, coverage_modes: [], parallel_executor: nil,
                                  unloaded_targets: [], jobs: 1, child_start: nil, concerns: [],
                                  sorbet_runtime: false }.merge(overrides))
  end

  def findings(**overrides) = Sabaku::Doctor.findings(facts(**overrides)).to_h { |f| [f.id, f] }

  def test_a_clean_boot_has_no_findings
    assert_empty findings
  end

  def test_unbooted_facts_say_nothing_about_the_boot
    assert_empty findings(coverage_modes: nil, parallel_executor: nil, unloaded_targets: nil,
                          sorbet_runtime: nil)
  end

  def test_coverage_without_line_counters_is_a_warning
    finding = findings(coverage_modes: %i[oneshot_lines])[:coverage_mode]

    assert_equal :warn, finding.severity
    assert_includes finding.message, "oneshot_lines"
    assert_equal "docs/rails.md#simplecov", finding.doc
  end

  def test_a_target_the_boot_did_not_load_is_a_warning
    finding = findings(unloaded_targets: %w[app/models/a.rb app/models/b.rb])[:eager_load]

    assert_equal :warn, finding.severity
    assert_includes finding.message, "app/models/a.rb"
    assert_equal "docs/rails.md#why-eager-load", finding.doc
  end

  def test_jobs_above_one_without_child_start_is_a_warning
    assert_equal :warn, findings(jobs: 4, child_start: false)[:child_start].severity
    assert_nil findings(jobs: 4, child_start: true)[:child_start]
    assert_nil findings(jobs: 1, child_start: false)[:child_start]
    assert_nil findings(jobs: 4, child_start: nil)[:child_start], "no setup file, nothing to share"
  end

  def test_rails_parallelize_is_named_as_harmless
    finding = findings(parallel_executor: "ActiveSupport::Testing::ParallelizeExecutor")[:parallel_executor]

    assert_equal :info, finding.severity
    assert_nil findings(parallel_executor: "Minitest::Parallel::Executor")[:parallel_executor]
  end

  def test_concerns_and_sorbet_point_at_their_recipes
    assert_equal "docs/rails.md#concerns", findings(concerns: %w[app/models/concerns/x.rb])[:concerns].doc
    assert_equal "docs/rails.md#sorbet", findings(sorbet_runtime: true)[:sorbet_runtime].doc
  end

  def test_every_doc_a_finding_or_a_skip_hint_names_is_a_heading_in_docs_rails
    every = findings(boot_error: "x", coverage_modes: %i[oneshot_lines], parallel_executor: "Other",
                     unloaded_targets: %w[a.rb], jobs: 2, child_start: false, concerns: %w[a.rb],
                     sorbet_runtime: true)
    docs = every.values.filter_map(&:doc) + Sabaku::Report::SKIP_HINTS.map(&:doc)
    headings = File.read(File.expand_path("../../docs/rails.md", __dir__))
                   .scan(/^#+ (.+)$/).flatten
                   .map { |title| "docs/rails.md##{title.downcase.gsub(/[^a-z0-9 -]/, "").tr(" ", "-")}" }

    assert_equal Sabaku::Doctor::CHECKS.size, every.size
    assert_empty docs.uniq - headings
  end

  def test_a_boot_that_fails_is_a_warning_with_its_error
    finding = findings(boot_error: "BootError: after_boot hook failed: NameError")[:boot]

    assert_equal :warn, finding.severity
    assert_includes finding.message, "after_boot hook failed"
  end
end
