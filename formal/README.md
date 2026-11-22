# Formal verification

What this directory proves about the mutation engine, what it checks, and what it leaves out.

Run everything with `bin/formal`. That takes about twenty minutes on a WSL2 laptop.
`bin/formal --deep` raises the runner bound from six steps to ten and the matrix bound from six
to eight; "What Quint checks" says what those bounds cover. Tool versions: Lean 4.36.0, Quint 0.33.1, Apalache 0.62.4.

## Three checks, three questions

| Question | Tool | Answer |
| --- | --- | --- |
| Does the algebra hold for every input? | Lean 4 | Proof. 140 theorems, no axioms, no `sorry`. |
| Can the pool or the kill-matrix sweep lose, double count, mis-order or rewrite a result on some schedule? | Quint + Apalache | No violation for every interleaving up to a step bound. |
| Does the running code agree with the model? | Replay | Lean and Ruby independently compute 88 splices, 36 scores and 200 kill-matrix verdict and tier sets; 0 mismatches. |

Lean owns the pure part: offsets, operators, aridity, selection, score, cache, and the kill
matrix's redundancy verdicts. Quint owns the concurrent part: the pool in `lib/sabaku/runner.rb`
and the `--kill-matrix` sweep pass after it. The replay is the bridge: it feeds real
mutants from the analyzer to a second implementation in Lean.

## Layout

```
formal/lean/Sabaku/Basic.lean      bytes, mutants, splice
formal/lean/Sabaku/Operators.lean  the operator tables
formal/lean/Sabaku/Aridity.lean    the recursive aridity rule and the walk
formal/lean/Sabaku/Selection.lean  per-line selection and its stability
formal/lean/Sabaku/Score.lean      the mutation score
formal/lean/Sabaku/Cache.lean      cache read/write
formal/lean/Sabaku/KillMatrix.lean dominance, kept tests, verdicts, the tail sweep
formal/lean/Sabaku/Replay.lean     the second implementation used by the replay
formal/quint/runner.qnt              the pool model and its invariants
formal/quint/matrix.qnt              the --kill-matrix sweep pass and its invariants
formal/quint/variants.sh             generates one fault variant per fault switch
formal/replay/emit.rb                deterministic facts from the real analyzer
formal/replay/check.rb               contract checks on the real mutant list
formal/replay/corpus/kitchen_sink.rb a source that reaches every operator
formal/regressions.sh                asserts the four findings stay fixed
```

## What Lean proves

Each row names the property in plain words and the code it mirrors.

| File | Property | Mirrors |
| --- | --- | --- |
| Basic | A splice keeps every byte before the site, and its length is `len - (end - start) + replacement.len`. | `Mutant#splice` |
| Basic | A splice changes the file exactly when the replacement differs from the node's slice. | `Mutant#splice`, `Analyzer#verify!` |
| Operators | Every operator image excludes the original, so no mutant is a no-op. | `aor.rb`, `ror.rb`, `lcr.rb`, `sbr.rb`, `uoi.rb`, `bool.rb`, `str.rb`, `literal.rb`, `cond.rb`, `assign.rb`, `return.rb`, `control.rb` |
| Operators | A rewrite that reproduces its own input is dropped before it becomes a mutant. | `Analyzer#walk` (`next if replacement.replacement == actual`) |
| Operators | The image is complete: every other token appears. | `OPERATORS - [token]` |
| Operators | Relational and connector tokens are disjoint, so two operators cannot emit `true` at one span. | `Mutant#initialize` (the id includes the operator) |
| Operators | `SBR` never removes the last statement of a def body and never removes anything from a declaration container. | `Sbr.removable_indices` |
| Aridity | The recursive rule has exactly one solution at each depth. | `Aridity#arid?` |
| Aridity | The verdict does not depend on the order of the ancestor stack. | `ancestors + [node]` and `reverse_each` |
| Aridity | Adding an expert rule only makes more nodes arid. | `expert_arid?` |
| Aridity | An arid node contributes no mutant and neither does its subtree. | `Analyzer#walk` |
| Aridity | The walk never emits a node outside the subtree it was given. | `Analyzer#walk` |
| Selection | One group keeps at most `min per_line size` mutants, so never more than `per_line`. | `select_per_line` |
| Selection | A candidate whose rewrite does not re-parse is never kept, and it costs the line no other candidate. | `candidate_parses?`, `select_per_line` |
| Selection | With `--per-line=1` one line contributes at most one mutant. | `select_per_line` |
| Selection | A second analysis of the same line keeps the same set. | `select_per_line` |
| Score | The score is in `[0, 1]`; it is 1 only with no survivors and no timeouts. | `Report#score` |
| Score | A timeout counts against the score; `uncovered` and `error` never move it. | `Result#counted?` |
| Cache | The reader never returns `uncovered`. | `Cache#fetch` |
| Cache | Everything the runner writes is read back unchanged. | `persist_results`, `Cache#fetch` |
| Cache | The reader accepts two statuses the writer never produces. | `KNOWN_STATUSES` vs `persist_results` |
| Cache | A file whose version is not the current one is ignored; a current file loads. | `Cache#load_entries` |
| KillMatrix | Dominance is irreflexive, asymmetric and transitive; equal kill sets are broken by id. | `KillMatrix#dominates?` |
| KillMatrix | Every dominated test has a kept dominator, and `by` is the strongest one: kept, and no kept dominator kills more. | `Verdict#by` |
| KillMatrix | Dropping the redundant tests still kills every killed mutant. | `KillMatrix#verdicts` |
| KillMatrix | A scored test is subsumed or duplicate exactly when a dominator exists, and duplicate means equal kill sets. | `KillMatrix#verdicts` |
| KillMatrix | A test that is the only killer of some mutant is kept. | `Verdict#unique` |
| KillMatrix | A mutant the test does not kill cannot change whether it is redundant or unique. | `KillMatrix.from` |
| KillMatrix | Under a group map, the verdict is the suite verdict over the test's group, `by` is in that group, and dropping a group's redundant tests keeps every kill the group had. | `KillMatrix.group_of`, `dominators` |
| KillMatrix | Only a redundant verdict carries a tier, and an artifact test kills nothing that a test of its group ran and survived. | `Verdict#tier`, `KillMatrix#broad?` |
| KillMatrix | A killed row is the first failure followed by every failing test after it. | `sweep_tail`, `write_row` |

## What Quint checks

`formal/quint/runner.qnt` models preparation, the bounded pool, completion, failure, timeout,
the first-load retry, and the report. The clock is not modelled: no invariant below depends on elapsed time. The deadline
race is kept as the freedom to time out any running child, which over-approximates the schedules
`run_pool` produces.

Checked invariants:

- `INV_one_result`: every mutant gets one outcome.
- `INV_done_has_result`: a mutant is done exactly when it has an outcome.
- `INV_uncovered_has_no_child`: an uncovered mutant never starts a child.
- `INV_capacity`: at most `W` children are in flight.
- `INV_report_complete`: a report is emitted only when every mutant is done.
- `INV_report_has_every_result`: a reported campaign has an outcome for every mutant.
- `INV_score_bound`: the score numerator never exceeds the denominator.
- `INV_denominator_covers_timeouts`: timeouts are counted.
- `INV_skip_from_boot_error`: a skipped mutant that started a child is a boot error the reload
  control explained.
- `INV_skip_without_child_after_survivor`: a skipped mutant that never started was left in the
  queue by `--fail-fast`, so a survivor stopped the run.
- `INV_rewrite_at_most_once`: a reported result is rewritten at most once, by the kill check.
- `INV_retry_measured_once`: a boot error becomes a measured result only through a child on the
  first-load surface.
- `INV_weak_has_no_child`: a mutant the weak pass decided never starts a child.

The halt has two triggers in the code and one in the model. `--fail-fast` also stops the campaign
at a survivor the probe pass proved, before the first child starts. The model leaves `halted` free
during preparation, which admits that trace and every trace where it does not halt, so a schedule
the code cannot produce cannot hide a violation; the fault variants therefore exercise the
child-side halt only.

Two checks sit around the pool and are modelled only where they can change a result. The baseline
runs before any mutant exists, so it either lets the campaign start or ends it with no result at
all. The kill check rewrites a reported `killed` to `error`. The attribution is not a rewrite: a
boot error leaves the mutant `unmeasured` with no outcome, and either the retry's child writes its
only result or the attribution writes `skipped`. `INV_one_result` therefore still says something
about every path that produces a result.

The default gate checks three mutants with two workers up to six steps. That bound reaches
preparation, the pool, a boot error, the retry transition and `finalize`. A trace that carries a
retried mutant to a measured result needs eight steps; `--deep` raises the bound to ten, but the
ten-step run does not finish inside the gate's budget, so the retried result is checked at six
steps only through the transition and the invariant that guards it. Apalache decides every
interleaving inside the bound, not a sample.

`formal/quint/matrix.qnt` models the `--kill-matrix` pass. The pool is collapsed into one
nondeterministic classification per mutant, which can leave a kill with or without a named test,
a survivor, a timeout, an error, or a cache hit with or without a stored row. Each mutant then
gets a row from the cache, an empty row as a survivor, or a sweep of its tail on a bounded pool
followed by the reload control and the write. Two mutants, three tests and one worker. A fixed
`Focus` of two tests stands for `--kill-matrix-focus`: the sweep runs only the focus's part of the
tail, so a row covers the focus plus the first failure.

Checked invariants:

- `INV_sweep_keeps_status`: the pass never writes a status, so the score cannot move.
- `INV_complete_row_is_truth`: a written row is exactly the set of tests that fail among the focus
  and the first failure.
- `INV_killed_row_has_first`: a killed row contains the test that first failed.
- `INV_survivor_row_empty`: a survivor's row is empty.
- `INV_row_only_for_scored`: timeouts and errors never get a row.
- `INV_failed_sweep_incomplete`: a sweep that fails leaves no row.
- `INV_unverified_incomplete`: a killer whose reload control fails leaves no row.
- `INV_cache_hit_no_first_child`: a cache hit never starts a first child.
- `INV_row_from_cache_no_sweep`: a cache hit with a stored row is not swept again.
- `INV_dropped_has_cause`: a row is dropped exactly when it records why.
- `INV_cause_matches_sweep`: a sweep failure cause needs a failed sweep, and `unverified_killer`
  needs a killer whose reload control failed.
- `INV_one_row_write`: a row is written at most once.
- `INV_sweep_capacity`: at most `W` sweeps are in flight.
- `INV_report_after_sweeps`: the report waits for every sweep.

The honest matrix model is decided to six steps in the default gate and to eight, a complete
two-mutant pass, under `--deep`.

Each invariant is shown able to fail: `formal/quint/variants.sh` flips one fault switch in a
model, and the gate requires the variant to violate an invariant. Matrix variants go to
`formal/quint/broken-matrix/`. The variants are generated, not
copied, so the honest model stays the only source of truth.

## What the replay checks

`formal/replay/emit.rb` analyses the two fixtures and the kitchen-sink corpus with every
operator at `--per-line=2`, twice, and refuses to write anything unless both runs agree. It emits
one splice record per mutant and one score record per count grid. The score record is the
percentage the terminal prints, in tenths of a percent. `lake exe replay` recomputes
each one in Lean; `formal/replay/check.rb` checks the real mutant list against the proven
contract:

- the list is sorted by `(path, start, operator, replacement)`;
- no id repeats and every id recomputes from `(path, scope, AST path, operator, replacement)`;
- at most `per_line` mutants share a line;
- every reported line lies inside its node's span;
- every replacement differs from the bytes it replaces;
- every operator in `Registry.ids` appears.

## What is not covered

- `selector.rb` and `call.rb` are text-rebuild operators: their image is not a token substitution,
  so Lean models the no-op filter (`emitted`) and not the tables themselves. The tables are checked
  by `test/core/operators/meta_test.rb` and by the corpus parse test, not by a proof.
- The tail sweep assumes a test's verdict does not depend on the tests before it. A killer
  that fails only after an earlier test has run is missed or misattributed. The matrix model's
  `truth` is order-free by construction, so this assumption is not checked.
- `Cache.lean` does not model the stored `killers` row. Unit tests cover that a row is read back
  only for a killed entry whose first failure it contains.
- `CoverageMap#ordered_tests_for_span` only orders the covering tests; the selection cardinality
  properties in `Selection.lean` do not depend on that order.

- The Ruby runtime is modelled, not proven. `fork`, `IO.select`, `SIGKILL`, `waitpid2`, pipe
  buffering, and `Process.spawn` are trusted.
- The adapter (`minitest.rb`) and `coverage_sampler.rb` are trusted. Their framework behaviour is
  covered by the e2e tests, not here.
- Prism's parse tree is trusted. The aridity *expert table* is an uninterpreted `base` predicate;
  the recursive rule is what is proven.
- The selection model is the deterministic take of the first `per_line` parseable candidates, so
  the specific ranking (`Registry.rank`, offsets, names) is modelled by its result, not proven
  element by element. The replay checks the real analyzer's order.
- `Array#sort_by` is not stable. The order is proven canonical only for distinct keys, and the
  replay checks that the corpus has no ties.
- SHA1 truncated to 64 bits can collide. The proof shows the id is a function of
  `(path, scope, AST path, operator, replacement)`; collision resistance is an assumption.
- `LoadHazard` decides which files get a kill check. It is a screen over the parse tree, not a
  proof: a file that runs no unknown code at load time is assumed to be unobservable when loaded
  twice, and a construct the screen does not recognize would leave its kills unverified. The probe
  itself is exact — it runs the same test with the file loaded once more and no mutation.
- Nothing about performance.
- Quint is bounded. The honest model is decided for three mutants, two workers, and six steps in
  the default gate; larger pools are not checked. `--deep` raises the bound to ten, but the
  ten-step run does not finish in the gate's budget now that attribution and the first-load retry
  both extend the path. A retried mutant's measured result is first reachable at eight steps,
  which is also outside the budget, so the runner classification is currently confirmed at six
  steps.

## Findings

`formal/FINDINGS.md` records four behaviours the work exposed. All four are fixed, and
`formal/regressions.sh` asserts the fixed behaviour.

## Keeping it in step

The verification describes the code at the last commit that changed a covered file, at
the six-step bound (see "What Quint checks"). See
`.dsh/skills/formal-verification/SKILL.md` for the coverage record and what to do when
the covered code changes.

## Reproducing

```
bin/formal          # about 20 minutes, six steps
bin/formal --deep   # runner at ten steps, which does not finish in the gate's budget; matrix at eight
```

The gate fails if a proof is unfinished, a replay record disagrees, the honest model violates an
invariant, a fault variant fails to violate one, or a fixed finding comes back.
