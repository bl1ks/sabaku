/-
  The per-line selection of `lib/sabaku/analyzer.rb`.

  `select_per_line` orders a line's candidates by operator rank, then offset, then operator name,
  then replacement. It keeps the first `per_line` candidates that re-parse. The order is a pure
  function of the candidates, so the model is a left-to-right take and not a random draw: two
  analyses of the same file keep the same mutants, and the cache keeps every id it stored.
-/

universe u

namespace Sabaku.Selection

/-- The line's budget: keep the first `k` candidates of the ordered pool. -/
def pick (k : Nat) (pool : List α) : List α := pool.take k

theorem pick_zero {α : Type u} (pool : List α) : pick 0 pool = [] := rfl

theorem pick_nil {α : Type u} (k : Nat) : pick k ([] : List α) = [] := by
  cases k <;> rfl

theorem pick_cons {α : Type u} (k : Nat) (x : α) (xs : List α) :
    pick (k + 1) (x :: xs) = x :: pick k xs := rfl

/-- A kept candidate was in the line's group. -/
theorem pick_subset (k : Nat) (pool : List α) {x : α} (hx : x ∈ pick k pool) : x ∈ pool := by
  induction pool generalizing k with
  | nil => simp [pick] at hx
  | cons y ys ih =>
      cases k with
      | zero => simp [pick] at hx
      | succ k =>
          rw [pick_cons] at hx
          rcases List.mem_cons.mp hx with rfl | hx
          · exact List.mem_cons_self ..
          · exact List.mem_cons_of_mem _ (ih k hx)

/-- One group keeps exactly `min per_line (group size)` mutants. -/
theorem pick_length (k : Nat) (pool : List α) :
    (pick k pool).length = min k pool.length := by
  unfold pick
  exact List.length_take

theorem pick_le (k : Nat) (pool : List α) : (pick k pool).length ≤ k := by
  rw [pick_length]
  exact Nat.min_le_left _ _

/-- With `--per-line=1` one line contributes at most one mutant. -/
theorem pick_one (pool : List α) : (pick 1 pool).length ≤ 1 :=
  pick_le 1 pool

/-- Asking for at least as many as the group holds keeps the whole group. -/
theorem pick_all (k : Nat) (pool : List α) (hk : pool.length ≤ k) : pick k pool = pool := by
  unfold pick
  exact List.take_of_length_le hk

/-- Re-analysing a file keeps the same mutants: the second pass draws from the list the first
    pass produced, and a take of a take is the same take. -/
theorem pick_stable (k : Nat) (pool : List α) : pick k (pick k pool) = pick k pool := by
  unfold pick
  rw [List.take_take]
  simp

/-! ## The candidate gate

`Analyzer#candidate_parses?` refuses a candidate whose rewritten file does not re-parse, because
every child would fail to load it. `select_per_line` walks the ordered candidates and skips a dead
one, continuing until it has `min per_line group.length` live candidates or the group is empty.
That is the same set as taking `min per_line` from the live candidates, so the pool the theorems
above describe is the parseable subset of the line's group. -/

/-- The candidates a line may keep: the rewrites whose file re-parses. -/
def parseable {α : Type u} (ok : α → Bool) (pool : List α) : List α := pool.filter ok

theorem parseable_subset {α : Type u} (ok : α → Bool) (pool : List α) :
    parseable ok pool ⊆ pool :=
  List.filter_sublist.subset

theorem parseable_eq_self {α : Type u} {ok : α → Bool} {pool : List α}
    (hall : ∀ x ∈ pool, ok x = true) : parseable ok pool = pool := by
  simp only [parseable]
  exact List.filter_eq_self.mpr hall

/-- A kept candidate was in the line's group, gate or no gate. -/
theorem pick_parseable_subset (k : Nat) (ok : α → Bool) (pool : List α) {x : α}
    (hx : x ∈ pick k (parseable ok pool)) : x ∈ pool :=
  parseable_subset ok pool (pick_subset k (parseable ok pool) hx)

/-- A line keeps `min per_line (parseable candidates)` mutants, never more. -/
theorem pick_parseable_length (k : Nat) (ok : α → Bool) (pool : List α) :
    (pick k (parseable ok pool)).length = min k (parseable ok pool).length :=
  pick_length k _

/-- Re-analysing a file keeps the same mutants. The gate is a pure function of the file text, so
    the second pass walks the same live candidates and `pick_all` applies again. -/
theorem pick_stable_parseable (k : Nat) (ok : α → Bool) (pool : List α) :
    pick k (parseable ok (pick k (parseable ok pool))) = pick k (parseable ok pool) := by
  have hlive : ∀ x ∈ pick k (parseable ok pool), ok x = true := by
    intro x hx
    have hmem : x ∈ parseable ok pool := pick_subset k _ hx
    simpa using (List.mem_filter.mp hmem).2
  rw [parseable_eq_self hlive]
  exact pick_stable k _

end Sabaku.Selection
