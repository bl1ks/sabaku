/// The --kill-matrix pass of `lib/sabaku/runner.rb`: `sweep_killers`, `record_sweep`,
/// `verify_sweeps`, `write_row`, and the cache row `prepare_entry` reuses.
///
/// The pool that runner.qnt models is collapsed into one nondeterministic `classify` step per
/// mutant. It yields what the pool and the kill checks can leave behind: a kill naming the
/// first failing test, a kill with no test named (the child exited 1 before reporting), a
/// survivor, a timeout, an error, or a cache hit with or without a stored row. `truth` is the
/// set of tests that would fail against the mutant, chosen at `init`. Every mutant selects
/// every test, in id order.
///
/// What the model checks is that the pass never writes a status, and that a row is either the
/// whole truth or absent. A sweep that fails, or a swept killer whose reload control fails,
/// leaves the mutant scored with no row, and that missing row always says why
/// (`Runner#incomplete_causes`).
///
/// Not modelled: the test-order assumption the tail sweep rests on (a test's verdict does not
/// depend on the tests before it). The model's `truth` is order-free by construction.
module matrix {
  /// Two mutants reach every interaction between a sweep and a second mutant. One worker is
  /// the smallest pool in which `FAULT_ignore_capacity` can start a sweep it must not.
  pure val N = 2
  pure val T = 3
  pure val W = 1

  pure val Mutants = 0.to(N - 1)
  pure val Tests = 0.to(T - 1)

  /// Fault switches. The honest model has all nine false. `variants.sh` flips exactly one line
  /// per variant, and the gate requires an invariant to fail there.
  /// A failed sweep downgrades the kill it was asked about.
  pure val FAULT_sweep_writes_status = false
  /// The row keeps only the swept tests and loses the first failure.
  pure val FAULT_sweep_from_failed_exclusive = false
  /// The tail starts one test late.
  pure val FAULT_tail_skips_one = false
  /// A sweep that timed out writes a complete row from what it had.
  pure val FAULT_failed_sweep_complete = false
  /// A killer whose reload control failed stays in a complete row.
  pure val FAULT_trust_unverified = false
  /// The report is written while a sweep is still running.
  pure val FAULT_report_early = false
  /// Sweeps start beyond the worker limit.
  pure val FAULT_ignore_capacity = false
  /// A cache hit that already has its row is swept again.
  pure val FAULT_sweep_cached_row = false
  /// A row is dropped without recording why.
  pure val FAULT_drop_without_cause = false

  type MState = {
    // "" until classified, then "killed", "survived", "timeout" or "error".
    status: str,
    // The first failing test the result names, -1 when none was named.
    failedTest: int,
    // Writes to `status` after classification. The pass must never make one.
    statusWrites: int,
    // "none", "status_only" or "with_row": what the cache supplied.
    cached: str,
    firstChild: bool,
    // "idle", "queued", "running", "ok" (clean payload), "checked" (killers verified),
    // or "failed" (timeout, crash, bad payload).
    sweep: str,
    tail: Set[int],
    observed: Set[int],
    // "none", "complete", or "dropped" (scored, but no row can be built).
    row: str,
    killers: Set[int],
    rowWrites: int,
    // A swept killer failed its reload control.
    unverified: bool,
    // "none", or why the sweep failed: "sweep_timeout", "sweep_crash", "bad_payload".
    failure: str,
    // "none", or why the row was dropped: a sweep failure, "unverified_killer", "no_killer".
    cause: str,
  }

  pure val Fresh: MState = {
    status: "", failedTest: -1, statusWrites: 0, cached: "none", firstChild: false,
    sweep: "idle", tail: Set(), observed: Set(), row: "none", killers: Set(), rowWrites: 0,
    unverified: false, failure: "none", cause: "none",
  }

  var truth: int -> Set[int]
  var m: int -> MState
  var reported: bool

  def scored(s: MState): bool = s.status == "killed" or s.status == "survived"

  def runningSweeps: int = Mutants.filter(i => m.get(i).sweep == "running").size()

  /// `sweep_tail`: the selected tests after the first failure, or all of them when the kill
  /// named no test.
  pure def tailAfter(f: int): Set[int] =
    if (f < 0) Tests
    else if (FAULT_tail_skips_one) Tests.filter(t => t > f + 1)
    else Tests.filter(t => t > f)

  pure def firstOf(s: Set[int], f: int): bool = s.contains(f) and s.forall(u => f <= u)

  action update(i: int, s: MState): bool = all {
    m' = m.set(i, s),
    truth' = truth,
    reported' = reported,
  }

  action init = all {
    nondet k0 = Tests.powerset().oneOf()
    nondet k1 = Tests.powerset().oneOf()
    truth' = Map(0 -> k0, 1 -> k1),
    m' = Mutants.mapBy(_ => Fresh),
    reported' = false,
  }

  /// The pool, the kill checks and the cache, collapsed: whatever they leave behind.
  action classify = {
    nondet i = oneOf(Mutants)
    nondet f = oneOf(Tests)
    nondet outcome = oneOf(Set("killed", "aborted", "survived", "timeout", "error",
                               "cached_killed", "cached_survived", "cached_row"))
    val s = m.get(i)
    val k = truth.get(i)
    all {
      not(reported),
      s.status == "",
      if (outcome == "killed" or outcome == "cached_killed" or outcome == "cached_row")
        firstOf(k, f)
      else if (outcome == "aborted") k.size() > 0
      else if (outcome == "survived" or outcome == "cached_survived") k.size() == 0
      else true,
      val status =
        if (outcome == "killed" or outcome == "aborted" or outcome == "cached_killed"
            or outcome == "cached_row") "killed"
        else if (outcome == "survived" or outcome == "cached_survived") "survived"
        else outcome
      val failed =
        if (outcome == "killed" or outcome == "cached_killed" or outcome == "cached_row") f
        else -1
      val cached =
        if (outcome == "cached_row") "with_row"
        else if (outcome == "cached_killed" or outcome == "cached_survived") "status_only"
        else "none"
      update(i, { ...s, status: status, failedTest: failed, cached: cached,
                  firstChild: cached == "none" }),
    }
  }

  /// `prepare_entry` built the row from the cache entry, which is what a past sweep found.
  action rowFromCache = {
    nondet i = oneOf(Mutants)
    val s = m.get(i)
    all {
      not(reported),
      s.cached == "with_row",
      s.row == "none",
      update(i, { ...s, row: "complete", killers: truth.get(i), rowWrites: s.rowWrites + 1 }),
    }
  }

  /// Every selected test already ran and passed: the row needs no child.
  action rowForSurvivor = {
    nondet i = oneOf(Mutants)
    val s = m.get(i)
    all {
      not(reported),
      s.status == "survived",
      s.row == "none",
      update(i, { ...s, row: "complete", killers: Set(), rowWrites: s.rowWrites + 1 }),
    }
  }

  action queueSweep = {
    nondet i = oneOf(Mutants)
    val s = m.get(i)
    all {
      not(reported),
      s.status == "killed",
      s.row == "none",
      s.sweep == "idle",
      FAULT_sweep_cached_row or s.cached != "with_row",
      update(i, { ...s, sweep: "queued", tail: tailAfter(s.failedTest) }),
    }
  }

  action startSweep = {
    nondet i = oneOf(Mutants)
    val s = m.get(i)
    all {
      not(reported),
      s.sweep == "queued",
      FAULT_ignore_capacity or runningSweeps < W,
      update(i, { ...s, sweep: "running" }),
    }
  }

  /// `record_sweep` accepts a clean payload: every tail test that fails, and nothing else.
  action finishSweep = {
    nondet i = oneOf(Mutants)
    val s = m.get(i)
    all {
      not(reported),
      s.sweep == "running",
      update(i, { ...s, sweep: "ok", observed: s.tail.intersect(truth.get(i)) }),
    }
  }

  /// A deadline, a signal, a boot error or a payload `record_sweep` refuses.
  action failSweep = {
    nondet i = oneOf(Mutants)
    nondet why = oneOf(Set("sweep_timeout", "sweep_crash", "bad_payload"))
    val s = m.get(i)
    all {
      not(reported),
      s.sweep == "running",
      if (FAULT_sweep_writes_status)
        update(i, { ...s, sweep: "failed", failure: why, status: "error",
                    statusWrites: s.statusWrites + 1 })
      else
        update(i, { ...s, sweep: "failed", failure: why }),
    }
  }

  /// `verify_sweeps`: a swept killer that is not the first failure may fail its reload
  /// control. Whether it does depends on the file, so the model lets it.
  action verifySweep = {
    nondet i = oneOf(Mutants)
    nondet fails = oneOf(Set(true, false))
    val s = m.get(i)
    all {
      not(reported),
      s.sweep == "ok",
      not(fails) or s.observed.exists(t => t != s.failedTest),
      update(i, { ...s, sweep: "checked", unverified: fails }),
    }
  }

  /// `write_row`: the first failure plus what the sweep found.
  action writeRow = {
    nondet i = oneOf(Mutants)
    val s = m.get(i)
    val first = if (s.failedTest >= 0) Set(s.failedTest) else Set()
    val ks = if (FAULT_sweep_from_failed_exclusive) s.observed else first.union(s.observed)
    all {
      not(reported),
      s.sweep == "checked",
      FAULT_trust_unverified or not(s.unverified),
      s.row == "none",
      FAULT_sweep_from_failed_exclusive or ks.size() > 0,
      update(i, { ...s, row: "complete", killers: ks, rowWrites: s.rowWrites + 1 }),
    }
  }

  /// No row can be built: the result keeps its status and the report calls it incomplete.
  action dropRow = {
    nondet i = oneOf(Mutants)
    val s = m.get(i)
    val first = if (s.failedTest >= 0) Set(s.failedTest) else Set()
    val cause =
      if (FAULT_drop_without_cause) "none"
      else if (s.sweep == "failed") s.failure
      else if (s.unverified) "unverified_killer"
      else "no_killer"
    all {
      not(reported),
      s.row == "none",
      s.sweep == "failed" or (s.sweep == "checked" and s.unverified)
        or (s.sweep == "checked" and first.union(s.observed).size() == 0),
      if (FAULT_failed_sweep_complete and s.sweep == "failed")
        update(i, { ...s, row: "complete", killers: first, rowWrites: s.rowWrites + 1 })
      else
        update(i, { ...s, row: "dropped", cause: cause }),
    }
  }

  action finalize = all {
    not(reported),
    Mutants.forall(i => m.get(i).status != ""),
    FAULT_report_early or Mutants.forall(i =>
      val s = m.get(i)
      s.sweep != "queued" and s.sweep != "running" and (not(scored(s)) or s.row != "none")),
    m' = m,
    truth' = truth,
    reported' = true,
  }

  action step = any {
    classify,
    rowFromCache,
    rowForSurvivor,
    queueSweep,
    startSweep,
    finishSweep,
    failSweep,
    verifySweep,
    writeRow,
    dropRow,
    finalize,
  }

  val INV_sweep_keeps_status = Mutants.forall(i => m.get(i).statusWrites == 0)

  val INV_complete_row_is_truth =
    Mutants.forall(i => m.get(i).row == "complete" implies m.get(i).killers == truth.get(i))

  val INV_killed_row_has_first = Mutants.forall(i =>
    val s = m.get(i)
    (s.row == "complete" and s.status == "killed" and s.failedTest >= 0)
      implies s.killers.contains(s.failedTest))

  val INV_survivor_row_empty = Mutants.forall(i =>
    val s = m.get(i)
    (s.row == "complete" and s.status == "survived") implies s.killers == Set())

  val INV_row_only_for_scored =
    Mutants.forall(i => m.get(i).row != "none" implies scored(m.get(i)))

  val INV_failed_sweep_incomplete =
    Mutants.forall(i => m.get(i).sweep == "failed" implies m.get(i).row != "complete")

  val INV_unverified_incomplete =
    Mutants.forall(i => m.get(i).unverified implies m.get(i).row != "complete")

  val INV_cache_hit_no_first_child =
    Mutants.forall(i => m.get(i).cached != "none" implies not(m.get(i).firstChild))

  val INV_row_from_cache_no_sweep =
    Mutants.forall(i => m.get(i).cached == "with_row" implies m.get(i).sweep == "idle")

  val INV_dropped_has_cause = Mutants.forall(i =>
    val s = m.get(i)
    (s.row == "dropped") iff (s.cause != "none"))

  val INV_cause_matches_sweep = Mutants.forall(i =>
    val s = m.get(i)
    (s.cause == "unverified_killer" implies s.unverified) and
      (Set("sweep_timeout", "sweep_crash", "bad_payload").contains(s.cause)
        implies s.sweep == "failed"))

  val INV_one_row_write = Mutants.forall(i => m.get(i).rowWrites <= 1)

  val INV_sweep_capacity = runningSweeps <= W

  val INV_report_after_sweeps = reported implies Mutants.forall(i =>
    val s = m.get(i)
    s.sweep != "queued" and s.sweep != "running" and (not(scored(s)) or s.row != "none"))
}
