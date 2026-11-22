/-
  Test redundancy over the kill graph, mirroring `Sabaku::KillMatrix` and the runner's tail sweep.

  A test is its index in the sorted universe, so the id tiebreak is `<` on `Nat`. `K t m` says test
  `t` failed against mutant `m`, and `ms` are the complete rows: every selected test ran against
  them. `seen` says the test was selected for at least one scored mutant, complete or not.
-/

namespace Sabaku.KillMatrix

variable {μ : Type}

/-- `kills t ⊆ kills t'` over the complete rows. -/
def sub (K : Nat → μ → Bool) (ms : List μ) (t t' : Nat) : Bool :=
  ms.all (fun m => !K t m || K t' m)

/-- `t'` makes `t` redundant: a superset of its kills, and on equal sets the smaller id wins. -/
def dom (K : Nat → μ → Bool) (ms : List μ) (t' t : Nat) : Bool :=
  t' != t && sub K ms t t' && (!sub K ms t' t || decide (t' < t))

def count (K : Nat → μ → Bool) (ms : List μ) (t : Nat) : Nat :=
  (ms.filter (K t)).length

def dominated (K : Nat → μ → Bool) (ms : List μ) (ts : List Nat) (t : Nat) : Bool :=
  ts.any (fun t' => dom K ms t' t)

def keep (K : Nat → μ → Bool) (ms : List μ) (ts : List Nat) : List Nat :=
  ts.filter (fun t => !dominated K ms ts t)

/-- `KillMatrix`'s `min_by { [-kills.size, id] }`: more kills first, then the smaller id. -/
def better (K : Nat → μ → Bool) (ms : List μ) (a b : Nat) : Bool :=
  decide (count K ms b < count K ms a ∨ (count K ms a = count K ms b ∧ a < b))

def pick (r : Nat → Nat → Bool) : List Nat → Option Nat
  | [] => none
  | a :: rest =>
    match pick r rest with
    | none => some a
    | some b => if r a b then some a else some b

/-- The `by` a redundant test names: the strongest test that dominates it. -/
def witness (K : Nat → μ → Bool) (ms : List μ) (ts : List Nat) (t : Nat) : Option Nat :=
  pick (better K ms) (ts.filter (fun t' => dom K ms t' t))

inductive Kind
  | kept
  | subsumed
  | duplicate
  | zero
  | idle
  deriving DecidableEq, Repr

def verdict (K : Nat → μ → Bool) (ms : List μ) (ts : List Nat) (seen : Bool) (t : Nat) : Kind :=
  if !seen then .idle
  else if count K ms t = 0 then .zero
  else
    match witness K ms ts t with
    | none => .kept
    | some b => if sub K ms b t then .duplicate else .subsumed

/-- `m` is killed by `t` and by no other test. A property of one row, so other rows cannot move it. -/
def unique (K : Nat → μ → Bool) (ts : List Nat) (t : Nat) (m : μ) : Bool :=
  K t m && ts.all (fun t' => t' == t || !K t' m)

/-! ## Filter-length facts -/

theorem len_filter_mono {α : Type} (p q : α → Bool) :
    ∀ l : List α, (∀ x ∈ l, p x = true → q x = true) →
      (l.filter p).length ≤ (l.filter q).length
  | [], _ => by simp
  | a :: l, h => by
    have ih := len_filter_mono p q l (fun x hx => h x (List.mem_cons_of_mem _ hx))
    have ha := h a List.mem_cons_self
    cases hp : p a <;> cases hq : q a <;> simp_all <;> omega

theorem len_filter_strict {α : Type} (p q : α → Bool) :
    ∀ l : List α, (∀ x ∈ l, p x = true → q x = true) →
      (∃ x ∈ l, q x = true ∧ p x = false) →
      (l.filter p).length < (l.filter q).length
  | [], _, ⟨_, hx, _⟩ => by simp at hx
  | a :: l, h, ⟨x, hx, hqx, hpx⟩ => by
    have hmono := len_filter_mono p q l (fun y hy => h y (List.mem_cons_of_mem _ hy))
    have ha := h a List.mem_cons_self
    rcases List.mem_cons.mp hx with rfl | hx'
    · simp [hqx, hpx]
      omega
    · have ih := len_filter_strict p q l (fun y hy => h y (List.mem_cons_of_mem _ hy))
        ⟨x, hx', hqx, hpx⟩
      cases hp : p a <;> cases hq : q a <;> simp_all <;> omega

/-! ## The preorder and domination -/

variable {K : Nat → μ → Bool} {ms : List μ}

theorem sub_iff {t t' : Nat} :
    sub K ms t t' = true ↔ ∀ m ∈ ms, K t m = true → K t' m = true := by
  unfold sub
  simp only [List.all_eq_true, Bool.or_eq_true, Bool.not_eq_true']
  constructor
  · intro h m hm hk
    rcases h m hm with h1 | h1
    · simp [hk] at h1
    · exact h1
  · intro h m hm
    cases hk : K t m
    · exact Or.inl rfl
    · exact Or.inr (h m hm hk)

theorem sub_false_iff {t t' : Nat} :
    sub K ms t t' = false ↔ ∃ m ∈ ms, K t m = true ∧ K t' m = false := by
  constructor
  · intro h
    apply Classical.byContradiction
    intro hne
    have : sub K ms t t' = true := by
      rw [sub_iff]
      intro m hm hk
      cases hk' : K t' m
      · exact absurd ⟨m, hm, hk, hk'⟩ hne
      · rfl
    simp [this] at h
  · rintro ⟨m, hm, hk, hk'⟩
    cases hs : sub K ms t t'
    · rfl
    · have := sub_iff.mp hs m hm hk
      simp [hk'] at this

theorem dom_iff {t' t : Nat} :
    dom K ms t' t = true ↔ t' ≠ t ∧ sub K ms t t' = true ∧ (sub K ms t' t = false ∨ t' < t) := by
  unfold dom
  cases h1 : sub K ms t t' <;> cases h2 : sub K ms t' t <;> simp

theorem sub_refl (t : Nat) : sub K ms t t = true :=
  sub_iff.mpr (fun _ _ h => h)

theorem sub_trans {a b c : Nat} (hab : sub K ms a b = true) (hbc : sub K ms b c = true) :
    sub K ms a c = true :=
  sub_iff.mpr (fun m hm h => sub_iff.mp hbc m hm (sub_iff.mp hab m hm h))

theorem count_le_of_sub {t t' : Nat} (h : sub K ms t t' = true) :
    count K ms t ≤ count K ms t' :=
  len_filter_mono (K t) (K t') ms (sub_iff.mp h)

theorem count_lt_of_strict {t t' : Nat} (h : sub K ms t t' = true)
    (hs : sub K ms t' t = false) : count K ms t < count K ms t' := by
  obtain ⟨m, hm, hk', hk⟩ := sub_false_iff.mp hs
  exact len_filter_strict (K t) (K t') ms (sub_iff.mp h) ⟨m, hm, hk', hk⟩

theorem count_eq_zero_iff {t : Nat} : count K ms t = 0 ↔ ∀ m ∈ ms, K t m = false := by
  unfold count
  simp [List.filter_eq_nil_iff]

/-- A test with no kills is `≼` every test, which is why `zero` is a bucket of its own. -/
theorem zero_sub_all {t : Nat} (h : count K ms t = 0) (t' : Nat) : sub K ms t t' = true := by
  rw [sub_iff]
  intro m hm hk
  simp [count_eq_zero_iff.mp h m hm] at hk

theorem dom_irrefl (t : Nat) : dom K ms t t = false := by
  simp [dom]

theorem dom_asymm {a b : Nat} (h : dom K ms a b = true) : dom K ms b a = false := by
  rw [dom_iff] at h
  cases hb : dom K ms b a
  · rfl
  · rw [dom_iff] at hb
    obtain ⟨_, hba, hab | hlt⟩ := h
    · simp [hab] at hb
    · obtain ⟨_, _, hab' | hlt'⟩ := hb
      · simp [hab'] at hba
      · omega

theorem dom_trans {a b c : Nat} (hab : dom K ms a b = true) (hbc : dom K ms b c = true) :
    dom K ms a c = true := by
  have hasym : dom K ms b a = false := dom_asymm hab
  have hne : a ≠ c := by
    rintro rfl
    simp [hbc] at hasym
  rw [dom_iff] at hab hbc ⊢
  obtain ⟨_, hba, hab'⟩ := hab
  obtain ⟨_, hcb, hbc'⟩ := hbc
  have hca : sub K ms c a = true := sub_trans hcb hba
  refine ⟨hne, hca, ?_⟩
  · cases hac : sub K ms a c
    · exact Or.inl rfl
    · right
      have hab2 : sub K ms a b = true := sub_trans hac hcb
      have hbc2 : sub K ms b c = true := sub_trans hba hac
      rcases hab' with h | h
      · simp [hab2] at h
      · rcases hbc' with h' | h'
        · simp [hbc2] at h'
        · omega

/-- A reported redundant test satisfies the literal predicate `kills t ⊆ kills t'`, `t' ≠ t`. -/
theorem dom_implies_sub {t' t : Nat} (h : dom K ms t' t = true) :
    t' ≠ t ∧ sub K ms t t' = true :=
  let ⟨hne, hs, _⟩ := dom_iff.mp h
  ⟨hne, hs⟩

/-- The literal predicate either reports `t`, or `t` is the smallest id of an equal-kill class. -/
theorem sub_implies_dom_or_canonical {t' t : Nat} (hne : t' ≠ t) (h : sub K ms t t' = true) :
    dom K ms t' t = true ∨ (sub K ms t' t = true ∧ t < t') := by
  cases hs : sub K ms t' t
  · left
    exact dom_iff.mpr ⟨hne, h, Or.inl hs⟩
  · by_cases hlt : t' < t
    · left
      exact dom_iff.mpr ⟨hne, h, Or.inr hlt⟩
    · right
      exact ⟨rfl, by omega⟩

/-! ## The witness -/

theorem better_irrefl (a : Nat) : better K ms a a = false := by
  simp [better]

theorem better_trans {a b c : Nat} (hab : better K ms a b = true) (hbc : better K ms b c = true) :
    better K ms a c = true := by
  simp only [better, decide_eq_true_eq] at hab hbc ⊢
  omega

theorem pick_eq_none_iff (r : Nat → Nat → Bool) : ∀ l : List Nat, pick r l = none ↔ l = []
  | [] => by simp [pick]
  | a :: rest => by
    simp only [pick]
    cases pick r rest with
    | none => simp
    | some b => by_cases h : r a b = true <;> simp [h]

theorem pick_spec (r : Nat → Nat → Bool) (hirr : ∀ a, r a a = false)
    (htrans : ∀ a b c, r a b = true → r b c = true → r a c = true) :
    ∀ (l : List Nat) (b : Nat), pick r l = some b → b ∈ l ∧ ∀ c ∈ l, r c b = false
  | [], _, h => by simp [pick] at h
  | a :: rest, b, h => by
    simp only [pick] at h
    cases hp : pick r rest with
    | none =>
      rw [hp] at h
      cases h
      have hrest : rest = [] := (pick_eq_none_iff r rest).mp hp
      subst hrest
      simp [hirr]
    | some b' =>
      rw [hp] at h
      obtain ⟨hmem, hbest⟩ := pick_spec r hirr htrans rest b' hp
      by_cases hab : r a b' = true
      · simp [hab] at h
        subst h
        refine ⟨List.mem_cons_self, ?_⟩
        intro c hc
        rcases List.mem_cons.mp hc with rfl | hc'
        · exact hirr c
        · cases hca : r c a
          · rfl
          · have := htrans c a b' hca hab
            simp [hbest c hc'] at this
      · simp [hab] at h
        subst h
        refine ⟨List.mem_cons_of_mem _ hmem, ?_⟩
        intro c hc
        rcases List.mem_cons.mp hc with rfl | hc'
        · simpa using hab
        · exact hbest c hc'

variable {ts : List Nat}

theorem witness_spec {t b : Nat} (h : witness K ms ts t = some b) :
    b ∈ ts ∧ dom K ms b t = true ∧
      ∀ c ∈ ts, dom K ms c t = true → better K ms c b = false := by
  obtain ⟨hmem, hbest⟩ :=
    pick_spec (better K ms) better_irrefl (fun _ _ _ => better_trans) _ b h
  rw [List.mem_filter] at hmem
  exact ⟨hmem.1, hmem.2, fun c hc hd => hbest c (List.mem_filter.mpr ⟨hc, hd⟩)⟩

theorem witness_isSome_iff {t : Nat} :
    (witness K ms ts t).isSome ↔ ∃ t' ∈ ts, dom K ms t' t = true := by
  unfold witness
  rw [Option.isSome_iff_ne_none, ne_eq, pick_eq_none_iff, List.filter_eq_nil_iff]
  simp

theorem dominated_iff {t : Nat} : dominated K ms ts t = true ↔ ∃ t' ∈ ts, dom K ms t' t = true := by
  simp [dominated]

theorem mem_keep {t : Nat} : t ∈ keep K ms ts ↔ t ∈ ts ∧ dominated K ms ts t = false := by
  simp [keep]

/-- The `by` a redundant test names is kept: no test in the suite dominates it. -/
theorem by_kept {t b : Nat} (h : witness K ms ts t = some b) :
    b ∈ keep K ms ts ∧ dom K ms b t = true := by
  obtain ⟨hb, hdom, hbest⟩ := witness_spec h
  refine ⟨mem_keep.mpr ⟨hb, ?_⟩, hdom⟩
  cases hd : dominated K ms ts b
  · rfl
  · obtain ⟨c, hc, hcb⟩ := dominated_iff.mp hd
    have hct : dom K ms c t = true := dom_trans hcb hdom
    have hnot := hbest c hc hct
    obtain ⟨_, hbc, hstrict⟩ := dom_iff.mp hcb
    have hle := count_le_of_sub hbc
    have : better K ms c b = true := by
      simp only [better, decide_eq_true_eq]
      rcases hstrict with hs | hlt
      · exact Or.inl (count_lt_of_strict hbc hs)
      · cases hcb' : sub K ms c b
        · exact Or.inl (count_lt_of_strict hbc hcb')
        · exact Or.inr ⟨Nat.le_antisymm (count_le_of_sub hcb') hle, hlt⟩
    simp [this] at hnot

/-- The `by` is the strongest dominator: no dominator kills more, and on a tie it has the
    smallest id. -/
theorem by_strongest {t b : Nat} (h : witness K ms ts t = some b) :
    ∀ c ∈ ts, dom K ms c t = true →
      count K ms c ≤ count K ms b ∧ (count K ms c = count K ms b → b ≤ c) := by
  obtain ⟨_, _, hbest⟩ := witness_spec h
  intro c hc hd
  have := hbest c hc hd
  simp only [better, decide_eq_false_iff_not] at this
  omega

theorem kept_dominator_exists {t : Nat} (h : ∃ t' ∈ ts, dom K ms t' t = true) :
    ∃ b ∈ keep K ms ts, dom K ms b t = true := by
  obtain ⟨b, hb⟩ := Option.isSome_iff_exists.mp (witness_isSome_iff.mpr h)
  exact ⟨b, (by_kept hb).1, (by_kept hb).2⟩

/-- Dropping every redundant test keeps every kill, so the killed count and the score stay. -/
theorem kept_preserves_killed {m : μ} (hm : m ∈ ms) :
    (∃ t ∈ ts, K t m = true) ↔ ∃ t ∈ keep K ms ts, K t m = true := by
  constructor
  · rintro ⟨t, ht, hk⟩
    cases hd : dominated K ms ts t
    · exact ⟨t, mem_keep.mpr ⟨ht, hd⟩, hk⟩
    · obtain ⟨b, hb, hdom⟩ := kept_dominator_exists (dominated_iff.mp hd)
      exact ⟨b, hb, sub_iff.mp (dom_iff.mp hdom).2.1 m hm hk⟩
  · rintro ⟨t, ht, hk⟩
    exact ⟨t, (mem_keep.mp ht).1, hk⟩

/-- The report never invents a test. -/
theorem kept_sublist : (keep K ms ts).Sublist ts :=
  List.filter_sublist

/-! ## Verdicts -/

theorem verdict_scored {t : Nat} (hc : count K ms t ≠ 0) :
    verdict K ms ts true t =
      match witness K ms ts t with
      | none => .kept
      | some b => if sub K ms b t then .duplicate else .subsumed := by
  simp [verdict, hc]

theorem verdict_redundant_iff {seen : Bool} {t : Nat} :
    (verdict K ms ts seen t = .subsumed ∨ verdict K ms ts seen t = .duplicate) ↔
      seen = true ∧ count K ms t ≠ 0 ∧ ∃ t' ∈ ts, dom K ms t' t = true := by
  constructor
  · intro h
    cases seen
    · simp [verdict] at h
    by_cases hc : count K ms t = 0
    · simp [verdict, hc] at h
    refine ⟨rfl, hc, witness_isSome_iff.mp ?_⟩
    rw [verdict_scored hc] at h
    cases hw : witness K ms ts t with
    | none => rw [hw] at h; simp at h
    | some _ => rfl
  · rintro ⟨rfl, hc, hex⟩
    obtain ⟨b, hw⟩ := Option.isSome_iff_exists.mp (witness_isSome_iff.mpr hex)
    rw [verdict_scored hc, hw]
    cases sub K ms b t <;> simp

theorem verdict_subsumed_iff {seen : Bool} {t : Nat} :
    verdict K ms ts seen t = .subsumed ↔
      seen = true ∧ count K ms t ≠ 0 ∧
        ∃ t' ∈ ts, dom K ms t' t = true ∧ sub K ms t' t = false := by
  constructor
  · intro h
    cases seen
    · simp [verdict] at h
    by_cases hc : count K ms t = 0
    · simp [verdict, hc] at h
    rw [verdict_scored hc] at h
    cases hw : witness K ms ts t with
    | none => rw [hw] at h; simp at h
    | some b =>
      rw [hw] at h
      obtain ⟨hb, hdom, _⟩ := witness_spec hw
      cases hs : sub K ms b t
      · exact ⟨rfl, hc, b, hb, hdom, hs⟩
      · simp [hs] at h
  · rintro ⟨rfl, hc, c, hc', hdc, hsc⟩
    obtain ⟨b, hw⟩ := Option.isSome_iff_exists.mp (witness_isSome_iff.mpr ⟨c, hc', hdc⟩)
    rw [verdict_scored hc, hw]
    obtain ⟨_, hdom, _⟩ := witness_spec hw
    cases hs : sub K ms b t
    · simp [hs]
    · exfalso
      have htb := (dom_iff.mp hdom).2.1
      have htc := (dom_iff.mp hdc).2.1
      have heq : count K ms b = count K ms t :=
        Nat.le_antisymm (count_le_of_sub hs) (count_le_of_sub htb)
      have hlt := count_lt_of_strict htc hsc
      have := (by_strongest hw c hc' hdc).1
      omega

theorem verdict_duplicate {seen : Bool} {t : Nat} (h : verdict K ms ts seen t = .duplicate) :
    ∃ t' ∈ ts, dom K ms t' t = true ∧ sub K ms t' t = true := by
  cases seen
  · simp [verdict] at h
  by_cases hc : count K ms t = 0
  · simp [verdict, hc] at h
  rw [verdict_scored hc] at h
  cases hw : witness K ms ts t with
  | none => rw [hw] at h; simp at h
  | some b =>
    rw [hw] at h
    obtain ⟨hb, hdom, _⟩ := witness_spec hw
    cases hs : sub K ms b t
    · simp [hs] at h
    · exact ⟨b, hb, hdom, hs⟩

/-- The test a redundant verdict names is itself reported `kept`. -/
theorem by_verdict_kept {t b : Nat} (hc : count K ms t ≠ 0) (h : witness K ms ts t = some b) :
    verdict K ms ts true b = .kept := by
  obtain ⟨hkeep, hdom⟩ := by_kept h
  have hnd := (mem_keep.mp hkeep).2
  have hcb : count K ms b ≠ 0 := by
    have := count_le_of_sub (dom_iff.mp hdom).2.1
    omega
  have hnone : witness K ms ts b = none := by
    cases hw : witness K ms ts b with
    | none => rfl
    | some _ =>
      have hsome : (witness K ms ts b).isSome = true := by rw [hw]; rfl
      have := witness_isSome_iff.mp hsome
      rw [← dominated_iff, hnd] at this
      cases this
  simp [verdict, hcb, hnone]

theorem count_pos {t : Nat} {m : μ} (hm : m ∈ ms) (hk : K t m = true) : count K ms t ≠ 0 := by
  intro h
  simp [count_eq_zero_iff.mp h m hm] at hk

theorem unique_not_sub {t t' : Nat} {m : μ} (hm : m ∈ ms) (ht' : t' ∈ ts) (hne : t' ≠ t)
    (hu : unique K ts t m = true) : sub K ms t t' = false := by
  simp only [unique, Bool.and_eq_true, List.all_eq_true, Bool.or_eq_true, beq_iff_eq,
    Bool.not_eq_true'] at hu
  obtain ⟨hk, hall⟩ := hu
  rw [sub_false_iff]
  refine ⟨m, hm, hk, ?_⟩
  rcases hall t' ht' with h | h
  · exact absurd h hne
  · exact h

/-- A test with a unique kill is kept and reported `kept`. -/
theorem unique_kept {t : Nat} {m : μ} (hm : m ∈ ms) (ht : t ∈ ts) (hu : unique K ts t m = true) :
    t ∈ keep K ms ts ∧ verdict K ms ts true t = .kept := by
  have hnd : dominated K ms ts t = false := by
    cases hd : dominated K ms ts t
    · rfl
    · obtain ⟨t', ht', hdom⟩ := dominated_iff.mp hd
      have hne := (dom_iff.mp hdom).1
      have := unique_not_sub hm ht' hne hu
      simp [this, dom] at hdom
  refine ⟨mem_keep.mpr ⟨ht, hnd⟩, ?_⟩
  have hk : K t m = true := by simp [unique] at hu; exact hu.1
  have hnone : witness K ms ts t = none := by
    cases hw : witness K ms ts t with
    | none => rfl
    | some _ =>
      have hsome : (witness K ms ts t).isSome = true := by rw [hw]; rfl
      have := witness_isSome_iff.mp hsome
      rw [← dominated_iff, hnd] at this
      cases this
  simp [verdict, count_pos hm hk, hnone]

/-! ## Completing an incomplete row

`provisional` marks the tests an incomplete row selected. Completing a row `m` that did not
select `t` (and so cannot have `t` among its killers) leaves `t`'s claims standing. -/

section Stable

variable {T : Nat → μ → Bool} {m : μ} {t : Nat}
variable (hT : ∀ s, K s m = true → T s m = true) (hout : T t m = false)

include hT hout in
theorem not_killer_outside : K t m = false := by
  cases hk : K t m
  · rfl
  · simp [hT t hk] at hout

theorem sub_append_left {a b : Nat} :
    sub K (ms ++ [m]) a b = (sub K ms a b && (!K a m || K b m)) := by
  simp [sub, List.all_append]

theorem count_append {s : Nat} :
    count K (ms ++ [m]) s = count K ms s + (if K s m then 1 else 0) := by
  simp [count, List.filter_append, List.filter_cons]
  split <;> simp

include hT hout in
theorem dom_stable_outside {t' : Nat} (h : dom K ms t' t = true) : dom K (ms ++ [m]) t' t = true := by
  have hk := not_killer_outside hT hout
  obtain ⟨hne, hs, hrest⟩ := dom_iff.mp h
  refine dom_iff.mpr ⟨hne, by simp [sub_append_left, hs, hk], ?_⟩
  rcases hrest with h' | h'
  · exact Or.inl (by simp [sub_append_left, h'])
  · exact Or.inr h'

include hT hout in
theorem redundancy_stable_outside :
    (verdict K ms ts true t = .zero → verdict K (ms ++ [m]) ts true t = .zero) ∧
    (verdict K ms ts true t = .subsumed → verdict K (ms ++ [m]) ts true t = .subsumed) ∧
    (verdict K ms ts true t = .duplicate →
      verdict K (ms ++ [m]) ts true t = .subsumed ∨ verdict K (ms ++ [m]) ts true t = .duplicate) := by
  have hk := not_killer_outside hT hout
  have hcount : count K (ms ++ [m]) t = count K ms t := by simp [count_append, hk]
  refine ⟨?_, ?_, ?_⟩
  · intro h
    have hz : count K ms t = 0 := by
      apply Classical.byContradiction
      intro hc
      rw [verdict_scored hc] at h
      cases hw : witness K ms ts t with
      | none => rw [hw] at h; simp at h
      | some b =>
        rw [hw] at h
        cases hs : sub K ms b t <;> simp [hs] at h
    simp [verdict, hcount, hz]
  · intro h
    obtain ⟨_, hc, t', ht', hd, hs⟩ := verdict_subsumed_iff.mp h
    refine verdict_subsumed_iff.mpr ⟨rfl, by omega, t', ht', dom_stable_outside hT hout hd, ?_⟩
    simp [sub_append_left, hs]
  · intro h
    have hred : verdict K ms ts true t = .subsumed ∨ verdict K ms ts true t = .duplicate :=
      Or.inr h
    obtain ⟨_, hc, t', ht', hd⟩ := verdict_redundant_iff.mp hred
    exact verdict_redundant_iff.mpr ⟨rfl, by omega, t', ht', dom_stable_outside hT hout hd⟩

include hT hout in
theorem unique_stable_outside :
    (ms ++ [m]).filter (unique K ts t) = ms.filter (unique K ts t) := by
  have hk := not_killer_outside hT hout
  simp [List.filter_append, unique, hk]

end Stable

/-! ## Dominance inside a group

`g t` is the group of test `t`: its test class under `--kill-matrix-scope=class`, one constant
under `suite`. Only a test of the same group can make `t` redundant, so the grouped verdict is the
suite verdict over `t`'s group, and every theorem above holds group by group. -/

section Grouped

variable (g : Nat → Nat)

def group (ts : List Nat) (t : Nat) : List Nat := ts.filter (fun t' => g t' = g t)

def domG (K : Nat → μ → Bool) (ms : List μ) (t' t : Nat) : Bool :=
  decide (g t' = g t) && dom K ms t' t

def witnessG (K : Nat → μ → Bool) (ms : List μ) (ts : List Nat) (t : Nat) : Option Nat :=
  witness K ms (group g ts t) t

def verdictG (K : Nat → μ → Bool) (ms : List μ) (ts : List Nat) (seen : Bool) (t : Nat) : Kind :=
  verdict K ms (group g ts t) seen t

theorem verdictG_eq_verdict_filter {seen : Bool} {t : Nat} :
    verdictG g K ms ts seen t = verdict K ms (ts.filter (fun t' => g t' = g t)) seen t := rfl

/-- `KillMatrix#dominators` keeps a candidate only when it shares the test's group. -/
theorem dominatedG_iff {t : Nat} :
    dominated K ms (group g ts t) t = true ↔ ∃ t' ∈ ts, domG g K ms t' t = true := by
  rw [dominated_iff]
  simp [group, domG, List.mem_filter, and_assoc]

/-- The `by` a grouped verdict names is in the test's own group. -/
theorem witnessG_same_group {t b : Nat} (h : witnessG g K ms ts t = some b) :
    b ∈ ts ∧ g b = g t := by
  obtain ⟨hb, _, _⟩ := witness_spec h
  simpa [group, List.mem_filter] using hb

/-- Dropping the redundant tests of a group still kills every mutant that group killed. -/
theorem keptG_preserves_killed {m : μ} (hm : m ∈ ms) (c : Nat) :
    (∃ t ∈ ts, g t = c ∧ K t m = true) ↔
      ∃ t ∈ keep K ms (ts.filter (fun t' => g t' = c)), K t m = true := by
  rw [← kept_preserves_killed hm]
  simp [List.mem_filter, and_assoc]

end Grouped

/-! ## First failure and the tail sweep -/

/-- The killers among the ids after the first failure: what the sweep child reports. -/
def sweepTail {α : Type} (p : α → Bool) : List α → List α
  | [] => []
  | a :: rest => if p a then rest.filter p else sweepTail p rest

/-- The first failure plus a sweep of the tail is the whole killer set, so skipping the prefix
    that already passed loses nothing. -/
theorem killers_eq_first_cons_tail {α : Type} (p : α → Bool) :
    ∀ ids : List α, ids.filter p =
      match ids.find? p with
      | none => []
      | some t => t :: sweepTail p ids
  | [] => by simp
  | a :: rest => by
    have ih := killers_eq_first_cons_tail p rest
    cases hp : p a
    · simp [hp, sweepTail, ih]
    · simp [hp, sweepTail]

/-- Running to the first failure and running every test agree on killed versus survived. -/
theorem first_some_iff_filter_nonempty {α : Type} (p : α → Bool) (ids : List α) :
    (ids.find? p).isSome ↔ ids.filter p ≠ [] := by
  rw [killers_eq_first_cons_tail p ids]
  cases ids.find? p <;> simp

/-- The reported `failed_test` is one of the killers. -/
theorem first_mem_filter {α : Type} (p : α → Bool) (ids : List α) (t : α)
    (h : ids.find? p = some t) : t ∈ ids.filter p := by
  rw [killers_eq_first_cons_tail p ids, h]
  exact List.mem_cons_self

end Sabaku.KillMatrix
