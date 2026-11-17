/-
  Bytes, mutants, and the splice the runner applies.

  `lib/mutation/mutant.rb` applies a mutant with `String#bytesplice`, so the offsets are byte
  offsets and the text is modelled as a list of bytes. `lib/mutation/analyzer.rb` replaces
  exactly one node's span, and `Source#slice` gives that span the same meaning.
-/

namespace Mutation

abbrev Bytes := List UInt8

/-- The part of `Mutation::Mutant` the algebra depends on. -/
structure Mutant where
  startOffset : Nat
  endOffset : Nat
  replacement : Bytes
  deriving DecidableEq, Repr

/-- `text.bytesplice start (end - start) replacement`, over byte lists. -/
def splice (text : Bytes) (m : Mutant) : Bytes :=
  text.take m.startOffset ++ m.replacement ++ text.drop m.endOffset

/-- The bytes `m` replaces. `Source#slice` returns this for the node the mutant came from. -/
def slice (text : Bytes) (m : Mutant) : Bytes :=
  (text.drop m.startOffset).take (m.endOffset - m.startOffset)

theorem take_append_of_le {α : Type} (a b : List α) {n : Nat} (h : n ≤ a.length) :
    (a ++ b).take n = a.take n := by
  induction a generalizing n with
  | nil =>
      simp only [List.length_nil] at h
      have hn : n = 0 := Nat.le_zero.mp h
      rw [hn]
      rfl
  | cons x xs ih =>
      cases n with
      | zero => rfl
      | succ k =>
          rw [List.cons_append, List.take_succ_cons, List.take_succ_cons]
          exact congrArg (x :: ·) (ih (by simp only [List.length_cons] at h; omega))

theorem append_left_cancel {α : Type} {a b c : List α} (h : a ++ b = a ++ c) : b = c := by
  induction a with
  | nil => simpa using h
  | cons x xs ih =>
      simp only [List.cons_append, List.cons.injEq] at h
      exact ih h.2

theorem append_right_cancel {α : Type} {a b c : List α} (h : a ++ b = c ++ b) : a = c := by
  induction a generalizing c with
  | nil =>
      cases c with
      | nil => rfl
      | cons y ys =>
          have hl := congrArg List.length h
          simp only [List.nil_append, List.cons_append, List.length_append, List.length_cons] at hl
          omega
  | cons x xs ih =>
      cases c with
      | nil =>
          have hl := congrArg List.length h
          simp only [List.nil_append, List.cons_append, List.length_append, List.length_cons] at hl
          omega
      | cons y ys =>
          simp only [List.cons_append, List.cons.injEq] at h
          rw [h.1, ih h.2]

/-- `text.take start ++ slice text start end ++ text.drop end` puts the file back together. -/
theorem take_slice_drop (text : Bytes) (m : Mutant)
    (h1 : m.startOffset ≤ m.endOffset) (_h2 : m.endOffset ≤ text.length) :
    (text.take m.startOffset ++ slice text m) ++ text.drop m.endOffset = text := by
  unfold slice
  have hsub : (text.drop m.startOffset).drop (m.endOffset - m.startOffset) =
      text.drop m.endOffset := by
    rw [List.drop_drop]
    congr 1
    omega
  have hX : (text.drop m.startOffset).take (m.endOffset - m.startOffset) ++
      text.drop m.endOffset = text.drop m.startOffset := by
    rw [← hsub]
    exact List.take_append_drop _ _
  rw [List.append_assoc, hX, List.take_append_drop]

/-- The splice keeps every byte before the mutation site. -/
theorem splice_prefix (text : Bytes) (m : Mutant) (h : m.startOffset ≤ text.length) :
    (splice text m).take m.startOffset = text.take m.startOffset := by
  have hlen : m.startOffset ≤ (text.take m.startOffset ++ m.replacement).length := by
    rw [List.length_append, List.length_take, Nat.min_eq_left h]
    omega
  unfold splice
  rw [take_append_of_le (text.take m.startOffset ++ m.replacement) (text.drop m.endOffset) hlen]
  rw [take_append_of_le (text.take m.startOffset) m.replacement (by
        rw [List.length_take, Nat.min_eq_left h]
        omega)]
  simp [List.take_take]

/-- The splice's byte length, in the shape `bytesplice` produces. -/
theorem splice_length (text : Bytes) (m : Mutant)
    (h1 : m.startOffset ≤ m.endOffset) (h2 : m.endOffset ≤ text.length) :
    (splice text m).length =
      text.length - (m.endOffset - m.startOffset) + m.replacement.length := by
  have h3 : m.startOffset ≤ text.length := Nat.le_trans h1 h2
  unfold splice
  rw [List.length_append, List.length_append, List.length_take, List.length_drop,
    Nat.min_eq_left h3]
  omega

/-- A splice is a no-op exactly when the replacement is the node's slice.

    This is the property the campaign needs: every mutant read from the analyzer changes the
    file, so a surviving mutant is a fact about the tests and not about a rewrite that did
    nothing. `lib/mutation/analyzer.rb` refuses a replacement whose `original` differs from
    `Source#slice`, which is exactly `slice text m`. -/
theorem splice_noop (text : Bytes) (m : Mutant)
    (h1 : m.startOffset ≤ m.endOffset) (h2 : m.endOffset ≤ text.length) :
    splice text m = text ↔ m.replacement = slice text m := by
  constructor
  · intro h
    have hs : splice text m = (text.take m.startOffset ++ slice text m) ++ text.drop m.endOffset := by
      rw [h]
      exact (take_slice_drop text m h1 h2).symm
    unfold splice at hs
    exact append_left_cancel (append_right_cancel hs)
  · intro h
    rw [splice, h]
    exact take_slice_drop text m h1 h2

theorem mutant_changes_text (text : Bytes) (m : Mutant)
    (h1 : m.startOffset ≤ m.endOffset) (h2 : m.endOffset ≤ text.length)
    (hne : m.replacement ≠ slice text m) :
    splice text m ≠ text := by
  intro h
  exact hne ((splice_noop text m h1 h2).mp h)

theorem splice_insert (text : Bytes) (m : Mutant) (h : m.endOffset = m.startOffset) :
    splice text m = text.take m.startOffset ++ m.replacement ++ text.drop m.startOffset := by
  unfold splice
  rw [h]

theorem splice_example :
    splice [1, 2, 3, 4] ⟨1, 3, [9, 9]⟩ = [1, 9, 9, 4] := rfl

end Mutation
