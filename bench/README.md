# bench: execution-time harness

This directory measures the Ruby mutation engine, never the other way around. It shipped
before the engine existed and keeps working when the engine is absent, broken, or mid-landing.

Project goal (restated): a mutation testing library for Ruby that runs minitest and rspec
suites, following Petrovic & Ivankovic, "State of Mutation Testing at Google" — diff-based
mutation, arid-node suppression, one mutant per line, and coverage-based test selection. These
scripts answer "what does a campaign cost?" before and after the engine exists.

All commands run from the repo root. There is no Ruby on the host: `./bin/rt` starts the dev
container and mounts this repo at `/app`.

```sh
./bin/rt ruby bench/micro.rb                  # primitive costs -> bench/out/micro.json
./bin/rt ruby bench/campaign.rb               # cost model     -> bench/out/campaign.json
./bin/rt ruby bench/report.rb                 # markdown table + baseline comparison
./bin/rt ruby bench/report.rb --update        # snapshot current medians -> bench/baseline.json
./bin/rt ruby bench/report.rb --threshold=40  # allow 40% before exiting 1
```

`bench/out/` is gitignored and created on demand. Both scripts write the JSON schema frozen in
`docs/DESIGN.md` ("Harness contract"). `bench/report.rb` reads every `bench/out/*.json`.

## What each number means

### micro.rb

One operation per sample, timed with `Process::CLOCK_MONOTONIC`, after warmup. `n` excludes
warmup. Values are nanoseconds per operation (`unit: "op"`); median is the p50.

| case id | timed region | work-happened check |
| --- | --- | --- |
| `fork_wait` | `fork` + `wait2` of a child that calls `exit!(0)` | child status is 0 |
| `spawn_ruby_empty` | `spawn ruby -e ''` + `wait2` | child status 0 and status belongs to that pid |
| `prism_parse_fixture_lib` | `Prism.parse` of `fixture/minitest_calc/lib/pricing.rb` (source read once, outside) | parse has no errors |
| `prism_parse_generated_500` | `Prism.parse` of an in-memory, exactly 500-line generated Ruby file | generated file parses, 500 lines |
| `coverage_start_peek_result_load` | `Coverage.start` + `load` one small file + `peek_result` + `result` | file key present and at least one line hit |
| `file_write_2kb` | `File.write` 2048 bytes to a warm temp path | return value is 2048 |
| `file_read_2kb` | `File.read` 2048 bytes from a warm temp path | bytesize is 2048 |
| `load_small_file` | `load` a small file defining one class with two methods | `load` returns true, both methods exist |

Excluded from every timed region: warmup, assertions/verification, temp-file setup and cleanup,
JSON writing, and container startup. The fixture file is read once before timing; file I/O uses a
warm page cache and a warm temp path, so these are CPU/syscall costs, not cold-disk costs.

### campaign.rb

Synthetic mutant candidates are generated cheaply (default 20: ids plus source line labels).
No source is modified; the candidates only scale the per-mutant cost. Modes:

- `reference_process_full` — for each candidate, one fresh `ruby` process runs the whole
  fixture suite (`ruby -Ilib -Itest test/pricing_test.rb`). This is the naive
  re-run-everything baseline; the timed region includes interpreter boot.
- `reference_fork_full` — the fixture's tests are loaded once in the parent, then each
  candidate forks; the child runs the whole suite with `Minitest.run`, flushes, and `exit!`s.
  The timed region is fork + suite + wait. This is the fork-reuse baseline and a lower bound
  for the real fork runner (it does not apply a mutation or reload a file; `micro.rb` prices
  that separately at ~10 us for a small file).
- `engine` — best effort. If `bin/mutation` exists and passes `--version`, or
  `ruby -Ilib -e 'require "mutation"'` succeeds, the campaign runs `bin/mutation` on the
  fixture with `--report=json` (the real CLI flag; `--json` is retried as a forward-compat
  fallback), parses the report, and records `mutants, killed, survived, timeout, error,
  uncovered, score, wall_s, mutant_p50_ms, mutant_p95_ms`. Engine runs set
  `RUBY_MUTATION_NO_CACHE=1`: the engine's cache hits skip execution and report duration 0, so a
  warm cache would time JSON parsing instead of mutant execution. It also deletes
  `fixture/minitest_calc/.mutation-cache.json` before every engine repetition so a stale cache
  file cannot mask a code change. If the engine is absent it records `"engine": "absent"` and
  continues. Per-mutant p50/p95 use `Result#duration` for killed/survived/timeout only;
  `:uncovered` never ran and `:error` is an apply/boot failure.

The campaign is already inside the container, so it invokes `bin/mutation` directly instead of
nesting `./bin/rt` (there is no Docker CLI inside the container). Nested Docker would only add
the ~0.4 s wrapper startup, which is excluded anyway.

Two different per-mutant quantities are reported and must not be compared with each other:

- `per_mutant_wall_ms = wall_s * 1000 / mutants` — end-to-end cost per mutant for that mode. This
  is the planning number. For the engine it includes the one-time boot/preload.
- `p50_metric` says what the p50 column measures. Reference modes use `whole_leg_wall` (the
  process/fork wall for one mutant). The engine uses `child_duration` (`Result#duration`, the
  child's own time), which excludes boot/preload. `child_p50_ms`/`child_p95_ms` alias the engine
  columns; `mutant_p50_ms` is kept for the DESIGN schema.

Each mode runs `--reps` times (default 5), alternating order, with each repetition's wall time
recorded. The JSON reports the median wall time, min/max range, per-mutant p50/p95 across all
legs, and the range of per-repetition p50s. While the engine is landing, repetitions that are not
fully healthy (nonzero `:error`, or no positive timed durations) are kept in the JSON but excluded
from the engine's timing/counts when at least one healthy repetition exists; `attempted_reps` and
`healthy_reps` make that visible. The top-level `wall_s`/`mutant_p50_ms` come from the engine when
it produced a positive timed cost, otherwise from the fastest reference path; the `wall_s_basis`
and `p50_metric` fields say which. Every reference child is verified to have run exactly the
fixture's 6 tests with 0 failures and 0 errors; a failed verification retries once and then aborts
the campaign (a green campaign never contains work that did not happen).

### report.rb

Prints a compact markdown table (`case`, `n`, `median`, `p95`, `unit`) for every micro file and a
per-mode campaign table with `wall/mutant` and an explicit `p50 metric` column. When
`bench/baseline.json` exists it adds the baseline median and ratio for each case and exits 1 if any
median is worse than baseline by more than `--threshold` (default 25%). `--update` writes the
current medians; it only snapshots cases, not campaign modes. Exit codes: 0 pass or no baseline,
1 regression, 2 bad baseline/options.

## Measurement policy

- **Warmup before measuring.** Warmup iterations are discarded from `n`; for fork/spawn they are
  also the proof that the operation is possible at all.
- **Enough samples and repeats.** Micro uses 5 interleaved rounds (case order rotates each
  round) with 150-10,000 samples per case. Campaign uses 5 repetitions per mode in alternating
  order, and reports the median plus min/max range, never a single run as a verdict.
- **Interleaving beats pinning.** Other agents and containers share this host. Rotating case
  order and alternating modes gives every measurement the same chance of seeing a spike.
- **Medians, not minima.** Fork is bimodal on this host (~0.7 ms when the child is scheduled
  promptly, ~2.2 ms otherwise), so `fork_wait` shows large round-to-round drift and a wide
  min/max. The p50 over thousands of samples is the reported number; the micro output prints
  the five round medians for the worst case so the noise is visible rather than hidden.
- **What is excluded.** Container startup (`docker run`, ~0.4 s) is outside every measurement:
  it is harness cost, not engine cost. Setup, verification, log parsing, candidate generation,
  and JSON writing are also outside. What a mode models (fresh interpreter boot, fork, suite
  execution) is inside that mode's timed region.
- **Answering "did it happen?"** Every timed operation checks its own result: child exit status,
  parse errors, coverage hits, bytes written/read, `load` return value and defined methods, and
  a full minitest summary per reference leg. A passing report means the work was executed, not
  just requested.

Run the scripts on a quiet host for baseline comparisons. `bench/baseline.json` is a snapshot,
not a universal constant; regenerate it with `--update` when the host class or Ruby image changes.
