/-
  The result cache of `lib/mutation/cache.rb` and `lib/mutation/runner.rb`.

  The cache is a key to entry map. The runner writes only the two statuses whose outcome it can
  reproduce (`persist_results`), while the reader accepts four (`KnownStatuses` minus
  `uncovered`). That gap is proven here, not assumed away.
-/

namespace Mutation.Cache

inductive Status where
  | killed | survived | timeout | error | uncovered
  deriving DecidableEq, Repr

/-- `Runner#persist_results`: killed and survived are the only statuses written. -/
def cacheable : Status → Bool
  | .killed | .survived => true
  | .timeout | .error | .uncovered => false

/-- `Cache::KNOWN_STATUSES` minus `uncovered`, which `fetch` rejects. -/
def fetchable : Status → Bool
  | .killed | .survived | .timeout | .error => true
  | .uncovered => false

abbrev Store := String → Option Status

/-- `Cache#fetch`. -/
def fetch (store : Store) (key : String) : Option Status :=
  match store key with
  | some .killed => some .killed
  | some .survived => some .survived
  | some .timeout => some .timeout
  | some .error => some .error
  | _ => none

/-- `Cache#store`: last write wins. -/
def store (cache : Store) (key : String) (s : Status) : Store :=
  fun k => if k = key then some s else cache k

theorem store_self (cache : Store) (key : String) (s : Status) :
    store cache key s key = some s := by
  simp [store]

/-- The reader never returns `uncovered`, so an entry written for an uncovered mutant cannot
    come back as a result. -/
theorem fetch_never_uncovered (cache : Store) (key : String) :
    fetch cache key ≠ some Status.uncovered := by
  unfold fetch
  split <;> simp

/-- A written entry is read back only when the reader accepts its status. -/
theorem fetch_store (cache : Store) (key : String) (s : Status) :
    fetch (store cache key s) key = if fetchable s then some s else none := by
  cases s <;> simp [store, fetch, fetchable]

/-- The statuses the runner writes are all statuses the reader accepts, so a campaign reads
    back what it wrote. -/
theorem store_roundtrip (cache : Store) (key : String) (s : Status)
    (h : cacheable s = true) : fetch (store cache key s) key = some s := by
  have hf : fetchable s = true := by
    cases s <;> simp_all [cacheable, fetchable]
  rw [fetch_store]
  simp [hf]

theorem cacheable_fetchable (s : Status) (h : cacheable s = true) : fetchable s = true := by
  cases s <;> simp_all [cacheable, fetchable]

/-- The reader accepts two statuses the writer never produces. A cache file that this code
    did not write can therefore report a `timeout` or an `error` with duration zero. -/
theorem reader_accepts_more :
    fetchable Status.timeout = true ∧ cacheable Status.timeout = false ∧
      fetchable Status.error = true ∧ cacheable Status.error = false := by
  decide

/-- `Cache::FORMAT_VERSION`. Bumped to 2 when the key grew a campaign fingerprint: an entry
    keyed without the test tree and the setup cannot answer the question the next campaign asks. -/
def FORMAT_VERSION : Nat := 2

/-- `Cache#load_entries`: the entries of a file with the current format version, and an empty
    cache for anything else. -/
def load (version : Nat) (entries : Store) : Store :=
  if version = FORMAT_VERSION then entries else fun _ => none

theorem load_current (entries : Store) : load FORMAT_VERSION entries = entries := by
  simp [load]

theorem load_unknown (version : Nat) (h : version ≠ FORMAT_VERSION) (entries : Store) :
    load version entries = fun _ => none := by
  simp [load, h]

end Mutation.Cache
