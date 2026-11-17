/-
  The one-mutant-per-line selection of `lib/mutation/analyzer.rb`.

  `select_per_line` groups the candidates of one line, orders them deterministically, and draws
  `min per_line length` of them with `Random#rand`. The RNG is modelled by its only contract,
  `rand n < n`. Everything the campaign promises follows from that contract alone, so these
  theorems do not depend on Mersenne Twister.
-/

universe u

namespace Mutation.Selection

/-- What `Random#rand n` guarantees for `n > 0`. -/
def RngOk (rand : Nat → Nat) : Prop := ∀ n, 0 < n → rand n < n

/-- One draw: take the item at the RNG's index and remove that position. -/
def pick (rand : Nat → Nat) (h : RngOk rand) : Nat → List α → List α
  | 0, _ => []
  | k + 1, [] => []
  | k + 1, x :: xs =>
      let i := rand (x :: xs).length
      have hi : i < (x :: xs).length := h _ (by simp)
      (x :: xs).get ⟨i, hi⟩ :: pick rand h k ((x :: xs).eraseIdx i)

theorem pick_zero (rand : Nat → Nat) (h : RngOk rand) {α : Type u} (pool : List α) :
    pick rand h 0 pool = [] := rfl

theorem pick_nil (rand : Nat → Nat) (h : RngOk rand) {α : Type u} (k : Nat) :
    pick rand h (k + 1) ([] : List α) = [] := rfl

theorem pick_cons (rand : Nat → Nat) (h : RngOk rand) {α : Type u} (k : Nat) (x : α)
    (xs : List α) :
    pick rand h (k + 1) (x :: xs) =
      (x :: xs).get ⟨rand (x :: xs).length, h (x :: xs).length (by simp)⟩ ::
        pick rand h k ((x :: xs).eraseIdx (rand (x :: xs).length)) := rfl

theorem mem_of_mem_eraseIdx {α : Type u} {l : List α} {i : Nat} {x : α}
    (h : x ∈ l.eraseIdx i) : x ∈ l := by
  induction l generalizing i with
  | nil => simp at h
  | cons y ys ih =>
      cases i with
      | zero =>
          rw [List.eraseIdx_cons_zero] at h
          exact List.mem_cons_of_mem y h
      | succ k =>
          rw [List.eraseIdx_cons_succ] at h
          rcases List.mem_cons.mp h with rfl | h
          · simp
          · exact List.mem_cons_of_mem y (ih h)

theorem length_eraseIdx_lt {α : Type u} {l : List α} {i : Nat} (h : i < l.length) :
    (l.eraseIdx i).length = l.length - 1 := by
  rw [List.length_eraseIdx]
  simp [h]

theorem perm_get_eraseIdx {α : Type u} (l : List α) (i : Nat) (h : i < l.length) :
    (l.get ⟨i, h⟩ :: l.eraseIdx i).Perm l := by
  induction l generalizing i with
  | nil => simp at h
  | cons y ys ih =>
      cases i with
      | zero => simp
      | succ k =>
          rw [List.eraseIdx_cons_succ, List.get_cons_succ]
          have hk : k < ys.length := by simpa using h
          refine (List.Perm.swap y (ys.get ⟨k, hk⟩) (ys.eraseIdx k)).trans ?_
          exact List.Perm.cons y (ih k hk)

/-- A draw of `k` items from one line's group is a sublist of that group. -/
theorem pick_subset (rand : Nat → Nat) (h : RngOk rand) (k : Nat) (pool : List α)
    {x : α} (hx : x ∈ pick rand h k pool) : x ∈ pool := by
  induction k generalizing pool with
  | zero => simp [pick_zero] at hx
  | succ k ih =>
      cases pool with
      | nil => simp [pick_nil] at hx
      | cons y ys =>
          rw [pick_cons] at hx
          rcases List.mem_cons.mp hx with rfl | hx
          · exact List.getElem_mem _
          · have hx' : x ∈ (y :: ys).eraseIdx (rand (y :: ys).length) := ih _ hx
            exact mem_of_mem_eraseIdx hx'

/-- One group keeps exactly `min per_line (group size)` mutants, so it never keeps more than
    `per_line`. -/
theorem pick_length (rand : Nat → Nat) (h : RngOk rand) (k : Nat) (pool : List α) :
    (pick rand h k pool).length = min k pool.length := by
  induction k generalizing pool with
  | zero => simp [pick_zero]
  | succ k ih =>
      cases pool with
      | nil => simp [pick_nil]
      | cons y ys =>
          have hi : rand (y :: ys).length < (y :: ys).length := h _ (by simp)
          rw [pick_cons, List.length_cons, ih ((y :: ys).eraseIdx (rand (y :: ys).length)),
            length_eraseIdx_lt hi]
          have hlen : (y :: ys).length = ys.length + 1 := rfl
          rw [hlen, Nat.succ_min_succ]
          omega

theorem pick_le (rand : Nat → Nat) (h : RngOk rand) (k : Nat) (pool : List α) :
    (pick rand h k pool).length ≤ k := by
  rw [pick_length]
  exact Nat.min_le_left _ _

/-- With `--per-line=1` one line contributes at most one mutant. -/
theorem pick_one (rand : Nat → Nat) (h : RngOk rand) (pool : List α) :
    (pick rand h 1 pool).length ≤ 1 :=
  pick_le rand h 1 pool

/-- Drawing at least as many as the group holds keeps the whole group, so a second analysis of
    the same line cannot drop a mutant the first one chose. -/
theorem pick_all_perm (rand : Nat → Nat) (h : RngOk rand) (k : Nat) (pool : List α)
    (hk : pool.length ≤ k) : (pick rand h k pool).Perm pool := by
  induction k generalizing pool with
  | zero =>
      cases pool with
      | nil => simp [pick_zero]
      | cons y ys => simp at hk
  | succ k ih =>
      cases pool with
      | nil => simp [pick_nil]
      | cons y ys =>
          have hi : rand (y :: ys).length < (y :: ys).length := h _ (by simp)
          rw [pick_cons]
          have hperm := perm_get_eraseIdx (y :: ys) (rand (y :: ys).length) hi
          have hrec : (pick rand h k ((y :: ys).eraseIdx (rand (y :: ys).length))).Perm
              ((y :: ys).eraseIdx (rand (y :: ys).length)) := by
            refine ih _ ?_
            rw [length_eraseIdx_lt hi]
            omega
          exact (List.Perm.cons ((y :: ys).get ⟨rand (y :: ys).length, hi⟩) hrec).trans hperm

/-- Re-analysing a file yields the same set of mutants on every line: a second pass keeps
    everything the first pass kept. -/
theorem pick_stable_perm (rand : Nat → Nat) (h : RngOk rand) (k : Nat) (pool : List α)
    (hk : (pick rand h k pool).length ≤ k) :
    (pick rand h k (pick rand h k pool)).Perm (pick rand h k pool) :=
  pick_all_perm rand h k _ hk

end Mutation.Selection
