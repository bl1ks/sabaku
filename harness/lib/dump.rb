# frozen_string_literal: true

# Human-readable dump of a JSON campaign report, for triaging a red practical case.
#   ruby bin/sabaku run lib --report=json | ruby harness/lib/dump.rb
require "json"

text = $stdin.read
line = text.lines.reverse.find { |candidate| candidate.start_with?("{") }
abort "no JSON report on stdin" if line.nil?

payload = JSON.parse(line)
payload.fetch("results").each do |result|
  mutant = result.fetch("mutant")
  puts format("%s:%d  %-10s %-14s %7.2fs  %s", mutant["path"], mutant["line"], result["status"],
              result["reason"].inspect, result["duration"], result["message"].to_s[0, 70])
end
puts payload.slice("mutants", "killed", "survived", "timeout", "uncovered", "error", "skipped",
                   "score").inspect
