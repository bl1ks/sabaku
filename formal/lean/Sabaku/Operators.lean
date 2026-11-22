/-
  The operator tables of `lib/sabaku/operators/`, as images of one token.

  Each operator rewrites one token or one statement of the node's source text. The properties
  proved here are the ones the campaign depends on: the image never contains the original (a
  mutant that does not change the file would be unkillable), the image is exhaustive over the
  other tokens (nothing is silently left out), and the relational and connector bool
  replacements cannot both fire on one node.
-/

namespace Sabaku.Operator

/-- `Aor::OPERATORS`. -/
inductive Arith where
  | add | sub | mul | div | mod
  deriving DecidableEq, Repr

def Arith.token : Arith → String
  | add => "+" | sub => "-" | mul => "*" | div => "/" | mod => "%"

def Arith.all : List Arith := [add, sub, mul, div, mod]

/-- `lib/sabaku/operators/aor.rb`: every other arithmetic operator. -/
def aorImage (a : Arith) : List Arith := Arith.all.filter (· ≠ a)

theorem aor_length (a : Arith) : (aorImage a).length = 4 := by
  cases a <;> decide

theorem aor_no_identity (a : Arith) : a ∉ aorImage a := by
  cases a <;> decide

theorem aor_complete (a b : Arith) (h : b ≠ a) : b ∈ aorImage a := by
  cases a <;> cases b <;> simp_all [aorImage, Arith.all]

theorem aor_token_changed (a b : Arith) (h : b ∈ aorImage a) :
    Arith.token b ≠ Arith.token a := by
  cases a <;> cases b <;> simp_all [aorImage, Arith.all, Arith.token]

/-- `Ror::RELATIONAL`. -/
inductive Rel where
  | eq | ne | gt | ge | lt | le
  deriving DecidableEq, Repr

def Rel.token : Rel → String
  | eq => "==" | ne => "!=" | gt => ">" | ge => ">=" | lt => "<" | le => "<="

def Rel.all : List Rel := [eq, ne, gt, ge, lt, le]

/-- `lib/sabaku/operators/ror.rb`: the five other relational forms, plus true and false. -/
def rorImage (r : Rel) : List String :=
  (Rel.all.filter (· ≠ r)).map Rel.token ++ ["true", "false"]

theorem ror_length (r : Rel) : (rorImage r).length = 7 := by
  cases r <;> decide

theorem ror_no_identity (r : Rel) : Rel.token r ∉ rorImage r := by
  cases r <;> decide

theorem ror_complete (r s : Rel) (h : s ≠ r) : Rel.token s ∈ rorImage r := by
  cases r <;> cases s <;> simp_all [rorImage, Rel.all, Rel.token]

theorem ror_bool_not_relational : "true" ∉ Rel.all.map Rel.token := by decide

/-- `Lcr::CONNECTORS`. -/
inductive Conn where
  | andand | oror | and | or | amp | pipe
  deriving DecidableEq, Repr

def Conn.token : Conn → String
  | andand => "&&" | oror => "||" | and => "and" | or => "or" | amp => "&" | pipe => "|"

def Conn.swap : Conn → Conn
  | andand => oror | oror => andand
  | and => or | or => and
  | amp => pipe | pipe => amp

theorem lcr_swap_ne (c : Conn) : Conn.swap c ≠ c := by
  cases c <;> decide

theorem lcr_swap_involution (c : Conn) : Conn.swap (Conn.swap c) = c := by
  cases c <;> rfl

theorem conn_token_injective : Function.Injective Conn.token := by
  intro a b h
  cases a <;> cases b <;> first | rfl | simp_all [Conn.token]

theorem lcr_token_changed (c : Conn) : Conn.token (Conn.swap c) ≠ Conn.token c := by
  intro h
  exact lcr_swap_ne c (conn_token_injective h)

/-- Relational and connector tokens are disjoint, so one `CallNode` can carry at most one of
    them. A `CallNode` is offered to both `Ror` and `Lcr`, and both can emit `true`/`false`; the
    mutant id ignores the operator, so two such mutants at one span would collapse to one. -/
theorem ror_lcr_tokens_disjoint (r : Rel) (c : Conn) : Rel.token r ≠ Conn.token c := by
  cases r <;> cases c <;> decide

/-- `Sbr::DECLARATION_CONTAINERS`, plus the containers the statement list can sit in. -/
inductive Container where
  | program | klass | mod | singletonClass | defn | other
  deriving DecidableEq, Repr

def Container.isDeclaration : Container → Bool
  | program => true | klass => true | mod => true | singletonClass => true
  | defn => false | other => false

/-- `Sbr.removable_indices`, including the `statements.length < 2` guard in `Sbr.mutations`.

    For a def body the code slices `[0...-1]`; `List.range (n - 1)` is the same list. -/
def removableIndices (c : Container) (n : Nat) : List Nat :=
  if n < 2 then []
  else if c.isDeclaration then []
  else if c = Container.defn then List.range (n - 1)
  else List.range n

/-- Ruby then filters with `pinned_by_sig?`. The filter only removes indices; it never adds. -/
def removableIndicesPinned (c : Container) (n : Nat) (pinned : Nat → Bool) : List Nat :=
  (removableIndices c n).filter (fun i => !(pinned i))

theorem sbr_declaration_none (c : Container) (h : c.isDeclaration = true) (n : Nat) :
    removableIndices c n = [] := by
  unfold removableIndices
  by_cases hn : n < 2 <;> simp [hn, h]

theorem sbr_defn_last_kept (n : Nat) (hn : 2 ≤ n) :
    n - 1 ∉ removableIndices Container.defn n := by
  have h2 : ¬ n < 2 := by omega
  have hdecl : Container.defn.isDeclaration = false := by decide
  unfold removableIndices
  simp [h2, hdecl, List.mem_range]

theorem sbr_other_last_removable (n : Nat) (hn : 2 ≤ n) :
    n - 1 ∈ removableIndices Container.other n := by
  have h2 : ¬ n < 2 := by omega
  have hdecl : Container.other.isDeclaration = false := by decide
  have hne : Container.other ≠ Container.defn := by decide
  unfold removableIndices
  simp [h2, hdecl, hne, List.mem_range]
  omega

theorem sbr_index_lt (c : Container) (n i : Nat) (h : i ∈ removableIndices c n) : i < n := by
  unfold removableIndices at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · split at h <;> simp_all [List.mem_range] <;> try omega

theorem sbr_nonempty (c : Container) (n : Nat) (hn : 2 ≤ n) (hc : c.isDeclaration = false) :
    1 ≤ (removableIndices c n).length := by
  unfold removableIndices
  have h2 : ¬ n < 2 := by omega
  split
  · simp only [List.length_nil]
    omega
  · split
    · simp_all
    · split <;> simp [List.length_range] <;> omega

theorem sbr_pinned_subset (c : Container) (n : Nat) (pinned : Nat → Bool) :
    ∀ i, i ∈ removableIndicesPinned c n pinned → i ∈ removableIndices c n := by
  intro i h
  simp [removableIndicesPinned, List.mem_filter] at h
  exact h.1

/-- `Uoi.negation_mutations`: the replacement is the receiver's text with the `!` dropped. -/
def bang (p : List UInt8) : List UInt8 := [33] ++ p

theorem uoi_strip_changes (p : List UInt8) : p ≠ bang p := by
  intro h
  have hl := congrArg List.length h
  simp [bang] at hl
  try omega

/-- `Uoi.predicate_mutations`: `!(pred)` around the same predicate. -/
def bangWrap (p : List UInt8) : List UInt8 := [33, 40] ++ p ++ [41]

theorem uoi_wrap_changes (p : List UInt8) : p ≠ bangWrap p := by
  intro h
  have hl := congrArg List.length h
  simp [bangWrap] at hl
  try omega

/-- `Bool.mutations`: true becomes false and false becomes true. -/
inductive Lit where
  | t | f
  deriving DecidableEq, Repr

def Lit.flip : Lit → Lit
  | t => f | f => t

theorem bool_flip_ne (b : Lit) : Lit.flip b ≠ b := by
  cases b <;> decide

theorem bool_flip_involution (b : Lit) : Lit.flip (Lit.flip b) = b := by
  cases b <;> rfl

/-- `Str.mutations`: the replacement is `""`, and the operator only fires on a literal the
    parser says is non-empty. -/
theorem str_replacement_ne (s : List UInt8) (h : s ≠ []) : ([] : List UInt8) ≠ s :=
  fun e => h e.symm

/-- `Assign::NODES`' operator tokens. The replacement is the plain `=`. -/
def assignTokens : List String :=
  ["+=", "-=", "*=", "/=", "%=", "**=", "||=", "&&=", "|=", "&=", "^=", "<<=", ">>="]

theorem assign_eq_not_mem : ("=" : String) ∉ assignTokens := by decide

theorem assign_no_identity (t : String) (h : t ∈ assignTokens) : ("=" : String) ≠ t := by
  intro he
  exact assign_eq_not_mem (he ▸ h)

/-- `Cond.mutations`: the predicate text becomes `true` and `false`, and the analyzer drops an
    identity rewrite (`if true` would otherwise mutate to itself). -/
def condImage (predicate : String) : List String := ["true", "false"].filter (· ≠ predicate)

theorem cond_no_identity (p : String) : p ∉ condImage p := by
  simp [condImage]

theorem cond_length (p : String) (ht : p ≠ "true") (hf : p ≠ "false") :
    (condImage p).length = 2 := by
  simp [condImage, Ne.symm ht, Ne.symm hf]

/-- `Literal.integer_mutations`: both neighbours, and neither is the original. -/
def intImage (n : Int) : List Int := [n + 1, n - 1]

theorem int_no_identity (n : Int) : n ∉ intImage n := by
  simp [intImage]
  omega

theorem int_length (n : Int) : (intImage n).length = 2 := by
  simp [intImage]

/-- `Analyzer#walk`: a candidate whose replacement text equals the source slice it replaces is
    dropped before it becomes a mutant. This is the guard that keeps `selector`, `call`, `cond`,
    and `literal` from emitting an unkillable no-op when a rewrite happens to reproduce its
    input, and it is modelled as part of emission rather than as a property of each table. -/
def emitted (original : String) (image : List String) : List String :=
  image.filter (· ≠ original)

theorem emitted_no_identity (original : String) (image : List String) :
    original ∉ emitted original image := by
  simp [emitted]

/-- `Control.mutations`: `break` becomes `next` and `next` becomes `break`. -/
inductive LoopControl where
  | breakOp | nextOp
  deriving DecidableEq, Repr

def LoopControl.token : LoopControl → String
  | breakOp => "break" | nextOp => "next"

def LoopControl.swap : LoopControl → LoopControl
  | breakOp => nextOp | nextOp => breakOp

theorem control_swap_ne (c : LoopControl) : LoopControl.swap c ≠ c := by
  cases c <;> decide

theorem control_token_changed (c : LoopControl) :
    LoopControl.token (LoopControl.swap c) ≠ LoopControl.token c := by
  cases c <;> decide

/-- `Return.mutations`: the last expression of a method body becomes `nil`. The
    operator skips a body that already ends in `nil`, which is the no-op guard
    applied where the table lives. -/
def returnImage (original : String) : Option String :=
  if original = "nil" then none else some "nil"

theorem return_no_identity (original : String) :
    returnImage original ≠ some original := by
  unfold returnImage
  split
  · simp
  · rename_i h
    simp [Ne.symm h]

theorem return_skips_nil : returnImage "nil" = none := by decide

end Sabaku.Operator
