# Practical acceptance harness

The engine has unit tests, e2e fixtures and formal models. None of them answer the question a
stranger asks before trusting this tool on their repository: **is it practical?** This directory
holds projects the engine was not developed against, each with a pass/fail criterion written
before the engine was allowed to see the result.

`./bin/practical` runs every case and exits nonzero on the first red one. A case is one
directory under `cases/`, holding a `check.rb` (the assertions) and a `project/` (a real minitest
project the check copies to a scratch directory and mutates).

## What "practical" means here

Eight claims. Each case is the cheapest experiment that could falsify its claim.

| Case | Claim | Falsified by |
| --- | --- | --- |
| `grading` | The score is the number the report computes, and the survivor list names exactly the gaps the suite leaves. | A score that does not follow from the statuses, a survivor that is not where the code says it is, a killed mutant the suite does not notice. |
| `selection` | Coverage-guided selection never changes a verdict on a suite whose tests are independent. | One mutant whose status differs from the whole-suite oracle, or a `not_infected` survivor the oracle kills. |
| `stateful` | On a suite that shares state between tests, the run is reproducible and a kill is never invented. | Two runs disagree, or a mutant reported `killed` survives when every test runs. |
| `timeout` | A mutation that hangs costs the deadline and nothing more. | A hang that is reported `survived`, or a campaign that outlives `mutants × timeout`. |
| `determinism` | The same tree gives the same report, cold or warm, and a new test changes it. | Cold runs differ, the cache returns a stale verdict, or a new covering test leaves the survivor in place. |
| `hostile` | Messy source and unloadable mutants degrade to an honest `skipped`, never to a crash or a free pass. | A traceback, a skipped mutant counted in the score, or a mutant reported killed that never ran. |
| `ci` | A team can gate on the exit code, the score threshold and the diff allowlist. | Exit codes that disagree with the printed score, `--diff` leaking outside its allowlist, `--report=quiet` printing. |
| `scale` | A 2k-line project with 60 tests finishes inside a budget, and selection is worth several times its own cost. | Exceeding the budget, or a sample verdict that disagrees with the oracle. |

## The oracle

Correctness cases compare against the engine's own expensive path, `--no-coverage --no-weak`,
which runs every test for every mutant. That path is not trusted blindly; it is the semantic
definition the cheap path must reproduce. A comparison is only meaningful with these rules, and
every case follows them.

- Correctness cases run both sides with `--per-line=all --timeout=30` and no cache, so selection
  and the deadline cannot explain a difference. `scale` uses the default `--per-line=1` because it
  measures the path a user gets by default.
- Statuses are compared per mutant `id`, never per line, because one line can carry several
  mutants.
- A mutant the cheap path reports `uncovered` is excluded from the comparison. No test covers its
  line, so the whole-suite path is not measuring the same thing.
- Reasons are not compared. `not_infected` and `not_detected` both mean survived, and only the
  cheap path has the probe pass. What is compared is the status, plus one asymmetry: every
  `not_infected` survivor must also be a survivor on the expensive path. That is the only way the
  probe pass could turn a kill into a survivor.
- A suite is only used for this comparison when its tests are independent. `stateful` is the case
  that does share state, and it asserts reproducibility instead, because coverage selection is a
  heuristic: a test outside the selected set can still kill a mutant through leaked state. No
  engine can promise otherwise without running every test.

## Budgets

Each case declares a `budget` in `case.json`, in seconds. The runner kills the case's process
group at the deadline and marks it red. Budgets are generous (2-6x the expected runtime on a
20-core machine) so they catch hangs and quadratic blowups, not noise.

## First full run

2026-11-20. Eight of eight green. The run found two engine defects, both fixed in `lib/` before
the suite went green.

| Caught by | Defect | Fix |
| --- | --- | --- |
| `ci` | `--fail-fast` never stopped when the probe pass had already decided the first survivor, so the flag did nothing on exactly the suites the weak pass is good at. | The runner halts before the first fork and leaves the rest `skipped`. |
| `grading`, `selection` | An endless method (`def m = expr`) never reports a per-test hit: Ruby marks its line at definition time and a call does not increment it, so every mutant on that line was `uncovered` and silently dropped from the score. | `TestSelection#unattributable?` recognises the line and the runner runs every test for those mutants. |

`ci` caught its defect by going red. The attribution defect was reported as an engine finding
rather than a red case, because `grading` had been hardened against it before the fix: after the
fix its statuses moved from 135 killed / 12 uncovered to 144 killed / 3 uncovered while its
expected survivor set stayed exactly the same five mutants. That is the evidence the fixture was
written from the claim, not from the bug.

| Case | Wall (idle) | Assertions | What it measured |
| --- | --- | --- | --- |
| `grading` | 3.6s | 52 | 152 mutants, 144 killed, 3 uncovered, score 96.6%, survivors exactly the 3 planted coordinates |
| `selection` | 16.0s | 19 | 936 mutants, 744 comparable, 0 status differences, 4 `not_infected` survivors all survive on the oracle, 4.2x faster than the oracle |
| `stateful` | 2.0s | 18 | two cold runs identical, every kill reproduced by the all-tests run, 4 optimistic survivors recorded |
| `timeout` | 44.9s | 55 | 18 hangs all `timeout` at 1.002s worst, wall 9.2s against an 82s bound, 0 leftover children |
| `determinism` | 4.0s | 55 | three cold runs identical, warm 0.13s against 0.60s cold with 55/55 cache hits, a new test moves one verdict and deleting it moves it back |
| `hostile` | 2.2s | 67 | 5 messy files all yield mutants, 11 unloadable mutants `skipped` with a reason, score 250/279 recomputed |
| `ci` | 1.1s | 35 | exit codes 0/1, threshold at the printed score, `--diff` inside its allowlist, `--fail-fast` skips the rest |
| `scale` | 56.7s | 18 | 1980 generated lines, 840 mutants, default 2.9s against a 51s oracle (17.5x), 15 sampled verdicts identical, `--jobs=4` 3.8x |

## Rules for changing a case

The criteria above were written before any case existed and before the engine was run against
them.

- A red case is either an engine bug or a harness bug. An engine bug is fixed in `lib/`. A
  harness bug is fixed in the case, and the fix goes in the log below with the reason.
- A case may be made stricter at any time. Making one looser requires a log entry that names the
  invariant that turned out to be wrong, not merely inconvenient.
- A case that cannot pass because the engine is slow is an engine bug. Moving the budget is
  loosening.
- Adding a case is always allowed. Removing one is not.

| Date | Case | Direction | Reason |
| --- | --- | --- | --- |
| 2026-11-20 | all | created | Criteria fixed before the engine was run against them. |
| 2026-11-20 | `stateful` | narrowed | The claim said a `not_infected` decision is never wrong. That is not observable from outside, and on a suite that leaks state a survivor may be optimistic by design. The claim now says what an external check can falsify: reproducibility, and no invented kill. |
| 2026-11-20 | oracle | clarified | `--per-line=all` applies to the correctness cases; `scale` uses the default `--per-line=1` because it measures the path a user gets by default. |
| 2026-11-20 | `ci`, `determinism`, `stateful`, `hostile` | tightened | Budgets were 120-180s against runs of 1-4s, which catches an infinite loop but not a twenty-fold blowup. Now 45-60s. |
