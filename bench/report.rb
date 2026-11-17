#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads every bench/out/*.json, prints a compact markdown table of the micro
# cases, and (when bench/baseline.json exists) compares each case's median to the
# baseline. Exit code 1 means at least one case got slower than the baseline by
# more than the threshold (default 25%). Use --update to snapshot current medians.
#
# Runnable from the repo root as: ./bin/rt ruby bench/report.rb

require "json"
require "optparse"
require "time"

module BenchReport
  ROOT = File.expand_path("..", __dir__)
  OUT_DIR = File.join(__dir__, "out")
  BASELINE_PATH = File.join(__dir__, "baseline.json")

  DEFAULT_THRESHOLD = 0.25

  module_function

  def grouped(number)
    whole, fraction = format("%.1f", number).split(".")
    whole = whole.reverse.scan(/\d{1,3}/).join(",").reverse
    fraction ? "#{whole}.#{fraction}" : whole
  end

  def fmt_ns(value)
    return "-" if value.nil?

    value = Float(value)
    value >= 1_000_000 ? grouped(value.round) : grouped(value)
  end

  def parse_threshold(raw)
    text = raw.to_s.strip
    percent = text.end_with?("%")
    value = Float(text.delete_suffix("%"))
    raise ArgumentError, "threshold must be >= 0" if value.negative?

    fraction = percent || value > 1.0 ? value / 100.0 : value
    fraction
  rescue ArgumentError => e
    raise OptionParser::InvalidArgument, e.message
  end

  def load_json(path)
    JSON.parse(File.read(path))
  end

  def collect
    files = Dir.glob(File.join(OUT_DIR, "*.json")).sort
    cases = []
    campaigns = []
    skipped = []

    files.each do |path|
      begin
        data = load_json(path)
      rescue StandardError => e
        skipped << "#{File.basename(path)}: #{e.class}: #{e.message}"
        next
      end

      name = data["name"] || File.basename(path, ".json")
      if data["cases"].is_a?(Array)
        data["cases"].each do |kase|
          next unless kase.is_a?(Hash) && kase["id"] && kase["median_ns"]

          cases << kase.merge("_file" => File.basename(path), "_bench" => name)
        end
      elsif data["modes"].is_a?(Array)
        campaigns << data.merge("_file" => File.basename(path))
      else
        skipped << "#{File.basename(path)}: no cases or modes array"
      end
    end

    [files, cases, campaigns, skipped]
  end

  def load_baseline
    return [nil, nil] unless File.file?(BASELINE_PATH)

    begin
      data = load_json(BASELINE_PATH)
    rescue StandardError => e
      warn "report: cannot read #{BASELINE_PATH}: #{e.class}: #{e.message}"
      exit 2
    end
    unless data["cases"].is_a?(Hash)
      warn "report: #{BASELINE_PATH} has no cases hash"
      exit 2
    end
    [data, data["cases"]]
  end

  def baseline_median(entry)
    return nil if entry.nil?

    value = entry.is_a?(Hash) ? entry["median_ns"] : entry
    value.nil? ? nil : Float(value)
  end

  def write_baseline(cases)
    if cases.empty?
      warn "report: no micro cases found under #{OUT_DIR}; nothing to snapshot"
      exit 2
    end

    by_id = {}
    cases.each do |kase|
      if by_id.key?(kase["id"])
        warn "report: duplicate case #{kase["id"]} across output files; keeping the later one"
      end
      by_id[kase["id"]] = {
        "median_ns" => kase["median_ns"],
        "n" => kase["n"],
        "unit" => kase["unit"],
        "file" => kase["_file"]
      }
    end

    payload = {
      "updated_at" => Time.now.utc.iso8601,
      "cases" => by_id
    }
    File.write(BASELINE_PATH, "#{JSON.pretty_generate(payload)}\n")
    puts "wrote benchmark baseline: #{BASELINE_PATH.sub("#{ROOT}/", "")} (#{by_id.length} cases)"
  end

  def print_case_table(cases, baseline_cases)
    ids = cases.map { |kase| kase["id"] }
    duplicates = ids.tally.select { |_, count| count > 1 }.keys

    if baseline_cases
      puts "| case | n | median (ns/op) | p95 (ns/op) | unit | baseline (ns/op) | ratio | status |"
      puts "| --- | ---: | ---: | ---: | --- | ---: | ---: | --- |"
    else
      puts "| case | n | median (ns/op) | p95 (ns/op) | unit |"
      puts "| --- | ---: | ---: | ---: | --- |"
    end

    cases.each do |kase|
      id = duplicates.include?(kase["id"]) ? "#{kase["id"]} (#{kase["_file"]})" : kase["id"]
      median = Float(kase["median_ns"])
      base = baseline_cases ? baseline_median(baseline_cases[kase["id"]]) : nil
      if baseline_cases
        ratio = base && base.positive? ? median / base : nil
        status = if base.nil?
                   "new"
                 elsif ratio > 1.0
                   "+#{(ratio - 1.0) * 100.0}%"
                 else
                   "#{(ratio - 1.0) * 100.0}%"
                 end
        puts "| #{id} | #{kase["n"]} | #{fmt_ns(median)} | #{fmt_ns(kase["p95_ns"])} | " \
             "#{kase["unit"]} | #{base ? fmt_ns(base) : "-"} | " \
             "#{ratio ? format("%.2fx", ratio) : "-"} | #{status} |"
      else
        puts "| #{id} | #{kase["n"]} | #{fmt_ns(median)} | #{fmt_ns(kase["p95_ns"])} | #{kase["unit"]} |"
      end
    end
  end

  def compare(cases, baseline_cases, threshold)
    results = []
    missing = baseline_cases.keys - cases.map { |kase| kase["id"] }
    new_cases = []

    cases.each do |kase|
      base = baseline_median(baseline_cases[kase["id"]])
      if base.nil?
        new_cases << kase["id"]
        next
      end
      next unless base.positive?

      median = Float(kase["median_ns"])
      ratio = median / base
      limit = base * (1.0 + threshold)
      results << {
        id: kase["id"],
        median: median,
        base: base,
        ratio: ratio,
        slow: median > limit
      }
    end

    slow = results.select { |result| result[:slow] }
    puts
    puts "threshold: #{format("%.1f", threshold * 100.0)}% slower than baseline is a regression"
    if results.empty?
      puts "compared cases: 0"
    else
      worst = results.max_by { |result| result[:ratio] }
      puts format("compared cases: %d, worst ratio: %.2fx (%s)",
                  results.length, worst[:ratio], worst[:id])
    end
    puts "new cases with no baseline (not compared): #{new_cases.join(", ")}" unless new_cases.empty?
    puts "baseline cases not measured this run: #{missing.join(", ")}" unless missing.empty?

    if slow.empty?
      puts "result: PASS"
    else
      puts "result: FAIL"
      slow.sort_by { |result| -result[:ratio] }.each do |result|
        puts format("  %s: %.2fx slower than baseline (%.1f ns -> %.1f ns)",
                    result[:id], result[:ratio], result[:base], result[:median])
      end
    end
    slow.empty?
  end

  def print_campaigns(campaigns)
    return if campaigns.empty?

    puts
    puts "## campaigns"
    campaigns.each do |campaign|
      engine = campaign["engine"] || "?"
      puts
      puts "### #{campaign["fixture"] || campaign["_file"]} (engine: #{engine}, file: #{campaign["_file"]})"
      if campaign["mutants"]
        puts format("engine run: %d mutants, killed=%d survived=%d timeout=%d error=%d uncovered=%d score=%.4f",
                    campaign["mutants"], campaign["killed"], campaign["survived"],
                    campaign["timeout"], campaign["error"], campaign["uncovered"],
                    campaign["score"])
      end
      if campaign["per_mutant_wall_ms"]
        metric = campaign["p50_metric"].to_s.tr("_", " ")
        puts format("basis: %s, %.1f ms/mutant end-to-end, p50 %.1f ms (%s)",
                    campaign["wall_s_basis"], campaign["per_mutant_wall_ms"],
                    campaign["mutant_p50_ms"], metric)
      end
      modes = campaign["modes"]
      unless modes.is_a?(Array) && !modes.empty?
        puts "no mode data"
        next
      end

      puts "| mode | wall median (s) | wall range (s) | wall/mutant (ms) | p50 metric | p50 (ms) | p95 (ms) | verified legs |"
      puts "| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |"
      modes.each do |mode|
        wall = mode["wall_s"]
        min = mode["wall_min_s"]
        max = mode["wall_max_s"]
        range = min && max ? format("%.2f..%.2f", min, max) : "-"
        mutants = mode["mutants"] || mode["mutants_per_rep"]
        per_mutant = mode["per_mutant_wall_ms"]
        per_mutant ||= wall && mutants ? wall * 1000.0 / mutants : nil
        metric = (mode["p50_metric"] || (mode["id"] == "engine" ? "child_duration" : "whole_leg_wall")).tr("_", " ")
        p50 = mode["mutant_p50_ms"]
        p95 = mode["mutant_p95_ms"]
        puts "| #{mode["id"]} | #{wall ? format("%.2f", wall) : "-"} | #{range} | " \
             "#{per_mutant ? format("%.1f", per_mutant) : "-"} | #{metric} | " \
             "#{p50 ? format("%.1f", p50) : "-"} | #{p95 ? format("%.1f", p95) : "-"} | " \
             "#{mode["verified_legs"] || "-"} |"
      end
    end
  end

  def main(argv)
    options = { threshold: DEFAULT_THRESHOLD, update: false }
    parser = OptionParser.new do |opts|
      opts.banner = "usage: ruby bench/report.rb [--threshold PCT] [--update]"
      opts.on("--threshold=PCT", "max allowed slowdown vs baseline (default 25%)") do |value|
        options[:threshold] = parse_threshold(value)
      end
      opts.on("--update", "write current medians to bench/baseline.json") do
        options[:update] = true
      end
      opts.on("-h", "--help", "this") do
        puts opts
        exit 0
      end
    end
    begin
      parser.parse!(argv)
    rescue OptionParser::ParseError => e
      warn "report: #{e.message}"
      return 2
    end

    files, cases, campaigns, skipped = collect
    if files.empty?
      puts "no JSON files under #{OUT_DIR.sub("#{ROOT}/", "")}; run micro/campaign first"
      return 0
    end

    if options[:update]
      write_baseline(cases)
      return 0
    end

    _, baseline_cases = load_baseline

    puts "# bench report"
    puts "source: #{files.map { |path| path.sub("#{ROOT}/", "") }.join(", ")}"
    puts "values: nanoseconds per op (lower is better); n excludes warmup"
    puts
    if cases.empty?
      puts "no micro cases found (campaign files are summarized below)"
    else
      print_case_table(cases, baseline_cases)
    end

    print_campaigns(campaigns)

    unless skipped.empty?
      puts
      puts "skipped files:"
      skipped.each { |line| puts "  #{line}" }
    end

    if baseline_cases.nil?
      puts
      puts "no bench/baseline.json; ratio comparison skipped (run with --update to snapshot)"
      return 0
    end
    return 0 if cases.empty?

    compare(cases, baseline_cases, options[:threshold]) ? 0 : 1
  end
end

exit BenchReport.main(ARGV)
