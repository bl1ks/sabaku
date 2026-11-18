# Formal verification

What this directory proves about the mutation engine, what it checks, and what it leaves out.

Run everything with `bin/formal`. That takes about two minutes. `bin/formal --deep` raises the
Quint bound from six steps to ten, which is a complete three-mutant campaign, and takes about
five minutes. Tool versions: Lean 4.36.0, Quint 0.33.1, Apalache 0.62.4.

## Three checks, three questions

| Question | Tool | Answer |
| --- | --- | --- |
| Does the algebra hold for every input? | Lean 4 | Proof. 74 theorems, no axioms, no `sorry`. |
| Can the pool lose, double count, or mis-order a result on some schedule? | Quint + Apalache | No violation for every interleaving up to a step bound. |
| Does the running code agree with the model? | Replay | Lean and Ruby independently compute 54 splices and 36 scores; 0 mismatches. |

Lean owns the pure part: offsets, operators, aridity, selection, score, cache. Quint owns the
concurrent part: the pool in `lib/mutation/runner.rb`. The replay is the bridge: it feeds real
mutants from the analyzer to a second implementation in Lean.

## Layout

```
formal/lean/Mutation/Basic.lean      bytes, mutants, splice
formal/lean/Mutation/Operators.lean  the operator tables
formal/lean/Mutation/Aridity.lean    the recursive aridity rule and the walk
formal/lean/Mutation/Selection.lean  per-line selection and its stability
formal/lean/Mutation/Score.lean      the mutation score
formal/lean/Mutation/Cache.lean      cache read/write
formal/lean/Mutation/Replay.lean     the second implementation used by the replay
formal/quint/runner.qnt              the pool model and its invariants
formal/quint/variants.sh             generates one fault variant per invariant
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
| Operators | Relational and connector tokens are disjoint, so two operators cannot emit `true` at one span. | `Mutant#initialize` (the id omits the operator) |
| Operators | `SBR` never removes the last statement of a def body and never removes anything from a declaration container. | `Sbr.removable_indices` |
| Aridity | The recursive rule has exactly one solution at each depth. | `Aridity#arid?` |
| Aridity | The verdict does not depend on the order of the ancestor stack. | `ancestors + [node]` and `reverse_each` |
| Aridity | Adding an expert rule only makes more nodes arid. | `expert_arid?` |
| Aridity | An arid node contributes no mutant and neither does its subtree. | `Analyzer#walk` |
| Aridity | The walk never emits a node outside the subtree it was given. | `Analyzer#walk` |
| Selection | One group keeps exactly `min per_line size` mutants, so never more than `per_line`. | `select_per_line` |
| Selection | With `--per-line=1` one line contributes at most one mutant. | `select_per_line` |
| Selection | A second analysis of the same line keeps the same set. | `select_per_line` |
| Score | The score is in `[0, 1]`; it is 1 only with no survivors and no timeouts. | `Report#score` |
| Score | A timeout counts against the score; `uncovered` and `error` never move it. | `Result#counted?` |
| Cache | The reader never returns `uncovered`. | `Cache#fetch` |
| Cache | Everything the runner writes is read back unchanged. | `persist_results`, `Cache#fetch` |
| Cache | The reader accepts two statuses the writer never produces. | `KNOWN_STATUSES` vs `persist_results` |
| Cache | A file whose version is not 1 is ignored; a current file loads. | `Cache#load_entries` |

## What Quint checks

`formal/quint/runner.qnt` models preparation, the bounded pool, completion, failure, timeout, and
the report. The clock is not modelled: no invariant below depends on elapsed time. The deadline
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
- `INV_skipped_has_no_child`: a `--fail-fast` skipped mutant never started a child.
- `INV_skip_only_after_survivor`: nothing is skipped before a survivor stopped the run.

The default gate checks three mutants with two workers up to six steps; `--deep` checks up to ten
steps, which reaches `finalize`. Apalache decides every interleaving inside the bound, not a
sample.

Each invariant is shown able to fail: `formal/quint/variants.sh` flips one fault switch in the
model, and the gate requires the variant to violate an invariant. The variants are generated, not
copied, so the honest model stays the only source of truth.

## What the replay checks

`formal/replay/emit.rb` analyses the two fixtures and the kitchen-sink corpus with every
operator at `--per-line=2`, twice, and refuses to write anything unless both runs agree. It emits
one splice record per mutant and one score record per count grid. The score record is the
percentage the terminal prints, in tenths of a percent. `lake exe replay` recomputes
each one in Lean; `formal/replay/check.rb` checks the real mutant list against the proven
contract:

- the list is sorted by `(path, start, operator, replacement)`;
- no id repeats and every id recomputes from `(path, start, end, replacement)`;
- at most `per_line` mutants share a line;
- every reported line lies inside its node's span;
- every replacement differs from the bytes it replaces;
- every operator in `Registry.ids` appears.

## What is not covered

- `selector.rb` and `call.rb` are text-rebuild operators: their image is not a token substitution,
  so Lean models the no-op filter (`emitted`) and not the tables themselves. The tables are checked
  by `test/core/operators/meta_test.rb` and by the corpus parse test, not by a proof.
- `CoverageMap#ordered_tests_for_span` only orders the covering tests; the selection cardinality
  properties in `Selection.lean` do not depend on that order.

- The Ruby runtime is modelled, not proven. `fork`, `IO.select`, `SIGKILL`, `waitpid2`, pipe
  buffering, and `Process.spawn` are trusted.
- The adapters (`minitest.rb`, `rspec.rb`, `coverage_sampler.rb`) are trusted. Their framework
  behaviour is covered by the e2e tests, not here.
- Prism's parse tree is trusted. The aridity *expert table* is an uninterpreted `base` predicate;
  the recursive rule is what is proven.
- The selection model fixes only the RNG contract `rand n < n`, not Mersenne Twister. The
  specific draw of a run is covered by the deterministic replay, not proven.
- `Array#sort_by` is not stable. The order is proven canonical only for distinct keys, and the
  replay checks that the corpus has no ties.
- SHA1 truncated to 64 bits can collide. The proof shows the id is a function of
  `(path, start, end, replacement)`; collision resistance is an assumption.
- Nothing about performance. Numbers live in `bench/`.
- Quint is bounded. The honest model is decided for three mutants, two workers, and ten steps in
  `--deep`; larger pools are not checked.

## Findings

`formal/FINDINGS.md` records four behaviours the work exposed. All four are fixed, and
`formal/regressions.sh` asserts the fixed behaviour.

## Keeping it in step

The verification describes the code at the last commit that changed a covered file. See
`.dsh/skills/formal-verification/SKILL.md` for the coverage record and what to do when
the covered code changes.

## Reproducing

```
bin/formal          # about 2 minutes
bin/formal --deep   # about 5 minutes, reaches finalize with three mutants
```

The gate fails if a proof is unfinished, a replay record disagrees, the honest model violates an
invariant, a fault variant fails to violate one, or a fixed finding comes back.
