/-
  The operator tables of `lib/mutation/operators/`, as images of one token.

  Each operator rewrites one token or one statement of the node's source text. The properties
  proved here are the ones the campaign depends on: the image never contains the original (a
  mutant that does not change the file would be unkillable), the image is exhaustive over the
  other tokens (nothing is silently left out), and the relational and connector bool
  replacements cannot both fire on one node.
-/

namespace Mutation.Operator

/-- `Aor::OPERATORS`. -/
inductive Arith where
  | add | sub | mul | div | mod
  deriving DecidableEq, Repr

def Arith.token : Arith → String
  | add => "+" | sub => "-" | mul => "*" | div => "/" | mod => "%"

def Arith.all : List Arith := [add, sub, mul, div, mod]

/-- `lib/mutation/operators/aor.rb`: every other arithmetic operator. -/
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

/-- `lib/mutation/operators/ror.rb`: the five other relational forms, plus true and false. -/
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

end Mutation.Operator
