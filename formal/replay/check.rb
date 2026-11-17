# frozen_string_literal: true

# Contract checks on the mutant list `formal/replay/emit.rb` produced.
#
# The proofs in formal/lean say what a correct list looks like: a stable order, one id per
# (path, offsets, replacement), at most `per_line` mutants per line, and a replacement that
# differs from the bytes it replaces. This script checks the real analyzer's output against them.

require "digest"

PER_LINE = 2
OPERATORS = %i[aor ror lcr sbr uoi bool str literal selector call cond assign].freeze

path = ARGV[0] || File.expand_path("../out/mutants.tsv", __dir__)
abort "check: missing #{path}" unless File.file?(path)

def bytes(text) = text.split(",").reject(&:empty?).map(&:to_i).pack("C*")

texts = {}
mutants = []

File.foreach(path, chomp: true) do |line|
  fields = line.split("\t")
  case fields[0]
  when "source"
    texts[fields[1]] = bytes(fields[2])
  when "mutant"
    _, file, number, column, operator, kind, start, stop, id, replacement = fields
    mutants << { path: file, line: number.to_i, column: column.to_i, operator: operator.to_sym,
                 kind: kind, start: start.to_i, stop: stop.to_i, id: id,
                 replacement: bytes(replacement) }
  end
end

failures = []

def line_of(text, offset)
  return 1 if offset < 0

  starts = [0]
  text.each_byte.with_index { |byte, index| starts << index + 1 if byte == 10 }
  starts.bsearch_index { |start| start > offset } || starts.size
end

mutants.each do |mutant|
  text = texts.fetch(mutant[:path]) { failures << "#{mutant[:id]}: unknown source #{mutant[:path]}" }
  next unless text

  slice = text.byteslice(mutant[:start], mutant[:stop] - mutant[:start])
  if slice.nil?
    failures << "#{mutant[:id]}: span #{mutant[:start]}..#{mutant[:stop]} is outside the file"
    next
  end
  failures << "#{mutant[:id]}: replacement equals the bytes it replaces" if slice == mutant[:replacement]

  first = line_of(text, mutant[:start])
  last = line_of(text, mutant[:stop] - 1)
  unless mutant[:line].between?(first, last)
    failures << "#{mutant[:id]}: reported line #{mutant[:line]} is outside #{first}..#{last}"
  end

  expected = Digest::SHA1.hexdigest(
    "#{mutant[:path]}\0#{mutant[:start]}\0#{mutant[:stop]}\0#{mutant[:replacement]}"
  )[0, 16]
  failures << "#{mutant[:id]}: id does not match its fields (expected #{expected})" if expected != mutant[:id]
end

if (duplicates = mutants.group_by { |m| m[:id] }.select { |_, list| list.size > 1 }).any?
  failures << "duplicate ids: #{duplicates.keys.join(", ")}"
end

keys = mutants.map { |m| [m[:path], m[:start], m[:operator].to_s, m[:replacement]] }
keys.each_cons(2) do |before, after|
  next if (before <=> after) <= 0

  failures << "order: #{before.inspect} came before #{after.inspect}"
end
keys.each_cons(2) { |a, b| failures << "tie: #{a.inspect} appears twice" if a == b }

mutants.group_by { |m| [m[:path], m[:line]] }.each do |(file, line), list|
  next if list.size <= PER_LINE

  failures << "#{file}:#{line}: #{list.size} mutants, per_line is #{PER_LINE}"
end

seen = mutants.map { |m| m[:operator] }.uniq
missing = OPERATORS - seen
failures << "operators missing from the corpus: #{missing.join(", ")}" if missing.any?

if failures.any?
  failures.first(20).each { |failure| puts "check: FAIL #{failure}" }
  puts "check: #{failures.size} failures over #{mutants.size} mutants"
  exit 1
end

puts "check: #{mutants.size} mutants, #{seen.sort.join(", ")}; contract holds"
