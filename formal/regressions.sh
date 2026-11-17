#!/usr/bin/env bash
# Regression probes for the four findings in formal/FINDINGS.md.
#
# Each probe asserts the fixed behaviour. A REGRESSED line means the defect is back.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work=formal/out/regressions
rm -rf "$work"
mkdir -p "$work/diffprobe/lib" "$work/helpprobe/lib"
fail=0

report() {
  local name="$1" status="$2" detail="${3:-}"
  echo "regression $name: $status${detail:+ ($detail)}"
}

# 1. --diff must filter on the line the mutant is reported at, including statement blocks.
cat > "$work/diffprobe/lib/m.rb" <<'RUBY'
def total(x)
  a = x + 1
  b = a * 2
  a + b
end
RUBY
printf '{"lib/m.rb": [[2, 2]]}\n' > "$work/diffprobe/first.json"
printf '{"lib/m.rb": [[3, 3]]}\n' > "$work/diffprobe/second.json"
first=$(./bin/rt sh -c "cd $work/diffprobe && ruby /app/bin/mutation list --diff=first.json --per-line=99 lib/m.rb" 2>&1)
second=$(./bin/rt sh -c "cd $work/diffprobe && ruby /app/bin/mutation list --diff=second.json --per-line=99 lib/m.rb" 2>&1)
if grep -Eq '^[[:space:]]+2[[:space:]]+sbr' <<<"$first" &&
  ! grep -Eq '^[[:space:]]+3[[:space:]]+sbr' <<<"$first" &&
  grep -Eq '^[[:space:]]+3[[:space:]]+sbr' <<<"$second"; then
  report diff_filters_on_the_reported_line FIXED
else
  report diff_filters_on_the_reported_line REGRESSED
  fail=1
fi

# 2. --help must print the table and return without touching the project.
list_help=$(./bin/rt sh -c "cd $work/helpprobe && ruby /app/bin/mutation list --help" 2>&1)
run_help=$(./bin/rt sh -c "cd $work/helpprobe && ruby /app/bin/mutation run --limit=0 --help" 2>&1)
if grep -q "usage: mutation" <<<"$list_help" &&
  ! grep -Eq '^[0-9]+ mutants$' <<<"$list_help" &&
  ! grep -q "no mutants to run" <<<"$run_help"; then
  report help_returns_without_running FIXED
else
  report help_returns_without_running REGRESSED
  fail=1
fi

# 3. The percentage the terminal prints is the percentage --min-score compares.
out=$(./bin/rt ruby -e '
$LOAD_PATH.unshift("/app/lib")
require "mutation"
Row = Struct.new(:status, :mutant)
results = Array.new(3999) { Row.new(:killed, nil) } + Array.new(1001) { Row.new(:survived, nil) }
doc = Mutation::Report.new(results, Mutation::Config.default)
puts doc.status_lines.lines.find { |l| l.include?("mutation score") }.strip
puts "below=#{doc.score_pct < 80}"
' 2>&1)
if grep -q "80.0%" <<<"$out" && grep -q "below=false" <<<"$out"; then
  report displayed_score_is_the_gated_value FIXED "$(grep 'mutation score' <<<"$out")"
else
  report displayed_score_is_the_gated_value REGRESSED
  fail=1
fi

# 4. The cache must ignore a file whose format version is not the current one.
out=$(./bin/rt ruby -e '
$LOAD_PATH.unshift("/app/lib")
require "mutation"
require "json"
require "tmpdir"
Dir.mktmpdir do |dir|
  path = File.join(dir, ".mutation-cache.json")
  entry = { "entries" => { "k" => { "status" => "killed" } } }
  File.write(path, JSON.generate({ "version" => 99 }.merge(entry)))
  stale = Mutation::Cache.new(path)
  File.write(path, JSON.generate({ "version" => Mutation::Cache::FORMAT_VERSION }.merge(entry)))
  fresh = Mutation::Cache.new(path)
  puts "stale=#{stale.size} fresh=#{fresh.size}"
end
' 2>&1)
if grep -q "stale=0 fresh=1" <<<"$out"; then
  report cache_version_is_checked FIXED
else
  report cache_version_is_checked REGRESSED "$out"
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo "regressions: a fixed finding came back" >&2
  exit 1
fi
