#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end cost model for the Ruby mutation engine, plus the day-one reference
# numbers that exist before the engine does.
#
#   reference_process_full : one fresh `ruby` process per synthetic mutant, whole
#                            suite. This is what a naive re-run-everything tool costs.
#   reference_fork_full    : preload the fixture's tests once in the parent, then
#                            fork per mutant and run the whole suite in the child.
#                            This is the fork-reuse baseline.
#   engine                 : best effort. Runs bin/mutation on the fixture when the
#                            library is present and parses its JSON report; records
#                            "absent" and keeps going otherwise.
#
# Modes are repeated (default 5) and alternated in order; each mode's wall time is
# reported as a median plus min/max range, never as a single run.
#
# Runnable from the repo root as: ./bin/rt ruby bench/campaign.rb

require "etc"
require "fileutils"
require "json"
require "optparse"
require "rbconfig"
require "time"
require "timeout"
require "tmpdir"

module Campaign
  ROOT = File.expand_path("..", __dir__)
  FIXTURE_NAME = "minitest_calc"
  FIXTURE_DIR = File.join(ROOT, "fixture", FIXTURE_NAME)
  FIXTURE_LIB = File.join(FIXTURE_DIR, "lib", "pricing.rb")
  ENGINE_BIN = File.join(ROOT, "bin", "mutation")
  OUT_PATH = File.join(__dir__, "out", "campaign.json")

  DEFAULT_MUTANTS = 20
  DEFAULT_REPS = 5
  PROJECTION_MUTANTS = 500
  SUITE_TIMEOUT_S = 60.0
  ENGINE_TIMEOUT_S = 60.0

  MINITEST_SUMMARY = /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/

  def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def self.median(sorted)
    n = sorted.length
    return nil if n.zero?

    n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  end

  def self.percentile(sorted, fraction)
    return nil if sorted.empty?

    rank = (fraction * sorted.length).ceil
    rank = 1 if rank < 1
    rank = sorted.length if rank > sorted.length
    sorted[rank - 1]
  end

  class Session
    def initialize(options)
      @options = options
      @started_at = Time.now.utc.iso8601
      @tmpdir = Dir.mktmpdir("ruby-mutation-campaign-")
      @process_log = File.join(@tmpdir, "process_suite.log")
      @fork_log = File.join(@tmpdir, "fork_suite.log")
      @engine_stdout = File.join(@tmpdir, "engine_stdout.log")
      @engine_report = File.join(@tmpdir, "engine_report.json")
      @precheck_log = File.join(@tmpdir, "precheck.log")
      @capture_sequence = 0
      @measurements = Hash.new { |hash, key| hash[key] = [] }
      @retries = Hash.new(0)
      @engine_errors = []
      @engine_runs = []
      @precheck = nil
    end

    def run
      $stdout.sync = true
      $stderr.sync = true
      validate_fixture!
      puts "ruby-mutation campaign: ruby #{RUBY_VERSION}, #{Etc.nprocessors} cpus, load #{load_average} (1/5/15m)"
      puts "fixture: #{FIXTURE_NAME} (#{FIXTURE_LIB.sub("#{ROOT}/", "")})"
      puts

      expected_runs = precheck!
      candidates = synthetic_candidates(@options[:mutants])
      puts "synthetic mutant candidates: #{candidates.length} (labels only; no source is modified)"
      puts "reps per mode: #{@options[:reps]}#{@options[:reps] < 5 ? " (WARNING: fewer than 5 is a smoke run, not a verdict)" : ""}"
      puts

      engine_info = detect_engine
      describe_engine(engine_info)
      puts

      preload_fork!(expected_runs)
      measure_all(candidates, expected_runs, engine_info)

      summaries = {
        "reference_process_full" => reference_summary("reference_process_full"),
        "reference_fork_full" => reference_summary("reference_fork_full")
      }
      engine_summary = engine_info[:available] ? engine_result_summary : nil
      engine_status = if !engine_info[:available]
                        "absent"
                      elsif engine_summary
                        "ok"
                      else
                        "error"
                      end

      campaign = build_campaign(candidates, summaries, engine_summary, engine_info, engine_status)
      print_summary(summaries, engine_summary, engine_info, engine_status, campaign)
      write_json(campaign)
    end

    def cleanup
      FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    end

    private

    def options = @options

    def validate_fixture!
      unless File.file?(FIXTURE_LIB)
        raise "fixture lib not found: #{FIXTURE_LIB}"
      end
      test_file = File.join(FIXTURE_DIR, "test", "pricing_test.rb")
      raise "fixture test not found: #{test_file}" unless File.file?(test_file)
    end

    def load_average
      File.read("/proc/loadavg").split.first(3).join(" ")
    rescue StandardError
      "n/a"
    end

    def parse_summary(text)
      match = MINITEST_SUMMARY.match(text.to_s)
      return nil unless match

      %i[runs assertions failures errors skips].zip(match.captures.map(&:to_i)).to_h
    end

    def tail(text, limit = 1200)
      text = text.to_s
      text.length <= limit ? text : "...(truncated)...\n#{text[-limit..]}"
    end

    def read_log(path)
      File.file?(path) ? File.read(path) : ""
    rescue StandardError
      ""
    end

    def wait_with_timeout(pid, seconds, label, group: false)
      Timeout.timeout(seconds) { Process.wait2(pid) }
    rescue Timeout::Error
      # Only spawned children were put in their own process group. A forked child
      # shares ours, so killing -pid for it could target an unrelated group.
      if group
        begin
          Process.kill("KILL", -pid)
        rescue StandardError
          # group is already gone
        end
      end
      begin
        Process.kill("KILL", pid)
      rescue StandardError
        # already gone
      end
      begin
        Process.wait2(pid)
      rescue StandardError
        # already reaped
      end
      raise "timed out after #{seconds}s (#{label})"
    end

    # Runs one fresh `ruby` process containing the whole fixture suite and returns
    # [elapsed_seconds, Process::Status, captured_output]. The timed region is
    # spawn + wait; reading and parsing the log happen after the clock stops.
    def run_fresh_suite(log_path)
      argv = [RbConfig.ruby, "-Ilib", "-Itest", "test/pricing_test.rb"]
      env = { "RUBYOPT" => nil, "RUBYLIB" => nil }
      t0 = Campaign.clock
      pid = Process.spawn(env, *argv, chdir: FIXTURE_DIR, out: log_path,
                          err: [:child, :out], pgroup: true)
      _, status = wait_with_timeout(pid, SUITE_TIMEOUT_S, "fresh fixture suite", group: true)
      elapsed = Campaign.clock - t0
      [elapsed, status, read_log(log_path)]
    end

    def verify_suite!(output, expected_runs, context)
      counts = parse_summary(output)
      unless counts
        raise "#{context}: no minitest summary in child output\n#{tail(output)}"
      end
      unless counts[:runs] == expected_runs
        raise "#{context}: expected #{expected_runs} runs, got #{counts[:runs]}\n#{tail(output)}"
      end
      unless counts[:failures].zero? && counts[:errors].zero?
        raise "#{context}: suite did not pass\n#{tail(output)}"
      end
      counts
    end

    def precheck!
      elapsed, status, output = run_fresh_suite(@precheck_log)
      counts = parse_summary(output)
      raise "precheck: no minitest summary in child output\n#{tail(output)}" unless counts
      raise "precheck: fixture suite reported 0 runs\n#{tail(output)}" if counts[:runs].zero?

      verify_suite!(output, counts[:runs], "precheck")
      unless status.success?
        raise "precheck: fixture suite exited #{status.exitstatus}\n#{tail(output)}"
      end
      @precheck = counts.merge(elapsed_s: elapsed)
      puts format("precheck: %d runs, %d assertions, 0 failures, 0 errors in %.1f ms (untimed)",
                  counts[:runs], counts[:assertions], elapsed * 1000.0)
      counts[:runs]
    end

    def synthetic_candidates(count)
      lines = File.readlines(FIXTURE_LIB)
      interesting = lines.each_with_index.filter_map do |line, index|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")
        next unless line.match?(/[+\-*\/<>=!&|]/)

        index + 1
      end
      raise "no candidate lines found in #{FIXTURE_LIB}" if interesting.empty?

      Array.new(count) do |index|
        {
          "id" => format("synthetic-%04d", index + 1),
          "line" => interesting[index % interesting.length]
        }
      end
    end

    def capture(argv, chdir:, timeout:)
      @capture_sequence += 1
      path = File.join(@tmpdir, "capture-#{@capture_sequence}.log")
      pid = Process.spawn(*argv, chdir: chdir, out: path, err: [:child, :out], pgroup: true)
      _, status = wait_with_timeout(pid, timeout, argv.first, group: true)
      [read_log(path), status]
    rescue Timeout::Error
      ["", nil]
    rescue StandardError => e
      ["capture failed: #{e.class}: #{e.message}", nil]
    end

    def detect_engine
      return { available: false, status: "absent", reason: "disabled by --skip-engine" } if @options[:skip_engine]

      unless File.file?(ENGINE_BIN)
        return { available: false, status: "absent", reason: "bin/mutation not found" }
      end

      version_out, version_status = capture(
        [RbConfig.ruby, ENGINE_BIN, "--version"], chdir: ROOT, timeout: 15.0
      )
      version_ok = version_status&.success? && version_out.match?(/ruby-mutation/i)

      require_ok = false
      unless version_ok
        _require_out, require_status = capture(
          [RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", "-e", 'require "mutation"'],
          chdir: ROOT, timeout: 15.0
        )
        require_ok = require_status&.success?
      end

      if version_ok || require_ok
        {
          available: true,
          status: "ok",
          reason: version_ok ? "bin/mutation --version exited 0" : 'require "mutation" succeeded'
        }
      else
        {
          available: false,
          status: "absent",
          reason: 'bin/mutation --version and ruby -Ilib -e "require \"mutation\"" both failed'
        }
      end
    end

    def describe_engine(engine_info)
      if engine_info[:available]
        puts "engine: present (#{engine_info[:reason]}); mode will run bin/mutation on the fixture"
        puts "engine cache: disabled for timing (RUBY_MUTATION_NO_CACHE=1; cache hits report duration 0)"
      else
        puts "engine: absent (#{engine_info[:reason]}); reference-only campaign, continuing"
      end
    end

    # Loads the fixture's test classes into this process once. minitest's autorun
    # at_exit hook is suppressed on purpose: without that, the parent would run the
    # whole suite again when the campaign exits. Children call Minitest.run
    # explicitly and then exit!.
    def preload_fork!(expected_runs)
      require "minitest"
      suppress_minitest_autorun!
      $LOAD_PATH.unshift(File.join(FIXTURE_DIR, "lib"), File.join(FIXTURE_DIR, "test"))
      require "pricing"
      require File.join(FIXTURE_DIR, "test", "pricing_test.rb")

      Minitest.seed = @options[:seed]
      runnables = Minitest::Runnable.runnables.select { |runnable| runnable.runnable_methods.any? }
      total = runnables.sum { |runnable| runnable.runnable_methods.length }
      unless total == expected_runs
        raise "preloaded #{total} tests but a fresh process reported #{expected_runs}"
      end

      @preloaded_runnables = runnables
      puts "fork preload: #{runnables.map(&:name).join(", ")} (#{total} tests) resident in the parent"
    end

    def suppress_minitest_autorun!
      Minitest.singleton_class.class_eval do
        unless method_defined?(:bench_original_autorun)
          alias_method :bench_original_autorun, :autorun
        end

        # The parent only preloads; children call Minitest.run directly.
        define_method(:autorun) { nil }
      end
    end

    def with_retry(mode_id)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue StandardError
        @retries[mode_id] += 1
        retry if attempts < 2
        raise
      end
    end

    def process_leg(expected_runs)
      with_retry("reference_process_full") do
        elapsed, status, output = run_fresh_suite(@process_log)
        unless status.success?
          raise "reference_process_full: fresh process exited #{status.exitstatus}\n#{tail(output)}"
        end
        verify_suite!(output, expected_runs, "reference_process_full")
        elapsed
      end
    end

    def fork_leg(expected_runs)
      with_retry("reference_fork_full") do
        t0 = Campaign.clock
        pid = fork do
          begin
            $stdout.reopen(@fork_log, "w")
            $stderr.reopen($stdout)
            ok = Minitest.run(["--seed", @options[:seed].to_s])
            $stdout.flush
            exit!(ok ? 0 : 1)
          rescue Exception => e # rubocop:disable Lint/RescueException
            begin
              $stdout.write("fork child crashed: #{e.class}: #{e.message}\n")
              $stdout.write(Array(e.backtrace).first(8).join("\n"))
              $stdout.write("\n")
              $stdout.flush
            rescue Exception # rubocop:disable Lint/RescueException
              # nothing left to do
            end
            exit!(97)
          end
        end
        _, status = wait_with_timeout(pid, SUITE_TIMEOUT_S, "forked fixture suite")
        elapsed = Campaign.clock - t0
        output = read_log(@fork_log)
        unless status.exitstatus == 0
          raise "reference_fork_full: child exited #{status.exitstatus.inspect}\n#{tail(output)}"
        end
        verify_suite!(output, expected_runs, "reference_fork_full")
        elapsed
      end
    end

    def engine_argv(json_flag)
      [
        RbConfig.ruby,
        "-I#{File.join(ROOT, "lib")}",
        ENGINE_BIN,
        "run",
        "--adapter=minitest",
        "--jobs=1",
        "--seed=#{@options[:seed]}",
        json_flag,
        "--output=#{@engine_report}",
        "lib/pricing.rb"
      ]
    end

    def engine_attempt(json_flag)
      File.delete(@engine_report) if File.file?(@engine_report)
      # The engine reads its own cache before the env kill switch only if a
      # stale file is present; remove it as well so a code change can never be
      # masked by an old result.
      fixture_cache = File.join(FIXTURE_DIR, ".mutation-cache.json")
      begin
        File.delete(fixture_cache) if File.file?(fixture_cache)
      rescue SystemCallError
        nil
      end
      t0 = Campaign.clock
      # A cache hit skips the child by design and reports duration 0, so a warm
      # cache would measure JSON parsing rather than mutant execution. Force cold
      # runs for every engine repetition.
      env = { "RUBYOPT" => nil, "RUBYLIB" => nil, "RUBY_MUTATION_NO_CACHE" => "1" }
      pid = Process.spawn(env, *engine_argv(json_flag),
                          chdir: FIXTURE_DIR, out: @engine_stdout,
                          err: [:child, :out], pgroup: true)
      _, status = wait_with_timeout(pid, @options[:engine_timeout], "engine", group: true)
      elapsed = Campaign.clock - t0
      output = read_log(@engine_stdout)
      report = nil
      if File.file?(@engine_report)
        begin
          report = JSON.parse(File.read(@engine_report))
        rescue JSON::ParserError
          report = nil
        end
      end
      report ||= parse_json_from_output(output)
      [report, elapsed, status, output]
    end

    def engine_leg
      report, elapsed, status, output = engine_attempt("--report=json")
      if !(status&.success?) && output.match?(/invalid option.*--report|--report.*invalid/i)
        # Forward compatibility with a CLI that only grew a --json alias.
        report, elapsed, status, output = engine_attempt("--json")
      end
      unless status&.success?
        raise "engine exited #{status&.exitstatus.inspect}\n#{tail(output)}"
      end
      report ||= parse_json_from_output(output)
      raise "engine produced no parseable JSON report\n#{tail(output)}" unless report

      [normalize_engine_data(report), elapsed]
    end

    def parse_json_from_output(text)
      text = text.to_s
      stripped = text.strip
      if stripped.start_with?("{", "[")
        begin
          return JSON.parse(stripped)
        rescue JSON::ParserError
          # fall through to line-by-line recovery
        end
      end

      text.lines.reverse_each do |line|
        candidate = line.strip
        next unless candidate.start_with?("{")

        begin
          return JSON.parse(candidate)
        rescue JSON::ParserError
          next
        end
      end
      nil
    end

    def normalize_engine_data(report)
      raise "engine JSON root is #{report.class}, expected object" unless report.is_a?(Hash)

      results = report["results"]
      statuses = results.is_a?(Array) ? results.map { |result| result["status"].to_s } : []
      counts = {}
      %w[killed survived timeout error uncovered].each do |key|
        value = report[key]
        value = statuses.count(key) if value.nil? && results
        raise "engine JSON lacks #{key}" if value.nil?

        counts[key] = Integer(value)
      end

      mutants = report["mutants"]
      mutants = results.length if mutants.nil? && results
      raise "engine JSON lacks mutants" if mutants.nil?

      durations_ms = []
      if results.is_a?(Array)
        # Only counted, executed mutants carry a meaningful per-mutant cost.
        # :uncovered never ran, and :error is a boot/apply failure (usually a
        # zero-duration attempt), so neither belongs in the timing distribution.
        timed_statuses = %w[killed survived timeout]
        durations_ms = results.filter_map do |result|
          next unless timed_statuses.include?(result["status"].to_s)

          duration = result["duration"]
          duration.nil? ? nil : Float(duration) * 1000.0
        end
      end

      denominator = counts["killed"] + counts["survived"] + counts["timeout"]
      score = report["score"]
      score = denominator.positive? ? counts["killed"].fdiv(denominator) : 0.0 if score.nil?

      {
        mutants: Integer(mutants),
        killed: counts["killed"],
        survived: counts["survived"],
        timeout: counts["timeout"],
        error: counts["error"],
        uncovered: counts["uncovered"],
        score: Float(score),
        durations_ms: durations_ms,
        reported_wall_ms: report["wall_ms"]
      }
    end

    def measure_all(candidates, expected_runs, engine_info)
      mode_ids = ["reference_process_full", "reference_fork_full"]
      mode_ids << "engine" if engine_info[:available]

      @options[:reps].times do |rep|
        order = mode_ids.dup
        order.reverse! if rep.odd?
        order.rotate!(rep % order.length)
        parts = []

        order.each do |mode_id|
          case mode_id
          when "reference_process_full"
            legs = candidates.map { process_leg(expected_runs) }
            @measurements[mode_id] << {
              wall_s: legs.sum,
              legs_ms: legs.map { |seconds| seconds * 1000.0 },
              verified: legs.length
            }
            parts << format("process=%.2fs", legs.sum)
          when "reference_fork_full"
            legs = candidates.map { fork_leg(expected_runs) }
            @measurements[mode_id] << {
              wall_s: legs.sum,
              legs_ms: legs.map { |seconds| seconds * 1000.0 },
              verified: legs.length
            }
            parts << format("fork=%.2fs", legs.sum)
          when "engine"
            begin
              data, wall = engine_leg
              @engine_runs << data
              @measurements[mode_id] << {
                wall_s: wall,
                durations_ms: data[:durations_ms],
                verified: data[:mutants],
                data: data
              }
              parts << format("engine=%.2fs", wall)
            rescue StandardError => e
              @engine_errors << e.message
              @measurements[mode_id] << { wall_s: nil, durations_ms: [], verified: 0, error: e.message }
              parts << "engine=ERROR"
            end
          end
        end

        puts format("rep %d/%d: %s", rep + 1, @options[:reps], parts.join("  "))
      end
      puts

      if engine_info[:available] && !@engine_errors.empty?
        puts "engine warnings: #{@engine_errors.uniq.length} failed rep(s); first error:"
        puts "  #{@engine_errors.first.lines.first&.strip}"
        puts
      end
    end

    def reference_summary(mode_id)
      entries = @measurements[mode_id]
      walls = entries.map { |entry| entry[:wall_s] }.compact.sort
      raise "no successful runs for #{mode_id}" if walls.empty?

      legs_ms = entries.flat_map { |entry| entry[:legs_ms] || [] }.sort
      rep_p50s = entries.filter_map do |entry|
        entry[:legs_ms] && Campaign.percentile(entry[:legs_ms].sort, 0.5)
      end
      wall_s = Campaign.median(walls)
      {
        "id" => mode_id,
        "wall_s" => wall_s,
        "wall_min_s" => walls.first,
        "wall_max_s" => walls.last,
        "reps" => walls.length,
        "mutants_per_rep" => @options[:mutants],
        "per_mutant_wall_ms" => wall_s * 1000.0 / @options[:mutants],
        "p50_metric" => "whole_leg_wall",
        "verified_legs" => entries.sum { |entry| entry[:verified] || 0 },
        "retries" => @retries[mode_id],
        "mutant_p50_ms" => Campaign.percentile(legs_ms, 0.5),
        "mutant_p95_ms" => Campaign.percentile(legs_ms, 0.95),
        "mutant_p50_range_ms" => rep_p50s.empty? ? nil : [rep_p50s.min, rep_p50s.max]
      }
    end

    def engine_result_summary
      entries = @measurements["engine"]
      ok = entries.select { |entry| entry[:wall_s] }
      return nil if ok.empty?

      # While the engine is landing, individual repetitions can be transiently
      # broken (e.g. all :error, or statuses with zero durations). Use only
      # fully healthy repetitions for timing/counts when at least one exists;
      # the attempted/healthy counts stay in the JSON so the gap is visible.
      healthy = ok.select do |entry|
        data = entry[:data]
        data && data[:error].to_i.zero? && (entry[:durations_ms] || []).any?(&:positive?)
      end
      used = healthy.empty? ? ok : healthy
      walls = used.map { |entry| entry[:wall_s] }.sort
      durations_ms = used.flat_map { |entry| entry[:durations_ms] || [] }.sort
      rep_p50s = used.filter_map do |entry|
        values = entry[:durations_ms] || []
        Campaign.percentile(values.sort, 0.5) unless values.empty?
      end

      canonical_pool = healthy.empty? ? ok : healthy
      canonical = canonical_pool.map { |entry| entry[:data] }.min_by do |run|
        [run[:error], -(run[:killed] + run[:survived] + run[:timeout])]
      end

      wall_s = Campaign.median(walls)
      child_p50 = Campaign.percentile(durations_ms, 0.5)
      child_p95 = Campaign.percentile(durations_ms, 0.95)
      executed = canonical[:killed] + canonical[:survived] + canonical[:timeout]
      summary = {
        "id" => "engine",
        "wall_s" => wall_s,
        "wall_min_s" => walls.first,
        "wall_max_s" => walls.last,
        "reps" => used.length,
        "attempted_reps" => ok.length,
        "healthy_reps" => healthy.length,
        "mutants" => canonical[:mutants],
        "killed" => canonical[:killed],
        "survived" => canonical[:survived],
        "timeout" => canonical[:timeout],
        "error" => canonical[:error],
        "uncovered" => canonical[:uncovered],
        "score" => canonical[:score],
        "per_mutant_wall_ms" => wall_s * 1000.0 / canonical[:mutants],
        "p50_metric" => "child_duration",
        # End-to-end wall per mutant includes the engine's one-time boot/preload.
        # This is the number to plan with; mutant_p50_ms is the child's own time.
        "mutant_p50_ms" => child_p50,
        "mutant_p95_ms" => child_p95,
        "child_p50_ms" => child_p50,
        "child_p95_ms" => child_p95,
        "mutant_p50_range_ms" => rep_p50s.empty? ? nil : [rep_p50s.min, rep_p50s.max],
        "executed_mutants" => executed,
        "timed_mutants" => durations_ms.length,
        "verified_legs" => used.sum { |entry| entry[:verified] || 0 }
      }
      summary["errors"] = @engine_errors.uniq unless @engine_errors.empty?
      summary
    end

    def build_campaign(candidates, summaries, engine_summary, engine_info, engine_status)
      process = summaries["reference_process_full"]
      fork = summaries["reference_fork_full"]
      reference_basis = [process, fork].min_by { |summary| summary["wall_s"] }
      # A present-but-incomplete engine can report every mutant as uncovered (or
      # as a zero-duration result) and therefore have no meaningful timed cost.
      # Prefer the reference path for the top-level cost numbers in that case,
      # while still recording the engine result fields and mode entry verbatim.
      engine_basis =
        if engine_summary && engine_summary["mutant_p50_ms"].to_f.positive?
          engine_summary
        end
      basis = engine_basis || reference_basis
      basis_id = engine_basis ? "engine" : reference_basis["id"]

      modes = [process, fork]
      if engine_info[:available]
        modes << (engine_summary || {
          "id" => "engine",
          "wall_s" => nil,
          "error" => @engine_errors.last || "engine did not complete a successful rep"
        })
      end

      projection = { "mutants" => PROJECTION_MUTANTS, "single_worker" => true, "minutes" => {} }
      modes.each do |summary|
        p50 = summary["mutant_p50_ms"]
        next unless p50&.positive?

        projection["minutes"][summary["id"]] = (p50 * PROJECTION_MUTANTS / 60_000.0).round(4)
      end

      campaign = {
        "name" => "campaign",
        "started_at" => @started_at,
        "ruby" => RUBY_VERSION,
        "cpu_count" => Etc.nprocessors,
        "fixture" => FIXTURE_NAME,
        "engine" => engine_status,
        "engine_reason" => engine_info[:reason],
        "precheck" => @precheck,
        "synthetic_mutants" => candidates.length,
        "mutants" => engine_summary&.fetch("mutants"),
        "killed" => engine_summary&.fetch("killed"),
        "survived" => engine_summary&.fetch("survived"),
        "timeout" => engine_summary&.fetch("timeout"),
        "error" => engine_summary&.fetch("error"),
        "uncovered" => engine_summary&.fetch("uncovered"),
        "score" => engine_summary&.fetch("score"),
        "engine_timed_mutants" => engine_summary&.fetch("timed_mutants"),
        "wall_s" => basis["wall_s"],
        "wall_min_s" => basis["wall_min_s"],
        "wall_max_s" => basis["wall_max_s"],
        "wall_s_basis" => basis_id,
        "per_mutant_wall_ms" => basis["per_mutant_wall_ms"],
        "p50_metric" => basis["p50_metric"],
        "mutant_p50_ms" => basis["mutant_p50_ms"],
        "mutant_p95_ms" => basis["mutant_p95_ms"],
        "modes" => modes,
        "projection" => projection
      }
      campaign["engine_errors"] = @engine_errors.uniq unless @engine_errors.empty?
      campaign
    end

    def print_summary(summaries, engine_summary, engine_info, engine_status, campaign)
      puts "campaign results"
      puts format("%-24s %12s %17s %16s %18s %12s %12s %10s",
                  "mode", "wall/rep (s)", "wall range (s)", "wall/mutant (ms)",
                  "p50 metric", "p50 (ms)", "p95 (ms)", "verified")
      puts "-" * 137
      [summaries["reference_process_full"], summaries["reference_fork_full"]].each do |summary|
        print_mode_row(summary)
      end
      if engine_summary
        print_mode_row(engine_summary)
      else
        puts format("%-24s %12s %17s %16s %18s %12s %12s %10s",
                    "engine", engine_status, "-", "-", "-", "-", "-", "-")
      end
      puts

      if engine_summary
        puts format("engine: %s, %d mutants, killed=%d survived=%d timeout=%d error=%d uncovered=%d score=%.4f",
                    engine_status, engine_summary["mutants"], engine_summary["killed"],
                    engine_summary["survived"], engine_summary["timeout"], engine_summary["error"],
                    engine_summary["uncovered"], engine_summary["score"])
        if engine_summary["healthy_reps"].to_i < engine_summary["attempted_reps"].to_i
          puts "engine note: #{engine_summary["healthy_reps"]}/#{engine_summary["attempted_reps"]} " \
               "engine repetition(s) fully healthy; timing/counts use the healthy ones"
        end
        if engine_summary["error"].to_i.positive?
          puts "engine note: #{engine_summary["error"]} mutant(s) reported :error (apply/boot failure); " \
               "they are excluded from the score and from p50/p95"
        end
        if engine_summary["mutant_p50_ms"].to_f <= 0.0
          puts "engine note: no positive per-mutant cost was measured (all results were " \
               "uncovered/error/zero-duration); top-level wall_s/p50/p95 use #{campaign["wall_s_basis"]} instead"
        end
      else
        puts "engine: #{engine_status} (#{engine_info[:reason]})"
      end
      puts "wall_s basis: #{campaign["wall_s_basis"]} (the basis for the top-level wall_s/p50/p95 numbers)"
      puts

      puts "projection (single worker, whole suite, no coverage-based selection):"
      campaign["projection"]["minutes"].each do |mode_id, minutes|
        p50 = [summaries["reference_process_full"], summaries["reference_fork_full"], engine_summary]
              .compact.find { |summary| summary["id"] == mode_id }["mutant_p50_ms"]
        puts format("  at %.1f ms per mutant, a %d-mutant campaign costs %.2f minutes (%s)",
                    p50, PROJECTION_MUTANTS, minutes, mode_id)
      end
      if engine_summary && engine_summary["per_mutant_wall_ms"]
        puts format("  engine end-to-end: %.1f ms/mutant over %d mutants (%.0f ms wall); "                     "child p50 %.1f ms excludes the one-time startup/preload",
                    engine_summary["per_mutant_wall_ms"], engine_summary["mutants"],
                    engine_summary["wall_s"] * 1000.0, engine_summary["mutant_p50_ms"])
      end
      process_p50 = summaries["reference_process_full"]["mutant_p50_ms"]
      fork_p50 = summaries["reference_fork_full"]["mutant_p50_ms"]
      if process_p50 && fork_p50 && fork_p50.positive?
        puts format("  fork reuse is %.1fx cheaper per mutant than a fresh process on this fixture",
                    process_p50 / fork_p50)
      end
      if @retries.values.any?(&:positive?)
        puts "  retries: #{@retries.map { |mode, count| "#{mode}=#{count}" }.join(", ")}"
      end
    end

    def print_mode_row(summary)
      range = format("%.2f..%.2f", summary["wall_min_s"], summary["wall_max_s"])
      per_mutant = summary["per_mutant_wall_ms"] ? format("%.1f", summary["per_mutant_wall_ms"]) : "-"
      metric = summary["p50_metric"] || "-"
      p50_range = summary["mutant_p50_range_ms"]
      p50_value = summary["mutant_p50_ms"]
      p50_text = p50_value ? format("%.1f", p50_value) : "-"
      p50_text += " [%.1f..%.1f]" % p50_range if p50_range
      p95_text = summary["mutant_p95_ms"] ? format("%.1f", summary["mutant_p95_ms"]) : "-"
      puts format("%-24s %12.2f %17s %16s %18s %12s %12s %10d",
                  summary["id"], summary["wall_s"], range, per_mutant,
                  metric, p50_text, p95_text, summary["verified_legs"])
    end

    def write_json(campaign)
      FileUtils.mkdir_p(File.dirname(@options[:out]))
      File.write(@options[:out], "#{JSON.pretty_generate(campaign)}\n")
      puts
      puts "wrote #{@options[:out].sub("#{ROOT}/", "")}"
    end
  end

  def self.parse_options(argv)
    options = {
      mutants: DEFAULT_MUTANTS,
      reps: DEFAULT_REPS,
      seed: 1234,
      skip_engine: false,
      engine_timeout: ENGINE_TIMEOUT_S,
      out: OUT_PATH
    }
    parser = OptionParser.new do |opts|
      opts.banner = "usage: ruby bench/campaign.rb [options]"
      opts.on("--mutants=N", Integer, "synthetic mutant candidates (default #{DEFAULT_MUTANTS})") do |value|
        options[:mutants] = value
      end
      opts.on("--reps=N", Integer, "repetitions per mode (default #{DEFAULT_REPS}, should be >= 5)") do |value|
        options[:reps] = value
      end
      opts.on("--seed=N", Integer, "seed for synthetic candidates and engine runs") do |value|
        options[:seed] = value
      end
      opts.on("--engine-timeout=SEC", Float, "wall deadline for one engine run") do |value|
        options[:engine_timeout] = value
      end
      opts.on("--skip-engine", "do not probe or run the engine") { options[:skip_engine] = true }
      opts.on("--out=PATH", "JSON output path (default bench/out/campaign.json)") do |value|
        options[:out] = File.expand_path(value, ROOT)
      end
      opts.on("-h", "--help", "this") do
        puts opts
        exit 0
      end
    end
    parser.parse!(argv)
    raise OptionParser::InvalidArgument, "--mutants must be >= 1" if options[:mutants] < 1
    raise OptionParser::InvalidArgument, "--reps must be >= 1" if options[:reps] < 1
    raise OptionParser::InvalidArgument, "--engine-timeout must be > 0" unless options[:engine_timeout].positive?

    options
  end
end

begin
  options = Campaign.parse_options(ARGV)
rescue OptionParser::ParseError => e
  warn "campaign: #{e.message}"
  exit 2
end

session = Campaign::Session.new(options)
begin
  session.run
ensure
  session.cleanup
end
