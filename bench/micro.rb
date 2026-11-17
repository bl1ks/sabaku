#!/usr/bin/env ruby
# frozen_string_literal: true

# Primitive-cost microbenchmarks for the Ruby mutation engine.
#
# Every case times one operation with CLOCK_MONOTONIC, after a per-case warmup,
# and is measured in ROUNDS interleaved rounds so drift and host noise are spread
# across cases instead of landing on whichever case happened to run during a
# spike. The JSON written to bench/out/micro.json is the schema frozen in
# docs/DESIGN.md ("Harness contract").
#
# Runnable from the repo root as: ./bin/rt ruby bench/micro.rb

require "coverage"
require "etc"
require "fileutils"
require "json"
require "prism"
require "rbconfig"
require "time"
require "tmpdir"

module Micro
  ROOT = File.expand_path("..", __dir__)
  FIXTURE_LIB = File.join(ROOT, "fixture", "minitest_calc", "lib", "pricing.rb")
  OUT_PATH = File.join(__dir__, "out", "micro.json")
  ROUNDS = 5

  # One measured operation. The block must do the work, verify that the work
  # actually happened, and return the elapsed seconds (the clock is stopped
  # before the assertion so verification does not inflate the number).
  class Case
    attr_reader :id, :warmup, :per_round, :description

    def initialize(id:, warmup:, per_round:, description:, &body)
      @id = id
      @warmup = warmup
      @per_round = per_round
      @description = description
      @body = body
    end

    def run_once = @body.call
  end

  module_function

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def median(sorted)
    n = sorted.length
    return nil if n.zero?

    n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  end

  # Nearest-rank percentile: the smallest sample such that at least p of the
  # samples are <= it. Stable and easy to explain in a report.
  def percentile(sorted, fraction)
    return nil if sorted.empty?

    rank = (fraction * sorted.length).ceil
    rank = 1 if rank < 1
    rank = sorted.length if rank > sorted.length
    sorted[rank - 1]
  end

  def load_average
    File.read("/proc/loadavg").split.first(3).join(" ")
  rescue StandardError
    "n/a"
  end

  def grouped(number)
    whole, fraction = format("%.1f", number).split(".")
    whole = whole.reverse.scan(/\d{1,3}/).join(",").reverse
    fraction ? "#{whole}.#{fraction}" : whole
  end

  def human_ns(ns)
    return "#{grouped(ns / 1_000)} us" if ns >= 1_000 && ns < 1_000_000
    return "#{grouped(ns / 1_000_000)} ms" if ns >= 1_000_000

    "#{grouped(ns)} ns"
  end

  # A valid, exactly 500-line Ruby file: module + class + 165 methods + closing
  # lines. Parsed once as a sanity check before any timing.
  def generated_500_line_source
    lines = ["# frozen_string_literal: true", "module Bench500", "  class Generated"]
    index = 0
    while lines.length < 497
      lines << "    def method_#{index}(a, b)"
      lines << "      a + b + #{index}"
      lines << "    end"
      index += 1
    end
    lines << "  end"
    lines << "end"
    raise "generated #{lines.length} lines, expected 500" unless lines.length == 500

    "#{lines.join("\n")}\n"
  end

  def write_small_class(path, name)
    File.write(path, <<~RUBY)
      class #{name}
        def plus_one(value)
          value + 1
        end

        def times_two(value)
          value * 2
        end
      end
    RUBY
  end

  def build_cases(tmpdir)
    fixture_source = File.read(FIXTURE_LIB)
    raise "fixture lib is empty: #{FIXTURE_LIB}" if fixture_source.empty?

    generated_source = generated_500_line_source
    generated_parse = Prism.parse(generated_source)
    unless generated_parse.errors.empty?
      raise "generated 500-line source does not parse: #{generated_parse.errors.inspect}"
    end

    coverage_target = File.join(tmpdir, "bench_coverage_target.rb")
    write_small_class(coverage_target, "BenchCoverageTarget")
    load_target = File.join(tmpdir, "bench_load_target.rb")
    write_small_class(load_target, "BenchLoadTarget")

    io_data = "x" * 2048
    io_path = File.join(tmpdir, "bench_2kb.bin")
    File.binwrite(io_path, io_data)
    raise "2KB fixture is #{File.size(io_path)} bytes" unless File.size(io_path) == 2048

    raise "ruby executable missing: #{RbConfig.ruby}" unless File.executable?(RbConfig.ruby)

    cases = []

    cases << Case.new(
      id: "fork_wait", warmup: 100, per_round: 400,
      description: "fork a child that exit!(0)s, then wait2 for it"
    ) do
      t0 = clock
      pid = fork { exit!(0) }
      _, status = Process.wait2(pid)
      elapsed = clock - t0
      unless status.exitstatus == 0
        raise "fork child did not exit 0: #{status.inspect}"
      end
      elapsed
    end

    cases << Case.new(
      id: "spawn_ruby_empty", warmup: 5, per_round: 30,
      description: "spawn a fresh `ruby -e ''` process and wait for it"
    ) do
      t0 = clock
      pid = Process.spawn(RbConfig.ruby, "-e", "", out: File::NULL, err: File::NULL)
      _, status = Process.wait2(pid)
      elapsed = clock - t0
      raise "spawned ruby did not succeed: #{status.inspect}" unless status.success?
      raise "waited on the wrong child: #{status.pid} != #{pid}" unless status.pid == pid
      elapsed
    end

    cases << Case.new(
      id: "prism_parse_fixture_lib", warmup: 200, per_round: 1500,
      description: "Prism.parse fixture/minitest_calc/lib/pricing.rb (#{fixture_source.lines.length} lines)"
    ) do
      t0 = clock
      parsed = Prism.parse(fixture_source)
      elapsed = clock - t0
      raise "prism reported errors for the fixture lib: #{parsed.errors.inspect}" unless parsed.errors.empty?
      elapsed
    end

    cases << Case.new(
      id: "prism_parse_generated_500", warmup: 50, per_round: 400,
      description: "Prism.parse a generated 500-line Ruby file"
    ) do
      t0 = clock
      parsed = Prism.parse(generated_source)
      elapsed = clock - t0
      raise "prism reported errors for the generated 500-line file: #{parsed.errors.inspect}" unless parsed.errors.empty?
      elapsed
    end

    cases << Case.new(
      id: "coverage_start_peek_result_load", warmup: 50, per_round: 300,
      description: "Coverage.start + load small file + peek_result + result"
    ) do
      t0 = clock
      Coverage.start
      peek = nil
      result = nil
      begin
        load coverage_target
        peek = Coverage.peek_result
      ensure
        result = Coverage.result
      end
      elapsed = clock - t0
      unless peek.key?(coverage_target) && result.key?(coverage_target)
        raise "coverage did not record #{coverage_target}"
      end
      hits = result[coverage_target]
      hits = hits["lines"] if hits.is_a?(Hash)
      unless hits&.any? { |hits_on_line| hits_on_line && hits_on_line.positive? }
        raise "coverage recorded no line hits for #{coverage_target}"
      end
      raise "coverage still running after Coverage.result" if Coverage.running?
      elapsed
    end

    cases << Case.new(
      id: "file_write_2kb", warmup: 200, per_round: 2000,
      description: "File.write 2048 bytes to a warm temp path"
    ) do
      t0 = clock
      written = File.write(io_path, io_data, mode: "wb")
      elapsed = clock - t0
      raise "File.write wrote #{written} bytes, expected 2048" unless written == 2048
      elapsed
    end

    cases << Case.new(
      id: "file_read_2kb", warmup: 200, per_round: 2000,
      description: "File.read 2048 bytes from a warm temp path"
    ) do
      t0 = clock
      content = File.read(io_path, mode: "rb")
      elapsed = clock - t0
      raise "File.read returned #{content.bytesize} bytes, expected 2048" unless content.bytesize == 2048
      elapsed
    end

    cases << Case.new(
      id: "load_small_file", warmup: 200, per_round: 1000,
      description: "`load` a small file defining one class with two methods"
    ) do
      t0 = clock
      loaded = load(load_target)
      elapsed = clock - t0
      raise "load did not return true" unless loaded
      elapsed
    end

    cases
  end

  def warmup!(cases)
    cases.each do |kase|
      kase.warmup.times { kase.run_once }
    end
  end

  def measure!(cases)
    samples = Hash.new { |hash, key| hash[key] = [] }
    round_medians = Hash.new { |hash, key| hash[key] = [] }

    ROUNDS.times do |round|
      # Rotate which case runs first each round so a host spike does not always
      # hit the same measurement.
      cases.rotate(round).each do |kase|
        batch = Array.new(kase.per_round) { kase.run_once }
        samples[kase.id].concat(batch)
        round_medians[kase.id] << median(batch.sort)
      end
    end

    [samples, round_medians]
  end

  def rows_for(cases, samples)
    cases.map do |kase|
      ns = samples[kase.id].map { |seconds| seconds * 1_000_000_000.0 }.sort
      {
        "id" => kase.id,
        "n" => ns.length,
        "unit" => "op",
        "median_ns" => median(ns),
        "p95_ns" => percentile(ns, 0.95),
        "min_ns" => ns.first,
        "max_ns" => ns.last,
        "warmup" => kase.warmup
      }
    end
  end

  def report(cases, rows, round_medians)
    puts "ruby-mutation micro: ruby #{RUBY_VERSION}, #{Etc.nprocessors} cpus, load #{load_average} (1/5/15m)"
    puts "wheel: #{ROUNDS} interleaved rounds, per-case warmup excluded from n, CLOCK_MONOTONIC, ns per op"
    puts

    header = format("%-34s %8s %17s %17s %17s %17s %5s",
                    "case", "n", "median(ns/op)", "p95(ns/op)",
                    "min(ns/op)", "max(ns/op)", "unit")
    puts header
    puts "-" * header.length
    rows.each do |row|
      puts format("%-34s %8d %17s %17s %17s %17s %5s",
                  row["id"], row["n"],
                  grouped(row["median_ns"]), grouped(row["p95_ns"]),
                  grouped(row["min_ns"]), grouped(row["max_ns"]), row["unit"])
    end
    puts

    puts "humanized medians:"
    rows.each do |row|
      puts format("  %-34s %10s", row["id"], human_ns(row["median_ns"]))
    end
    puts

    drifts = cases.to_h do |kase|
      medians = round_medians[kase.id].compact.map { |seconds| seconds * 1_000_000_000.0 }
      overall = rows.find { |row| row["id"] == kase.id }["median_ns"]
      drift = overall.positive? ? (medians.max - medians.min) / overall * 100.0 : 0.0
      [kase.id, drift]
    end
    worst_id, worst_drift = drifts.max_by { |_, value| value }
    worst_rounds = round_medians[worst_id].compact.map { |seconds| human_ns(seconds * 1_000_000_000.0) }
    puts format("round drift: worst is %s at %.1f%% (spread of the 5 round medians / overall median)",
                worst_id, worst_drift)
    puts "  #{worst_id} round medians: #{worst_rounds.join(", ")}"
    if worst_drift > 25.0
      puts "noise: >25% drift observed; medians are reported (not min or a single run) and cases were interleaved"
    end
    puts format("cases: %d, total measured operations: %d", rows.length, rows.sum { |row| row["n"] })
  end

  def main
    started_at = Time.now.utc.iso8601
    tmpdir = Dir.mktmpdir("ruby-mutation-micro-")
    begin
      cases = build_cases(tmpdir)
      warmup!(cases)
      samples, round_medians = measure!(cases)
      rows = rows_for(cases, samples)

      report(cases, rows, round_medians)

      FileUtils.mkdir_p(File.dirname(OUT_PATH))
      payload = {
        "name" => "micro",
        "started_at" => started_at,
        "ruby" => RUBY_VERSION,
        "cpu_count" => Etc.nprocessors,
        "cases" => rows
      }
      File.write(OUT_PATH, "#{JSON.pretty_generate(payload)}\n")
      puts
      puts "wrote #{OUT_PATH.sub("#{ROOT}/", "")}"
    ensure
      FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
    end
  end
end

Micro.main
