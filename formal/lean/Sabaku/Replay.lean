/-
  A second implementation of the operations the campaign relies on: `Mutant#splice`,
  `Report#score` and `KillMatrix#verdicts`. `formal/replay/emit.rb` writes one tab separated
  record per case, and this program decides each one independently of Ruby. A mismatch is a
  failure.
-/

import Sabaku.Basic
import Sabaku.Score
import Sabaku.KillMatrix

open Sabaku

namespace Sabaku.Replay

/-- "9,9" -> [9, 9]. Empty field means empty bytes. -/
def parseBytes (s : String) : Option Bytes :=
  if s.isEmpty then
    some []
  else
    (s.splitOn ",").mapM (fun x => String.toNat? x) |>.map (fun l => l.map UInt8.ofNat)

def showBytes (b : Bytes) : String :=
  String.intercalate "," (b.map (fun x => toString x.toNat))

/-- The score as tenths of a percent, matching `Report#score_pct` and the terminal's `%5.1f`.
    The zero-denominator case is `Report#score`'s `return 0.0`. The count grid avoids exact
    halves, where Float#round and this integer half-up could differ. -/
def scoreTenths (killed survived timeout : Nat) : Nat :=
  let den := killed + survived + timeout
  if den = 0 then 0 else (killed * 1000 + den / 2) / den

def checkSplice (s e txt repl want : String) : IO Bool := do
  match parseBytes txt, parseBytes repl, parseBytes want, String.toNat? s, String.toNat? e with
  | some t, some r, some w, some so, some eo => do
      let m : Mutant := ⟨so, eo, r⟩
      let got := splice t m
      if got = w then
        IO.println s!"ok splice {s} {e}"
        return true
      else
        IO.println s!"MISMATCH splice {s} {e}: got [{showBytes got}] want [{showBytes w}]"
        return false
  | _, _, _, _, _ => do
      IO.println s!"MISMATCH splice {s} {e}: unparseable record"
      return false

def checkScore (killed survived timeout uncovered err want : String) : IO Bool := do
  match String.toNat? killed, String.toNat? survived, String.toNat? timeout,
        String.toNat? uncovered, String.toNat? err, String.toNat? want with
  | some k, some s, some t, some _u, some _e, some w => do
      let got := scoreTenths k s t
      if got = w then
        IO.println s!"ok score {k} {s} {t}"
        return true
      else
        IO.println s!"MISMATCH score {k} {s} {t}: got {got} want {w}"
        return false
  | _, _, _, _, _, _ => do
      IO.println s!"MISMATCH score {killed} {survived} {timeout}: unparseable record"
      return false

def parseNats (s : String) : Option (List Nat) :=
  if s.isEmpty then some [] else (s.splitOn ",").mapM String.toNat?

def parseFields (s : String) : List String :=
  if s.isEmpty then [] else s.splitOn ";"

/-- "0,1/1" -> tested [0, 1], killers [1]. -/
def parseRow (s : String) : Option (List Nat × List Nat) :=
  match s.splitOn "/" with
  | [tested, killers] => do pure (← parseNats tested, ← parseNats killers)
  | _ => none

def kindName : KillMatrix.Kind → String
  | .kept => "kept"
  | .subsumed => "subsumed"
  | .duplicate => "duplicate"
  | .zero => "zero"
  | .idle => "idle"

/-- One `kind,by,unique` per test, in id order, as `KillMatrix#verdicts` lists them. `groups`
    gives each test's class; dominance holds only inside one. -/
def matrixTable (n : Nat) (groups : List Nat) (rows : List (List Nat × List Nat))
    (inc : List (List Nat)) : String :=
  let K : Nat → Nat → Bool := fun t m => (rows.getD m ([], [])).2.contains t
  let g : Nat → Nat := fun t => groups.getD t 0
  let ms := List.range rows.length
  let ts := List.range n
  let seen := fun t => rows.any (fun r => r.1.contains t) || inc.any (fun r => r.contains t)
  String.intercalate ";" <| ts.map fun t =>
    let kind := KillMatrix.verdictG g K ms ts (seen t) t
    let named := match kind, KillMatrix.witnessG g K ms ts t with
      | .subsumed, some b => toString b
      | .duplicate, some b => toString b
      | _, _ => "-"
    let uniq := (ms.filter (KillMatrix.unique K ts t)).length
    s!"{kindName kind},{named},{uniq}"

def checkMatrix (n groupsField rowsField incField want : String) : IO Bool := do
  match String.toNat? n, parseNats groupsField, (parseFields rowsField).mapM parseRow,
        (parseFields incField).mapM parseNats with
  | some n, some groups, some rows, some inc => do
      let got := matrixTable n groups rows inc
      if got = want then
        IO.println s!"ok matrix {n} {rows.length}"
        return true
      else
        IO.println s!"MISMATCH matrix [{rowsField}] [{incField}]: got [{got}] want [{want}]"
        return false
  | _, _, _, _ => do
      IO.println s!"MISMATCH matrix: unparseable record"
      return false

def handle (line : String) : IO Bool :=
  match line.splitOn "\t" with
  | ["splice", s, e, txt, repl, want] => checkSplice s e txt repl want
  | ["score", k, s, t, u, e, want] => checkScore k s t u e want
  | ["matrix", n, groups, rows, inc, want] => checkMatrix n groups rows inc want
  | _ => do
      IO.println s!"MISMATCH: unrecognised record [{line}]"
      return false

def main : IO UInt32 := do
  let input ← (← IO.getStdin).readToEnd
  let mut ok := 0
  let mut bad := 0
  for line in input.splitOn "\n" do
    if line.isEmpty then
      pure ()
    else if ← handle line then
      ok := ok + 1
    else
      bad := bad + 1
  IO.println s!"replay: {ok} ok, {bad} mismatch"
  return if bad = 0 then (0 : UInt32) else 1

end Sabaku.Replay

def main : IO UInt32 := Sabaku.Replay.main
