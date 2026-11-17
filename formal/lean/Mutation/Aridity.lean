/-
  The aridity rules of `lib/mutation/aridity.rb`.

  `Aridity#arid?` is a recursion over the AST with an ancestor stack:

    arid?(node) =
      suppressed_definition_ancestor?(ancestors)
      || expert_arid?(node, ancestors)
      || (children.empty? ? false : children.all?(lambda c, arid?(c, ancestors + [node])))

  The expert half is a fixed table; call it `base`. The recursive half is the paper's rule, and
  it is what this file owns. The recursion is modelled with an explicit depth bound because a
  Lean structure with a `List` field is a nested inductive, which the `induction` tactic
  rejects. The implementation recurses to the AST's depth, and every theorem below is proved
  for every bound, so each one holds at that depth.
-/

universe u

namespace Mutation.Aridity

/-- An AST node, as far as aridity sees it. `expert` data lives in the `base` parameter. -/
structure Node where
  key : Nat
  children : List Node
  deriving Repr

/-- `Aridity#arid?` up to depth `n`.

    `base ctx t` is the first two `return true` branches of the method:
    `suppressed_definition_ancestor?` and `expert_arid?`. A leaf is arid exactly when `base`
    says so, which is the `return false if children.empty?` branch. A node with children is
    arid when `base` says so or when every child is arid. -/
def arid (base : List Node → Node → Bool) : Nat → List Node → Node → Bool
  | 0, _, _ => false
  | _ + 1, ctx, ⟨k, []⟩ => base ctx ⟨k, []⟩
  | n + 1, ctx, ⟨k, c :: cs⟩ =>
      base ctx ⟨k, c :: cs⟩ || (c :: cs).all (arid base n (ctx ++ [⟨k, c :: cs⟩]))

theorem arid_succ_nil (base : List Node → Node → Bool) (n : Nat) (ctx : List Node) (k : Nat) :
    arid base (n + 1) ctx ⟨k, []⟩ = base ctx ⟨k, []⟩ := rfl

theorem arid_succ_cons (base : List Node → Node → Bool) (n : Nat) (ctx : List Node) (k : Nat)
    (c : Node) (cs : List Node) :
    arid base (n + 1) ctx ⟨k, c :: cs⟩ =
      (base ctx ⟨k, c :: cs⟩ || (c :: cs).all (arid base n (ctx ++ [⟨k, c :: cs⟩]))) := rfl

/-- The recursion has exactly one solution at each depth: any function obeying the same two
    equations is `arid`. This is what makes "the least fixed point of the recursive rule"
    well defined rather than a matter of evaluation order. -/
theorem arid_unique (base : List Node → Node → Bool) (f : Nat → List Node → Node → Bool)
    (hzero : ∀ ctx t, f 0 ctx t = false)
    (hnil : ∀ n ctx k, f (n + 1) ctx ⟨k, []⟩ = base ctx ⟨k, []⟩)
    (hcons : ∀ n ctx k c cs,
      f (n + 1) ctx ⟨k, c :: cs⟩ =
        (base ctx ⟨k, c :: cs⟩ || (c :: cs).all (f n (ctx ++ [⟨k, c :: cs⟩])))) :
    ∀ n ctx t, f n ctx t = arid base n ctx t := by
  intro n
  induction n with
  | zero => intro ctx t; rw [hzero]; rfl
  | succ n ih =>
      intro ctx t
      obtain ⟨k, cs⟩ := t
      cases cs with
      | nil => rw [hnil]; rfl
      | cons c cs =>
          rw [hcons, arid_succ_cons]
          congr 1
          apply List.all_congr rfl
          intro x
          exact ih _ x

/-- The ancestor stack is only ever tested with `any`, in `suppressed_definition_ancestor?` and
    in the `reverse_each` scan of `argument_of_arid_call?`, and a Boolean `any` does not see
    order. -/
theorem any_perm {α : Type u} (p : α → Bool) {l₁ l₂ : List α} (h : l₁.Perm l₂) :
    l₁.any p = l₂.any p := by
  induction h with
  | nil => rfl
  | cons x _ ih => simp [ih]
  | swap x y l => simp [Bool.or_left_comm]
  | trans _ _ ih₁ ih₂ => rw [ih₁, ih₂]

/-- The shape of `Aridity#expert_arid?` and `suppressed_definition_ancestor?` together: two
    ancestor scans plus a node-local verdict. -/
def baseOf (isSuppressedDef : Node → Bool) (isAridCall : Node → Bool)
    (expert : Node → Bool) (ctx : List Node) (n : Node) : Bool :=
  ctx.any isSuppressedDef || ctx.any isAridCall || expert n

/-- A base predicate that only scans ancestors cannot see their order. -/
def BasePermInvariant (base : List Node → Node → Bool) : Prop :=
  ∀ (ctx₁ ctx₂ : List Node) (n : Node), ctx₁.Perm ctx₂ → base ctx₁ n = base ctx₂ n

theorem baseOf_perm (isSuppressedDef isAridCall expert : Node → Bool) :
    BasePermInvariant (baseOf isSuppressedDef isAridCall expert) := by
  intro ctx₁ ctx₂ n h
  simp only [baseOf]
  rw [any_perm isSuppressedDef h, any_perm isAridCall h]

/-- The aridity verdict does not depend on the order of the ancestor stack. The implementation
    builds the stack with `ancestors + [node]` and scans it with `reverse_each`, so this is the
    property that keeps the two from disagreeing. -/
theorem arid_perm (base : List Node → Node → Bool) (hb : BasePermInvariant base) :
    ∀ (n : Nat) (ctx₁ ctx₂ : List Node) (t : Node),
      ctx₁.Perm ctx₂ → arid base n ctx₁ t = arid base n ctx₂ t := by
  intro n
  induction n with
  | zero => intro ctx₁ ctx₂ t _; rfl
  | succ n ih =>
      intro ctx₁ ctx₂ t h
      obtain ⟨k, cs⟩ := t
      cases cs with
      | nil => rw [arid_succ_nil, arid_succ_nil, hb ctx₁ ctx₂ _ h]
      | cons c cs =>
          rw [arid_succ_cons, arid_succ_cons, hb ctx₁ ctx₂ _ h]
          congr 1
          apply List.all_congr rfl
          intro x
          exact ih _ _ x (List.Perm.append_right _ h)

/-- Adding an expert rule can only make more nodes arid, never fewer. -/
theorem arid_mono (b₁ b₂ : List Node → Node → Bool)
    (h : ∀ (ctx : List Node) (t : Node), b₁ ctx t = true → b₂ ctx t = true) :
    ∀ (n : Nat) (ctx : List Node) (t : Node),
      arid b₁ n ctx t = true → arid b₂ n ctx t = true := by
  intro n
  induction n with
  | zero => intro ctx t hh; simp [arid] at hh
  | succ n ih =>
      intro ctx t hh
      obtain ⟨k, cs⟩ := t
      cases cs with
      | nil =>
          rw [arid_succ_nil] at hh ⊢
          exact h ctx ⟨k, []⟩ hh
      | cons c cs =>
          simp only [arid_succ_cons, Bool.or_eq_true, List.all_eq_true] at hh ⊢
          rcases hh with hb | hall
          · exact Or.inl (h ctx _ hb)
          · exact Or.inr (fun x hx => ih _ x (hall x hx))

/-- A node is inside its own subtree. -/
inductive Subtree : Node → Node → Prop where
  | refl (t : Node) : Subtree t t
  | step {t c x : Node} (hc : c ∈ t.children) (h : Subtree c x) : Subtree t x

/-- `Analyzer#walk`: stop at an arid node, otherwise emit the node and descend. -/
def walk (base : List Node → Node → Bool) : Nat → List Node → Node → List Node
  | 0, _, _ => []
  | n + 1, ctx, t@⟨_, cs⟩ =>
      if arid base (n + 1) ctx t then [] else t :: cs.flatMap (walk base n (ctx ++ [t]))

/-- An arid node contributes no mutant, and neither does anything below it. -/
theorem walk_pruned (base : List Node → Node → Bool) (n : Nat) (ctx : List Node) (t : Node)
    (h : arid base (n + 1) ctx t = true) : walk base (n + 1) ctx t = [] := by
  obtain ⟨k, cs⟩ := t
  simp [walk, h]

/-- A node the rules leave alone is emitted by the walk. -/
theorem walk_emits (base : List Node → Node → Bool) (n : Nat) (ctx : List Node) (t : Node)
    (h : arid base (n + 1) ctx t = false) : t ∈ walk base (n + 1) ctx t := by
  obtain ⟨k, cs⟩ := t
  simp [walk, h]

/-- The walk never invents a node: everything it emits is in the subtree it was given. -/
theorem walk_subtree (base : List Node → Node → Bool) :
    ∀ (n : Nat) (ctx : List Node) (t x : Node), x ∈ walk base n ctx t → Subtree t x := by
  intro n
  induction n with
  | zero => intro ctx t x hx; simp [walk] at hx
  | succ n ih =>
      intro ctx t x hx
      obtain ⟨k, cs⟩ := t
      by_cases har : arid base (n + 1) ctx ⟨k, cs⟩ = true
      · simp [walk, har] at hx
      · have hne : arid base (n + 1) ctx ⟨k, cs⟩ = false := by
          cases hv : arid base (n + 1) ctx ⟨k, cs⟩ <;> simp_all
        have hh : x ∈ (⟨k, cs⟩ : Node) :: cs.flatMap (walk base n (ctx ++ [⟨k, cs⟩])) := by
          simpa [walk, hne] using hx
        simp only [List.mem_cons] at hh
        rcases hh with rfl | hx'
        · exact Subtree.refl _
        · rw [List.mem_flatMap] at hx'
          obtain ⟨y, hy, hxy⟩ := hx'
          exact Subtree.step hy (ih _ y x hxy)

end Mutation.Aridity
