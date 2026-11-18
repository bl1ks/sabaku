/// The mutation campaign's pool, as `lib/mutation/runner.rb` runs it.
///
/// Preparation decides per mutant: no covering test means `uncovered` with no child, otherwise
/// the mutant queues. At most `W` children run. A running child ends in exactly one of four
/// ways: it reports a result (killed or survived), it exits 1 without a summary (killed: the
/// exit contract already says a selected test failed), it fails to load (error, pending
/// attribution), or the parent kills it at its deadline (timeout).
///
/// `attribute_unmeasured` runs after the pool drains and rewrites a boot-error result to
/// `skipped` when a reload control proves the file, not the mutation, is why the child could not
/// load. It is the `attributeBootError` action. A harness failure during the tests stays `error`:
/// it is a different payload key, and the reload control cannot explain it.
///
/// Two checks sit around the pool and are modelled only where they change a result:
///
///   * `verify_baseline!` runs before any mutant exists: it either lets the campaign start or
///     stops it with no result at all, so there is no mutant state for it to reach.
///   * `verify_kills` runs after the pool and rewrites a reported `killed` to `error` when the
///     same test fails with the target file loaded a second time and no mutation. It is the
///     `verifyKill` action, and `rewrites` counts it, because a second write would otherwise
///     make `INV_one_result` say nothing about the pool.
///   * `attribute_unmeasured` rewrites a boot-error result to `skipped`. It is also counted in
///     `rewrites`, and it is why `INV_skipped_has_no_child` became `INV_skip_from_boot_error`.
///
/// The exit code policy (`error` above zero exits 2, `lib/mutation/cli.rb`) is not modelled here;
/// `bin/check` covers the CLI.
///
/// The deadline race is kept as the freedom to take the timeout transition from any running
/// mutant. `run_pool` checks the pipe before the deadline, so on a real schedule only one of the
/// two is available; offering both over-approximates the schedules, and a safety property that
/// holds in the larger state space holds in the implementation. The clock itself is not
/// modelled: no property below depends on how much time a child took.
module runner {
  /// Three mutants and two workers keep the state space small enough for Apalache to decide
  /// while still letting two children be in flight at once.
  pure val N = 3
  pure val W = 2

  pure val Mutants = 0.to(N - 1)

  /// Fault switches. The honest model has all four false. `variants.sh` flips exactly one line
  /// per variant, and the gate requires the named invariant to fail there, which is how each
  /// property is shown to be able to fail.
  pure val FAULT_double_complete = false
  pure val FAULT_run_uncovered = false
  pure val FAULT_early_report = false
  pure val FAULT_ignore_capacity = false
  /// `--fail-fast` ignored: children keep starting after the first survivor, and the
  /// remaining queue is skipped without a survivor.
  pure val FAULT_ignore_fail_fast = false

  pure def faultOr(f: bool, guard: bool): bool = f or guard

  /// "new" -> "queued" -> "running" -> "done".
  var phase: int -> str
  /// "" until the mutant has an outcome.
  var result: int -> str
  /// How many outcomes the mutant has been given. The runner assigns each entry once.
  var writes: int -> int
  /// How many times the kill check replaced a reported kill with `error`.
  var rewrites: int -> int
  /// Whether a child was started for the mutant, so `uncovered` can be checked against it.
  var childRan: int -> bool
  /// Whether the child failed while loading the file rather than while running the tests, so the
  /// post-pool attribution can turn its `error` into `skipped`.
  var bootFailed: int -> bool
  /// Whether `--fail-fast` has stopped scheduling.
  var halted: bool
  /// Whether the report has been emitted.
  var reported: bool

  def countPhase(p: str): int =
    Mutants.filter(i => phase.get(i) == p).size()

  def countStatus(s: str): int =
    Mutants.filter(i => result.get(i) == s).size()

  def runningCount: int = countPhase("running")
  def doneCount: int = countPhase("done")

  /// `Report#score`'s denominator.
  def den: int = countStatus("killed") + countStatus("survived") + countStatus("timeout")

  action init = all {
    phase' = Map(0 -> "new", 1 -> "new", 2 -> "new"),
    result' = Map(0 -> "", 1 -> "", 2 -> ""),
    writes' = Map(0 -> 0, 1 -> 0, 2 -> 0),
    rewrites' = Map(0 -> 0, 1 -> 0, 2 -> 0),
    childRan' = Map(0 -> false, 1 -> false, 2 -> false),
    bootFailed' = Map(0 -> false, 1 -> false, 2 -> false),
    halted' = false,
    reported' = false,
  }

  /// `prepare_entry` with an empty selection: the mutant is terminal before any child.
  action prepareUncovered = {
    nondet i = oneOf(Mutants)
    all {
      phase.get(i) == "new",
      phase' = phase.set(i, "done"),
      result' = result.set(i, "uncovered"),
      writes' = writes.set(i, writes.get(i) + 1),
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  action prepareQueued = {
    nondet i = oneOf(Mutants)
    all {
      phase.get(i) == "new",
      phase' = phase.set(i, "queued"),
      result' = result,
      writes' = writes,
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// The pool loop: never more than `W` children, and only a queued mutant starts.
  action startChild = {
    nondet i = oneOf(Mutants)
    all {
      faultOr(FAULT_ignore_capacity, runningCount < W),
      faultOr(FAULT_ignore_fail_fast, not(halted)),
      faultOr(FAULT_run_uncovered, phase.get(i) == "queued"),
      phase' = phase.set(i, "running"),
      result' = result,
      writes' = writes,
      childRan' = childRan.set(i, true),
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// The child wrote a completion line and exited 0 or 1.
  action finishChild = {
    nondet i = oneOf(Mutants)
    nondet o = oneOf(Set("killed", "survived"))
    all {
      faultOr(FAULT_double_complete, phase.get(i) == "running"),
      phase' = phase.set(i, "done"),
      result' = result.set(i, o),
      writes' = writes.set(i, writes.get(i) + 1),
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// The child ended itself with the failed-test status and left no summary. `classify` reads
  /// exit 1 as a kill, because that is the status the contract reserves for a failed test.
  action abortChild = {
    nondet i = oneOf(Mutants)
    all {
      phase.get(i) == "running",
      phase' = phase.set(i, "done"),
      result' = result.set(i, "killed"),
      writes' = writes.set(i, writes.get(i) + 1),
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// The child could not load the mutated file (`boot_error`). It stays `error` until
  /// `attributeBootError` decides whether a reload control explains it.
  action bootFailChild = {
    nondet i = oneOf(Mutants)
    all {
      phase.get(i) == "running",
      phase' = phase.set(i, "done"),
      result' = result.set(i, "error"),
      writes' = writes.set(i, writes.get(i) + 1),
      childRan' = childRan,
      bootFailed' = bootFailed.set(i, true),
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// A harness failure while the tests ran (`test_error`), or an exit code that does not match
  /// the payload. The reload control cannot explain it, so it stays `error`.
  action failChild = {
    nondet i = oneOf(Mutants)
    all {
      phase.get(i) == "running",
      phase' = phase.set(i, "done"),
      result' = result.set(i, "error"),
      writes' = writes.set(i, writes.get(i) + 1),
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// `finish_job(timed_out: true)`: kill, reap, and report a timeout.
  action timeoutChild = {
    nondet i = oneOf(Mutants)
    all {
      phase.get(i) == "running",
      phase' = phase.set(i, "done"),
      result' = result.set(i, "timeout"),
      writes' = writes.set(i, writes.get(i) + 1),
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// `halt_fast_fail`: the first survivor stops new work.
  action halt = all {
    not(halted),
    countStatus("survived") > 0,
    phase' = phase,
    result' = result,
    writes' = writes,
    childRan' = childRan,
    bootFailed' = bootFailed,
    halted' = true,
    reported' = reported,
    rewrites' = rewrites,
  }

  /// `mark_skipped`: a mutant that was queued when the run halted is reported as skipped.
  action markSkipped = {
    nondet i = oneOf(Mutants)
    all {
      faultOr(FAULT_ignore_fail_fast, halted),
      phase.get(i) == "queued",
      phase' = phase.set(i, "done"),
      result' = result.set(i, "skipped"),
      writes' = writes.set(i, writes.get(i) + 1),
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
      rewrites' = rewrites,
    }
  }

  /// `verify_kills`: the same test, the target file loaded a second time, no mutation. A failure
  /// means the kill was the harness's, not the suite's, and the result becomes `error`.
  action verifyKill = {
    nondet i = oneOf(Mutants)
    all {
      not(reported),
      phase.get(i) == "done",
      result.get(i) == "killed",
      result' = result.set(i, "error"),
      rewrites' = rewrites.set(i, rewrites.get(i) + 1),
      phase' = phase,
      writes' = writes,
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
    }
  }

  /// `attribute_unmeasured`: after the pool drains, one reload control per file decides whether
  /// the boot error was the file's (it cannot be reloaded) or the mutation's (it does not load).
  /// Either way the mutant is `skipped`, because no child measured it.
  action attributeBootError = {
    nondet i = oneOf(Mutants)
    all {
      not(reported),
      doneCount == N,
      phase.get(i) == "done",
      result.get(i) == "error",
      bootFailed.get(i),
      result' = result.set(i, "skipped"),
      rewrites' = rewrites.set(i, rewrites.get(i) + 1),
      phase' = phase,
      writes' = writes,
      childRan' = childRan,
      bootFailed' = bootFailed,
      halted' = halted,
      reported' = reported,
    }
  }

  /// The campaign returns `@entries.map(&:result)`, in mutant order.
  action finalize = all {
    faultOr(FAULT_early_report, doneCount == N),
    phase' = phase,
    result' = result,
    writes' = writes,
    childRan' = childRan,
    bootFailed' = bootFailed,
    halted' = halted,
    reported' = true,
    rewrites' = rewrites,
  }

  action step = any {
    prepareUncovered,
    prepareQueued,
    startChild,
    finishChild,
    abortChild,
    bootFailChild,
    failChild,
    timeoutChild,
    halt,
    markSkipped,
    attributeBootError,
    verifyKill,
    finalize,
  }

  // ---- properties -------------------------------------------------------------

  /// Every mutant gets exactly one outcome, whatever the schedule.
  val INV_one_result = Mutants.forall(i => writes.get(i) <= 1)

  /// A mutant is done exactly when it has an outcome.
  val INV_done_has_result =
    Mutants.forall(i => (phase.get(i) == "done") == (result.get(i) != ""))

  /// An uncovered mutant never reaches a child.
  val INV_uncovered_has_no_child =
    Mutants.forall(i => result.get(i) == "uncovered" implies not(childRan.get(i)))

  /// The pool keeps at most `W` children in flight.
  val INV_capacity = runningCount <= W

  /// A reported result is rewritten at most once: the kill check, or the boot-error attribution.
  /// An attribution can only reach `error`, and the kill check only `killed`, so they cannot both
  /// touch one mutant.
  val INV_rewrite_at_most_once = Mutants.forall(i => rewrites.get(i) <= 1)

  /// A report is only emitted once every mutant is done, so the pool never loses work.
  val INV_report_complete = reported implies doneCount == N

  /// A reported campaign has an outcome for every mutant.
  val INV_report_has_every_result =
    reported implies Mutants.forall(i => result.get(i) != "")

  /// The score numerator never exceeds the denominator, so the score is at most one.
  val INV_score_bound = countStatus("killed") * den <= den * den

  /// Timeouts are counted, so the denominator covers every scored outcome.
  val INV_denominator_covers_timeouts = den >= countStatus("timeout")

  /// A skipped mutant that started a child is a boot error the reload control explained. No other
  /// path starts a child and then reports `skipped`, so attribution cannot hide a real kill.
  val INV_skip_from_boot_error =
    Mutants.forall(i => (result.get(i) == "skipped" and childRan.get(i)) implies bootFailed.get(i))

  /// A skipped mutant that never started was left in the queue by `--fail-fast`, so a survivor
  /// stopped the run. Attribution mutants ran and are covered by the invariant above.
  val INV_skip_without_child_after_survivor =
    Mutants.forall(i =>
      (result.get(i) == "skipped" and not(childRan.get(i))) implies countStatus("survived") > 0)
}
