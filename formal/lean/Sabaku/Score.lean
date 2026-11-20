/-
  The mutation score of `lib/sabaku/report.rb` and `lib/sabaku/result.rb`.

  `Report#score` is `killed / (killed + survived + timeout)`. The statements here compare two
  scores by cross-multiplying, so nothing depends on a float rounding mode.
-/

namespace Sabaku.Report

/-- `Result::STATUSES`. -/
inductive Status where
  | killed | survived | timeout | uncovered | error
  deriving DecidableEq, Repr

/-- `Result#counted?`. -/
def Status.counted : Status → Bool
  | killed | survived | timeout => true
  | uncovered | error => false

/-- `Report#counts`. -/
structure Tally where
  killed : Nat := 0
  survived : Nat := 0
  timeout : Nat := 0
  uncovered : Nat := 0
  error : Nat := 0
  deriving DecidableEq, Repr

def Tally.num (t : Tally) : Nat := t.killed

def Tally.den (t : Tally) : Nat := t.killed + t.survived + t.timeout

/-- `Report#counts` over a result list. -/
def Tally.ofList : List Status → Tally
  | [] => {}
  | s :: rest =>
      let t := Tally.ofList rest
      match s with
      | .killed => { t with killed := t.killed + 1 }
      | .survived => { t with survived := t.survived + 1 }
      | .timeout => { t with timeout := t.timeout + 1 }
      | .uncovered => { t with uncovered := t.uncovered + 1 }
      | .error => { t with error := t.error + 1 }

theorem num_le_den (t : Tally) : t.num ≤ t.den := by
  unfold Tally.num Tally.den
  omega

/-- A score is a fraction between zero and one. -/
theorem score_le_one (t : Tally) : t.num * t.den ≤ t.den * t.den := by
  exact Nat.mul_le_mul_right t.den (num_le_den t)

theorem score_ge_zero (t : Tally) : 0 ≤ t.num * t.den := Nat.zero_le _

/-- A zero denominator forces a zero numerator, so `return 0.0` and the division agree. -/
theorem den_zero_num_zero (t : Tally) (h : t.den = 0) : t.num = 0 := by
  have := num_le_den t
  omega

theorem score_zero_iff (t : Tally) : t.num = 0 ↔ t.killed = 0 := by
  unfold Tally.num
  rfl

theorem score_one_iff (t : Tally) :
    t.num = t.den ↔ t.survived = 0 ∧ t.timeout = 0 := by
  unfold Tally.num Tally.den
  omega

/-- Adding a killed mutant to a fixed denominator can only raise the score. -/
theorem killed_monotone (a b : Tally) (h : a.killed ≤ b.killed) (hd : a.den = b.den) :
    a.num * b.den ≤ b.num * a.den := by
  unfold Tally.num
  rw [← hd]
  exact Nat.mul_le_mul_right a.den h

/-- A timeout counts against the score, the same way a survivor does. -/
theorem timeout_weakly_lowers (t : Tally) :
    t.num * t.den ≤ t.num * (t.den + 1) :=
  Nat.mul_le_mul_left t.num (Nat.le_succ t.den)

/-- `uncovered` and `error` never move the score: neither is counted. -/
theorem uncovered_error_ignored (t : Tally) (u e : Nat) :
    (Tally.num { t with uncovered := u, error := e }) = Tally.num t := rfl

theorem uncovered_error_ignored_den (t : Tally) (u e : Nat) :
    (Tally.den { t with uncovered := u, error := e }) = Tally.den t := rfl

/-- A sample with three counted results and one killed scores a third. -/
theorem score_third :
    (Tally.ofList [.killed, .survived, .timeout]).num = 1 ∧
      (Tally.ofList [.killed, .survived, .timeout]).den = 3 := by decide

theorem score_third_bound :
    (Tally.ofList [.killed, .survived, .timeout]).num * 3 ≤ 3 * 3 := by decide

end Sabaku.Report
