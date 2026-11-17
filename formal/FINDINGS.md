# Findings

Four behaviours the formal work exposed. All four are fixed. `formal/regressions.sh` asserts the
fixed behaviour and is part of `bin/formal`; a `REGRESSED` line means one came back.

Each entry keeps the measured observation, then the root cause, the fix, and the behaviour now.
The before and after blocks are excerpts from the commands shown.

## 1. `--diff` filtered on the node's first line, but mutants are reported at their own line

**Observation.** `lib/mutation/analyzer.rb:71` kept a candidate when the diff covered
`node.location.start_line`. `lib/mutation/analyzer.rb:104` reported the mutant at
`replacement.line`, and `Sbr` sets that to the removed statement's line
(`lib/mutation/operators/sbr.rb:33`). For a statement block the node starts at its first
statement, so the filter and the report disagreed.

With `{"lib/m.rb": [[2, 2]]}` and `--per-line=99`, the pre-fix run listed six mutants, one of them
the `SBR` for line 3:

```
$ mutation list --diff=first.json --per-line=99 lib/m.rb
lib/m.rb  (6)
      3  sbr              SBR: a = x + 1 ...
      2  sbr              SBR: a = x + 1 ...
      2  aor              AOR: x + 1 -> x % 1
      ...
```

The opposite direction also occurred. With `{"lib/m.rb": [[3, 3]]}` the pre-fix run listed four
mutants, all `AOR`, and no `SBR` at all, because the block's first line was outside the diff:

```
$ mutation list --diff=second.json --per-line=99 lib/m.rb
lib/m.rb  (4)
      3  aor              AOR: a * 2 -> a % 2
      ...
```

**Root cause.** Two computations of the same line, one for the filter and one for the report.

**Fix.** `Analyzer#walk` derives `replacement.line || node.location.start_line` once, filters on
it, and `build_mutant` takes it as an argument. The filter and the report now read one value.

**Now.** The first command lists five mutants, all on line 2, and the second lists five, including
the line-3 `SBR`:

```
$ mutation list --diff=first.json --per-line=99 lib/m.rb
lib/m.rb  (5)
      2  sbr              SBR: a = x + 1 ...
      ...
$ mutation list --diff=second.json --per-line=99 lib/m.rb
lib/m.rb  (5)
      3  sbr              SBR: a = x + 1 ...
      ...
```

## 2. `mutation run --help` printed the option table and then ran a campaign

**Observation.** `lib/mutation/cli.rb:164` threw `:help` with no value, so `catch(:help)`
evaluated to `nil`. `lib/mutation/cli.rb:171` compared `caught == :help`, which is never true, so
`parse` returned the options hash and `run_command` continued.

```
$ mutation run --help
usage: mutation <run|list|doctor> [paths] [options]
        --adapter=NAME               minitest or rspec
        ...
  mutation score    0.0%  (killed / killed+survived+timeout)
```

**Root cause.** A `throw` value and a `catch` comparison that never met.

**Fix.** `throw(:help, :help)`. `parse` now returns `nil`, and every command returns `EXIT_OK`
after printing the table.

**Now.** The same command prints the table and stops. `list --help` lists nothing, and
`run --help` reads no source, so no report line appears.

## 3. The terminal rounded the score to one decimal, the `--min-score` gate did not

**Observation.** `lib/mutation/report.rb:67` printed `score * 100` with `%5.1f`, and
`lib/mutation/cli.rb:88` compared the unrounded `report.score * 100`. 3,999 killed and 1,001
survived is 79.98%, and the pre-fix run both printed `80.0%` and exited 1:

```
$ ruby -e '... Report.new(3999 killed, 1001 survived) ...'
status_lines.include?("80.0%")  #=> true
(score * 100) < 80              #=> true
```

**Root cause.** Two representations of one number. Any fixed display precision can disagree with
an exact comparison.

**Fix.** `Report#score_pct` rounds once, the terminal prints it, and the CLI compares it. The
help text says "exit 1 when the reported score is below this", which is now exactly what happens.

**Now.** The same run prints `80.0%` and the gate compares that value:

```
status_lines.include?("80.0%")  #=> true
score_pct < 80                  #=> false
```

A run whose reported score is 79.9 exits 1.

## 4. The cache wrote a format version and never read it

**Observation.** `lib/mutation/cache.rb:24` defined `FORMAT_VERSION`, `:106` wrote `"version"`,
and `:127` read only the `entries` object. A file with version 99 loaded as if it were current:

```
$ ruby -e 'Cache.new(file_with_version_99).size'  #=> 1
```

**Root cause.** The writer had a format version and the reader had no counterpart.

**Fix.** `load_entries` returns an empty cache unless the file's `version` is `FORMAT_VERSION`.
A version-less file is treated the same way, since `nil.to_i` is not 1.

**Now.** A file with version 99 is ignored and a file with version 1 loads:

```
$ ruby -e 'Cache.new(file_with_version_99).size'  #=> 0
```

`formal/regressions.sh` checks both, and `test/core/cache_test.rb` covers them.
