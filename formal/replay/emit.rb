# frozen_string_literal: true

# Deterministic facts for the formal replay.
#
# Writes formal/out/replay.tsv (splice, score and kill-matrix records for `lake exe replay`) and
# formal/out/mutants.tsv (the mutant list, for `formal/replay/check.rb`). The analysis runs twice
# and the script refuses to emit anything unless both runs agree.

require "digest"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sabaku"

ROOT = File.expand_path("../..", __dir__)
OUT = File.join(ROOT, "formal", "out")

SOURCES = [
  "fixture/minitest_calc/lib/pricing.rb",
  "fixture/inventory/lib/inventory.rb",
  "formal/replay/corpus/kitchen_sink.rb"
].freeze

CONFIG = Sabaku::Config.default(
  paths: SOURCES,
  operators: Sabaku::Operator::Registry.ids,
  per_line: 2
)

FakeResult = Struct.new(:status, :mutant)
FakeMutant = Struct.new(:id)

def bytes(text) = text.bytes.join(",")

# Small kill graphs with equal rows, empty rows and incomplete rows, and the verdict table
# `Sabaku::KillMatrix` draws from each. Tests are named so that their sorted order is their index,
# which is how Lean names them. Each test sits in a test class ("G1#T3"); classes are contiguous
# runs of ids, as sorted minitest ids are.
def matrix_records(count)
  random = Random.new(7)
  Array.new(count) do
    groups = [0]
    (random.rand(1..6) - 1).times { groups << groups.last + (random.rand < 0.4 ? 1 : 0) }
    tests = groups.each_with_index.map { |group, index| "G#{group}#T#{index}" }
    rows = Array.new(random.rand(0..8)) do
      tested = tests.select { random.rand < 0.7 }
      tested = [tests.sample(random: random)] if tested.empty?
      # Every test that ran it killed it: a broad row, the kind a lookup over a constant table makes.
      [tested, random.rand < 0.3 ? tested : tested.select { random.rand < 0.4 }]
    end
    rows << rows.first if rows.any? && random.rand < 0.4
    incomplete = Array.new(random.rand(0..2)) { tests.select { random.rand < 0.5 } }.reject(&:empty?)

    results = rows.each_with_index.map do |(tested, killers), index|
      status = killers.empty? ? :survived : :killed
      Sabaku::Result.new(mutant: FakeMutant.new("m#{index}"), status: status, failed_test: killers.first,
                         kills: Sabaku::Kills.new(tested: tested, killers: killers))
    end
    selected = {}
    incomplete.each_with_index do |tested, index|
      id = "i#{index}"
      selected[id] = tested
      results << Sabaku::Result.new(mutant: FakeMutant.new(id), status: :killed, failed_test: tested.first)
    end
    matrix = Sabaku::KillMatrix.from(results, universe: tests, selected: selected)

    index = ->(list) { list.map { |test| tests.index(test) }.join(",") }
    want = matrix.verdicts.map do |verdict|
      [verdict.kind, verdict.by ? tests.index(verdict.by) : "-", verdict.unique, verdict.tier].join(",")
    end
    ["matrix", tests.size, groups.join(","),
     rows.map { |tested, killers| "#{index.(tested)}/#{index.(killers)}" }.join(";"),
     incomplete.map { |tested| index.(tested) }.join(";"),
     want.join(";")].join("\t")
  end
end

def fake(status) = FakeResult.new(status, nil)

def analyze
  sources = SOURCES.map { |path| Sabaku::Source.new(path, File.read(File.join(ROOT, path))) }
  [sources, Sabaku::Analyzer.new(sources, CONFIG).mutants]
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
        report = Sabaku::Report.new(results, CONFIG)
        expected = (report.score_pct * 10).round
        out.puts ["score", killed, survived, timeout, uncovered, error, expected].join("\t")
      end
    end
  end

  matrix_records(200).each { |record| out.puts record }
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
