---
name: formal-verification
description: Re-verify the mutation engine's algebra and pool protocol. Use when editing lib/mutation/analyzer.rb, aridity.rb, operators/, selection, coverage_map.rb, report.rb, cache.rb, or runner.rb, or when asked whether the engine is correct, deterministic, or safe under concurrency.
---

# Formal verification of the mutation engine

The engine's pure part is proven in Lean 4 and its concurrent part is model checked in Quint.
`formal/README.md` states the properties and the bounds; this file is the procedure.

## Does a change touch verified code?

| If you changed | Run | Then |
| --- | --- | --- |
| `operators/*.rb` | `bin/formal` | A new operator needs a Lean image theorem and a corpus line that reaches it. |
| `aridity.rb` | `bin/formal` | An expert rule is `base`; the recursion is what is proven. Adding a rule needs no proof change, changing the recursion does. |
| `analyzer.rb` (walk, selection, diff) | `bin/formal` | Selection changes hit `Selection.lean`; the diff filter is exercised by `formal/regressions.sh`. |
| `report.rb` | `bin/formal` | `Score.lean` mirrors `score`; `emit.rb` emits the count grid. |
| `cache.rb` | `bin/formal` | `Cache.lean` mirrors read/write and the version check. |
| `runner.rb` (pool, classification) | `bin/formal --deep` | Update `runner.qnt` in the same commit. |
| `adapters/*.rb`, `cli.rb`, `Source`, `Mutant` | `bin/check` only | Not covered here, except `Mutant#splice` via the replay. |

## Run it

```
bin/formal          # about 2 minutes, Quint bound 6 steps
bin/formal --deep   # about 5 minutes, Quint bound 10 steps (reaches finalize)
```

The gate fails on an unfinished proof, a replay mismatch, a violation in the honest model, a
fault variant that stops violating its invariant, or a finding that stops reproducing.

## Read a failure

- **Lean compile error in a theorem.** The property no longer holds for the model. Read the code
  the theorem names in its docstring; if the model still matches the code, the change broke an
  invariant and the theorem is doing its job. If the model no longer matches, update the model
  and say in the commit which line moved.
- **Replay mismatch.** The two implementations disagree. A `splice` mismatch means
  `Mutant#splice` changed shape; a `score` mismatch means `Report#score` or `Result#counted?`
  changed. Diff the two values in the message: Lean prints both.
- **Quint violation in the honest model.** Read the trace Apalache prints. The last actions give
  the schedule, and the violated invariant names the promise. `INV_capacity` failing on a
  `startChild` that ignored `runningCount` is a real pool bug, not a modelling artefact.
- **A fault variant stops violating.** Do not delete it. Either the invariant got weaker or the
  fault switch stopped being wired; fix the model, because a check that cannot fail proves
  nothing.
- **A regression probe goes REGRESSED.** A fixed finding came back. `formal/FINDINGS.md` says
  what the behaviour was and why; fix the cause, not the probe.
- **Quint takes too long.** The model is bounded; lower `--max-steps` and say the new bound in
  the commit. Do not switch to the simulator and call it a proof.

## Coverage record

- `formal/lean/Mutation/Basic.lean`: `Mutant#splice`, `Source#slice`, the no-op condition.
- `formal/lean/Mutation/Operators.lean`: all seven operator tables, `Sbr.removable_indices`,
  `Mutant#initialize`'s id fields.
- `formal/lean/Mutation/Aridity.lean`: `Aridity#arid?`'s recursion and ancestor scans,
  `Analyzer#walk`'s pruning.
- `formal/lean/Mutation/Selection.lean`: `select_per_line`'s group draw and stability.
- `formal/lean/Mutation/Score.lean`: `Report#score`, `Result#counted?`.
- `formal/lean/Mutation/Cache.lean`: `Cache#fetch`, `Cache#store`, `Cache#load_entries`,
  `Runner#persist_results`.
- `formal/quint/runner.qnt`: `Runner#run_pool`, `prepare_entry`'s uncovered path, `finish_job`,
  `classify`, `Report#score`'s denominator.
- `formal/regressions.sh`: the four fixed findings, end to end through the CLI and the library.
- `formal/replay/emit.rb`: the real `Analyzer` over two fixtures and
  `formal/replay/corpus/kitchen_sink.rb`, with all seven operators, `--per-line=2`.

## Sync commit

The verification describes the code at the last commit that changed a covered file. Every
covered file above was last confirmed against the model at that commit. When covered code
changes: rerun, repair or extend the model, and land the model change in the commit that changed
the code. A green build is not confirmation; the confirmation is that the model and the replay
still describe the new code.

## Updating the model

- Keep the code's names and the file:line references in the docstrings. The model's value is
  that a reviewer can open the Ruby beside it.
- Add a theorem when you add a promise, not when you add a branch.
- If a property needs a bound, write the bound into `README.md` and the commit message.
- Regenerate the Quint fault variants with `formal/quint/variants.sh`; never edit
  `formal/quint/broken/`, which is generated and ignored.
