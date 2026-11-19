# frozen_string_literal: true

# Deterministic facts for the formal replay.
#
# Writes formal/out/replay.tsv (splice and score records for `lake exe replay`) and
# formal/out/mutants.tsv (the mutant list, for `formal/replay/check.rb`). The analysis runs twice
# and the script refuses to emit anything unless both runs agree.

require "digest"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "mutation"

ROOT = File.expand_path("../..", __dir__)
OUT = File.join(ROOT, "formal", "out")

SOURCES = [
  "fixture/minitest_calc/lib/pricing.rb",
  "fixture/inventory/lib/inventory.rb",
  "formal/replay/corpus/kitchen_sink.rb"
].freeze

CONFIG = Mutation::Config.default(
  paths: SOURCES,
  operators: Mutation::Operator::Registry.ids,
  per_line: 2
)

FakeResult = Struct.new(:status, :mutant)

def bytes(text) = text.bytes.join(",")

def fake(status) = FakeResult.new(status, nil)

def analyze
  sources = SOURCES.map { |path| Mutation::Source.new(path, File.read(File.join(ROOT, path))) }
  [sources, Mutation::Analyzer.new(sources, CONFIG).mutants]
end

sources, mutants = analyze
_, again = analyze
if mutants.map(&:to_h) != again.map(&:to_h)
  warn "emit: two analyses disagreed; the campaign is not deterministic"
  exit 1
end

texts = sources.to_h { |source| [source.rel_path, source.text] }

FileUtils.mkdir_p(OUT)
File.open(File.join(OUT, "replay.tsv"), "w") do |out|
  mutants.each do |mutant|
    text = texts.fetch(mutant.path)
    out.puts ["splice", mutant.start_offset, mutant.end_offset, bytes(text),
              bytes(mutant.replacement), bytes(mutant.splice(text))].join("\t")
  end

  [[0, 0, 0], [1, 1, 1], [3, 0, 0], [0, 3, 0], [2, 1, 2], [3999, 1001, 0],
   [7, 0, 2], [1, 0, 0], [0, 0, 1]].each do |killed, survived, timeout|
    [0, 1].each do |uncovered|
      [0, 1].each do |error|
        results = Array.new(killed) { fake(:killed) } +
                  Array.new(survived) { fake(:survived) } +
                  Array.new(timeout) { fake(:timeout) } +
                  Array.new(uncovered) { fake(:uncovered) } +
                  Array.new(error) { fake(:error) }
        report = Mutation::Report.new(results, CONFIG)
        expected = (report.score_pct * 10).round
        out.puts ["score", killed, survived, timeout, uncovered, error, expected].join("\t")
      end
    end
  end
end

File.open(File.join(OUT, "mutants.tsv"), "w") do |out|
  sources.each do |source|
    out.puts ["source", source.rel_path, bytes(source.text)].join("\t")
  end
  mutants.each do |mutant|
    out.puts ["mutant", mutant.path, mutant.line, mutant.column, mutant.operator,
              mutant.node_kind, mutant.start_offset, mutant.end_offset, mutant.scope,
              mutant.ast_path, mutant.id, bytes(mutant.replacement)].join("\t")
  end
end

puts "emit: #{mutants.length} mutants, #{mutants.map(&:operator).uniq.sort.join(", ")}"
