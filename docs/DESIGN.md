# sabaku design contract

Every subagent codes against this file. Deviations are surfaced, not absorbed.

The paper this engine started from is Petrovic & Ivankovic, "State of Mutation Testing at Google"
(ICSE-SEIP 2018). It is provenance now, not a constraint. The engine keeps what pays for itself
(diff filtering, coverage selection, aridity) and replaces what does not: the random per-line
pick, offset-derived identity, and the assumption that a survivor needs a child process.

## What survives from the paper

| Paper | This library | Where |
| --- | --- | --- |
| Mutants on changed lines only (diff-based) | `--diff` / `Config#diff_ranges` filters mutants by line | `Analyzer` |
| Lines without statement coverage are not mutated | mutant without a covering test is `:uncovered`, never run | `Runner` |
| Arid nodes are suppressed (expert() on simple nodes, recursive AND on compound) | `Aridity#arid?(node, ancestors)` with Ruby rules | `lib/sabaku/aridity.rb` |
| At most one mutant per line | the line spends its budget on the most productive operator first, with no random draw | `Analyzer`, `Registry::PRODUCTIVITY` |
| Operators AOR, LCR, ROR, SBR, UOI | same ids, Ruby semantics, plus nine Ruby-shaped operators | `lib/sabaku/operators/` |
| Mutant killed / living, test target per file | `:killed` / `:survived`, `CoverageMap#tests_for` | `Runner`, `adapters/` |

## What replaces the paper

| Idea | This library | Where |
| --- | --- | --- |
| A mutant's identity outlives its position | id = sha1(path, scope, AST path, operator, replacement) | `Mutant#id` |
| A line's budget goes to the operators that survive most | fixed productivity order, earliest offset as the tie break | `Registry::PRODUCTIVITY` |
| A survivor is only as strong as what a test observed | the weak pass records `:not_infected` without running a child | `Weak`, `CoverageSampler`, `Runner` |

## Data shapes

These are the core types. Every value object is frozen and `#to_h`-able so the report and the
JSON cache never need a second conversion path.

```ruby
# lib/sabaku/config.rb
Config = Data.define(
  :paths,        # Array[String] files or globs to mutate
  :exclude,      # Array[String] globs
  :operators,    # Array[Symbol] enabled operator ids
  :jobs,         # Integer >= 1
  :timeout,      # Float seconds per mutant
  :per_line,     # Integer (default 1) or Float::INFINITY for `--per-line=all`
  :diff_ranges,  # Hash[String => Array[Range]], nil when mutating whole files
  :coverage,     # Boolean, test selection on/off
  :isolation,    # Symbol, :fork | :process
  :report,       # Symbol, :terminal | :json | :quiet
  :output,       # String path | nil
  :env,          # Hash[String => String], set before the suite loads
  :requires,     # Array[String], required after Coverage.start, before the tests
  :setup,        # Sabaku::Setup | nil, the --setup hooks
  :setup_path,   # String | nil, the file the setup came from (process isolation)
  :fail_fast,    # Boolean, stop at the first survivor
  :baseline,     # Boolean, refuse to score a suite that is not green and re-check kills
  :weak,         # Boolean, run the dry-run probe pass
  :kill_matrix,  # Boolean, sweep every killed mutant's selection
  :kill_matrix_scope, # Symbol, :class | :suite, where one test can make another redundant
  :test_globs    # Array[String], test files to load; [] means test/**/*_test.rb
)
Config.default(**overrides) -> Config

# lib/sabaku/source.rb
Source.new(rel_path, text)
  #rel_path    -> String, path relative to the project root
  #text        -> String (frozen)
  #ast         -> Prism::Node (root, parsed once)
  #line_of(offset) -> Integer
  #slice(node) -> String, exactly node.location.slice
  flat_nodes  -> Enumerator[Prism::Node] (preorder, excluding the root)

# lib/sabaku/mutant.rb
Mutant = Data.define(:id, :path, :operator, :line, :column, :node_kind, :original,
                     :replacement, :start_offset, :end_offset, :scope, :ast_path, :weak)
  #id          String, stable: sha1("path\0scope\0ast_path\0operator\0replacement")[0, 16]
  #scope       String, e.g. "top::Shop::Pricing#total"; the nearest def with its owners
  #ast_path    String, child-index path inside the scope, e.g. "1/0/2"
  #weak        Boolean, the analyzer found the rewrite safe to probe
  #line        1-based line number of node start
  #column      0-based byte column of node start
  #node_kind   String, Prism node type, e.g. "CallNode"
  #original    String, exact source slice being replaced
  #replacement String, replacement source text
  #description String, e.g. "AOR: 4 + 5 -> 4 - 5"
  #to_h        Hash
Mutant#splice(text) -> String   # text with [start_offset, end_offset) replaced
Mutant#key -> Array             # [path, scope, ast_path, operator, replacement]
Mutant#start_offset, #end_offset  Integers into the source
```

`Mutant` carries its own offsets because the offsets must survive a round trip through the JSON
cache, but they are not part of the id: a method that moves keeps its cache entries. `splice`
never re-parses.

```ruby
# lib/sabaku/operators/registry.rb
# An operator is a module with three methods.
Operator.id           -> Symbol                 # see Registry.ids above
Operator.node_types   -> Array[Class]           # Prism node classes it applies to
Operator.mutations(node, source) -> Array[Replacement]
Replacement = Data.define(:original, :replacement)
# `original` must be `source.slice(node)` exactly; the Analyzer verifies this before emitting
# a Mutant and raises on mismatch, so a bad operator fails loudly instead of producing a no-op.

Operator::Registry.ids -> Array[Symbol]         # :aor :ror :lcr :sbr :uoi :bool :str
                                                # :literal :selector :call :cond :assign
                                                # :return :control
Operator::Registry.fetch(id) -> Operator
Operator::Registry.defaults -> Array[Symbol]    # every id above; depth is --per-line
Operator::Registry.rank(id) -> Integer          # index in PRODUCTIVITY; unknown ids sort last
```

```ruby
# lib/sabaku/aridity.rb
Aridity.new #arid?(node, ancestors) -> Boolean
# simple node: expert(node, ancestors)
# compound node: all children arid (recursive, per paper equation 1)
```

```ruby
# lib/sabaku/analyzer.rb
Analyzer.new(sources, config) #each -> Enumerator[Mutant]
Analyzer.new(...).mutants     -> Array[Mutant]  # deterministic order: path, offset, operator
```

The walk threads two coordinates down the tree: `scope` (the nearest `def`, qualified by its
class and module owners) and `ast_path` (child indices from the scope's first child). A mutant
anchored on a `def` line belongs to the scope that contains the `def`, not to the new one.

Per line, candidates sort by `Registry.rank`, then `start_offset`, then operator name, then
replacement. The line keeps the first `per_line` candidates that re-parse. There is no draw and
no seed: the same code always keeps the same mutants.

```ruby
# lib/sabaku/weak.rb
Weak.reset!                       # clears the runtime state before a dry run
Weak.eligible?(operator, node)    # Boolean: pure operands, a rewritable value
Weak.instrument(source, mutants)  # -> [probed_text, Array[Probe]] | nil
Weak.apply(text, probes)          # splices the probe calls into text
Weak.report                       # -> Report(seen:, infected:)
Report#decision(mutant, selected_ids) -> :not_infected | :infected | :unknown
```

A probe wraps one expression and every mutant of that expression:

```ruby
::Sabaku::Weak.evaluate((a - b), [["id1", -> { (a + b) }], ["id2", -> { (a * b) }]])
```

`evaluate` returns the original value, so the pass cannot change behaviour. It records `seen`
for every selected test that evaluated the expression and `infected` for every form whose value
differed or raised. `:unknown` means the probe is missing or a selected test never evaluated the
expression, and the mutant must run.

Only pure expressions are probed: literals, local and ivar reads, `self`, constants,
parenthesised pure expressions, and binary or logical nodes of those. A method call on a local
(`a.size`) stays off the list because nothing proves it is free of side effects.

```ruby
# lib/sabaku/coverage_map.rb
CoverageMap.empty
CoverageMap#record(test_id, hits)         # hits: Hash[path => Array[Integer] | Set[Integer]]
CoverageMap#tests_for(path, line)         -> Array[String] sorted
CoverageMap#merge(other)                  -> CoverageMap
CoverageMap#to_h / .from_h                # JSON round trip, "files" only when described
CoverageMap#describe(file) / #file(path) / #files
CoverageMap#load_time_only?(path, line)   -> Boolean, the boot ran it and no test did
CoverageMap#tests_for_file(path)          -> Array[String] sorted, every test that hit any line of path
CoverageMap::FileCoverage = Data.define(:path, :state, :boot_lines, :loaded_by)
# state: :not_loaded | :uninstrumented | :loaded_during_test | :instrumented
```

The coverage sampler owns per-test coverage collection; `CoverageMap` is a plain value that only
answers "which tests execute this file and line" and "how was this file loaded". The sampler
describes every target once: `instrumented` with the lines the boot ran when it has counters in
the snapshot right after boot, `uninstrumented` when Ruby loaded it but it has no live counters
(its reload under Coverage raised, or it never appeared in the snapshot), `loaded_during_test`
with the test that first required it, and `not_loaded` otherwise.
`TestSelection#uncovered_reason` turns that into the uncovered reason.

```ruby
# lib/sabaku/test_selection.rb
TestSelection.new(coverage_map)
TestSelection#tests_for(mutant, source)   -> Array[String], ordered by reach then id
```

The runner and the coverage sampler both ask `TestSelection` which tests a mutant needs, so the
weak pass runs exactly the union of those answers. A second copy of the rule would drift, and a
test the runner picks but the probe pass skipped would turn a decided mutant into `:unknown`.

```ruby
# lib/sabaku/adapters/minitest.rb
MinitestAdapter.new(test_globs: []) -> adapter   # the CLI passes Config#test_globs
adapter.preload!        -> void          # loads the project's tests into this process
adapter.test_ids        -> Array[String] # stable ids, minitest native
adapter.run(ids)        -> Outcome       # runs those ids only, in this process
adapter.sweep(ids)      -> Sweep         # runs every id, whatever the earlier ones did
Outcome = Data.define(:ok, :failed_id, :error)   # ok: Boolean, error: Exception | nil
Sweep = Data.define(:failed_ids)                 # every id that failed, in the given order
```

`preload!` then repeated `run(ids)` in forked children is the fast path. `MinitestAdapter#run` must never
raise for an ordinary test failure, and must never call `exit`.

```ruby
# lib/sabaku/runner.rb
Runner.new(config, analyzer:, adapter:, coverage_map:, weak:) #call -> Array[Result]
Result = Data.define(:mutant, :status, :duration, :failed_test, :message, :reason, :kills)
# status: :killed | :survived | :timeout | :error | :uncovered | :skipped
# reason: one of Result::REASONS[status], or nil when the result was not classified
#   survived  :not_detected | :not_infected
#   uncovered :not_loaded | :uninstrumented | :load_time_only | :not_reached
#   timeout   :deadline
#   error     :environment_crash | :unverified_kill | :harness
#   skipped   :fail_fast | :mutation_unloadable | :suite_unloadable
# The report groups unscored results by reason, never by message text.
# :skipped means --fail-fast stopped before this mutant was scheduled, or no
# child could measure it (the mutation does not load, on either surface)
# kills: Kills | nil. Only under --kill-matrix, only on killed and survived results, and
# only when every selected test ran to a verdict. A killed row contains failed_test when
# the child named one; a child that died before reporting leaves failed_test nil.
Kills = Data.define(:tested, :killers)            # killers ⊆ tested, both sorted

# lib/sabaku/kill_matrix.rb
KillMatrix.from(results, universe:, selected:, scope: :class)  # selected: {mutant id => test ids}
KillMatrix.group_of(test_id) -> String              # "Klass#method" -> "Klass"
KillMatrix#verdicts -> Array[Verdict]               # one per test, sorted by id
Verdict = Data.define(:test, :kind, :kills, :unique, :tested, :by, :provisional, :group,
                      :confidence)
# kind: :kept | :subsumed | :duplicate | :zero | :idle
# group: the test class under scope :class, "" under :suite. `by` is always in the same group.
# confidence: :artifact when every row the test kills is broad for its group (at least two
#   tests of the group ran it and all killed it), else :strong
Verdict#tier -> :actionable | :provisional | :artifact | :none   # :none unless redundant
```

Mutant lifecycle, the whole state machine:

```
candidate --(arid)--> dropped
candidate --(diff filter)--> dropped
candidate --(no covering test)--> uncovered
candidate --(covering tests, weak said not_infected)--> survived(:not_infected), no child
candidate --(covering tests)--> queued --> running --(child exits 0)--> survived(:not_detected)
                                                 |--(child exits 1)--> killed
                                                 |--(parent kills it at the deadline)--> timeout(:deadline)
                                                 |--(child dies of a signal before the deadline)--> error(:environment_crash)
                                                 |--(child exits 1 with no summary)--> killed
                                                 |--(mutated file does not load)--> skipped
                                                 |--(file cannot be reloaded)--> first-load child
                                                 |     |--(measured)--> survived | killed | timeout
                                                 |     '--(does not load)--> skipped
                                                 '--(other child failure)--> error
candidate --(--fail-fast saw a survivor first)--> skipped
```

Under `--kill-matrix`, one pass follows the pool and the kill checks, and it never writes a
status:

```
killed (failed_test t, selected s) --(nothing after t in s)--> row {t}
killed --(sweep child runs s after t)--> clean payload --(swept killers pass the reload check)--> row {t} ∪ failed
                                    '--> timeout / crash / bad payload / a killer fails unmutated --> no row
survived --> row {} (every selected test already passed)
```

A kill whose child died before naming a test sweeps the whole selection. The pass runs even when
every mutant was a cache hit, and `--fail-fast` does not stop it, because it asks about kills
already counted.

The probe pass decides some survivors before any child runs, so `--fail-fast` has two halting
points, not one: a survivor the dry run proved stops the campaign before the first fork, and a
survivor a child produced stops it before the next fork. Both leave the mutants that were never
scheduled `skipped`, and both keep the verdicts the dry run already paid for: a cache hit or a
`not_infected` decision behind the first survivor is still reported, because dropping it would
throw away evidence already bought.

`score` = killed / (killed + survived + timeout). A survivor keeps its full weight whether a test
noticed the change (`:not_detected`) or no test ever saw one (`:not_infected`); the report splits
them so the number and the explanation cannot disagree. `uncovered`, `error` and `skipped` are
reported separately and never enter the denominator.

## The dry run (coverage, then probes)

`CoverageSampler#call` owns both passes, in this order, in the parent:

1. `Coverage.start` if it is not already running, then `Boot.require_paths`, `preload!`, and the
   `after_boot` hook. Coverage must start before the project loads. A Coverage the project
   started without `lines` raises `CoverageError`: no line could be attributed. A target loaded
   before Coverage started is reloaded once; one whose reload raises is `uninstrumented` and the
   rest are still sampled.
2. Every test runs once, in process, and its newly-hit target lines are recorded in a
   `CoverageMap`. A red suite fails the run before any mutant is spent (unless `--no-baseline`).
3. The weak pass reloads probe-instrumented copies of the target files over the originals, then
   runs only the tests the runner can select for a probe-eligible mutant. `Weak.test_id` is set
   to the running test so every probe attributes its evaluation. A probe that cannot be installed
   (a file whose reload raises, a mutant without pure operands) simply leaves its mutant
   `:unknown`, which runs normally.

Two line kinds have no per-test owner. Naming either `:uncovered` would be cheaper and would drop
real mutants from the score, which is the one lie this engine cannot tell.

- A line only the boot ran: a class-body DSL call, a schema block the class body yields to.
  `TestSelection#tests_for` falls back from the span and the statement span to every test that
  reached the file, ordered by reach then id. The child re-evaluates the file, so the mutated DSL
  call runs again and those tests see what it built. With no such test the mutant is `:uncovered`
  with `:load_time_only`.
- An endless method's line (`def m = expr`). Ruby marks it when the class body runs and never
  increments it on a call, so the delta after a test is zero even though every call executed it.
  `TestSelection#unattributable?` recognises that line from the AST, and the runner runs every
  test for mutants on it. The measured load-time-only fallback is not enough here: under a lazy
  autoload the `def` line is attributed to the one test that loaded the file.

The passes are separate because code compiled by `eval` is not instrumented: doing both at once
would erase the probed files' line counts. The price is one extra run of the tests that can reach
a probe, paid only when at least one mutant is probe-eligible. `--no-weak` skips the pass and the
classification.

The probe text is evaluated with the original absolute path, so `__FILE__` and `require_relative`
behave as they do in the file. The file body does re-execute, which is the same surface the cache
reload and first-load paths already assume.

## Mutation application (the one load-bearing trick)

Ruby has no supported API to replace a defined method body, so the child re-executes the source
file after the splice:

1. Parent: `preload!` loads the framework and the project tests once. Test code is now resident.
2. Per mutant: `fork`.
3. Child: `eval(mutant.splice(source.text), absolute_path, 1)`. Re-executing the file re-opens the
   classes it declares and replaces their method bodies. The original path is kept so
   `require_relative` and `__FILE__` resolve as they do normally.
4. Child: `adapter.run(selected_ids)`, then `exit!(0)` or `exit!(1)`.
5. Parent: wait with deadline, classify.

A file that cannot be loaded twice is not a mutation that cannot be measured. After the pool
drains, one reload control per file re-evaluates the unmutated file in the same child shape. If it
raises, the file is the reason the fork child failed, so the mutant moves to the first-load
surface. If the unmutated file loads, the mutation is unloadable and the mutant is `:skipped` with
that error.

The first-load surface is `runtime/bootstrap.rb` in a fresh process. It boots like the parent
(`Boot.require_paths`, `preload!`, `after_boot`) before installing the loader; the loader hooks
both `require` and `Kernel.require`, which Zeitwerk and Bootsnap call. The project's suite loads in
its normal order, and `runtime/first_load.rb` substitutes the mutated source at the moment the
project loads the target: a `require` is answered with an `eval` of the spliced text, and an
`autoload` registered for the target is redirected to a generated shim that does the same. The
mutation is therefore the file's first load, with the rest of the project already loaded. A
pending autoload for the same constant is removed first; otherwise the file's own `module` line
would fire it and lose the constant.

The child's deadline carries the measured cost of a bare first-load child (one neutral boot), so
the preload is not charged to the mutant. A boot error on this surface means the suite cannot load
with the mutation, and the mutant is `:skipped` with that reason. A kill on either surface is kept
only when the same test passes with no mutation applied on that surface; a kill that only the
second load or only the first load caused becomes `:error` with `unverified kill`.

Limits, documented in the README and reported rather than silently passed:
`require_relative` and files something loaded before the loader was installed cannot be
intercepted. When the target was already loaded, the child names that instead of evaluating over
a copy, and the mutant is `:skipped`. Mutations inside `define_method` blocks, inside
`Struct`/`Data` field lists, or in a file whose reload redefines a constant differently still
raise, and land in the reload-control branch.

`isolation: :process` replaces steps 2 to 4 with a fresh `ruby` process per mutant running the
minitest adapter with the selected test ids in the environment; it uses the same first-load loader
for every mutant. Slower, and the fallback surface for a file that fork isolation cannot load twice.

## Cache

`Cache` stores one entry per `Runner#cache_key`, which hashes:

- the cache format version and the campaign fingerprint (test tree, setup, ENV, `--require`,
  isolation, weak mode, timeout)
- `Mutant#id` (path, scope, AST path, operator, replacement)
- sha256 of the full mutated source that would be loaded
- Ruby version and the selected test ids

A hit skips the child and reports the stored status and reason with duration 0. `:uncovered`
results are not stored. `SABAKU_NO_CACHE` is the kill switch.

A killed entry may also carry `killers`, its kill-matrix row. The key is optional, so the format
version does not move. A malformed row is dropped and the status kept, and a store without
`killers` keeps the row already stored for the same status and failed test. `--kill-matrix` is
not in the fingerprint: it cannot change a status, so it must not split the cache.

## Aridity rules for Ruby (expert())

Suppressed because unit tests do not assert them, or because killing them teaches nothing:

- calls to `puts`, `print`, `p`, `pp`, `warn`, `$stdout.*`, `$stderr.*`, `Kernel#printf`
- calls on a receiver named `logger`, `@logger`, `Rails.logger`, `ActiveSupport::Logger`
- `require`, `require_relative`, `load`, `autoload`
- `attr_accessor`, `attr_reader`, `attr_writer`, `include`, `extend`, `prepend`, `private`,
  `protected`, `public`, `module_function`, `alias_method`, `using`
- assignment to an all-uppercase constant (`MAX_RETRIES = 3`)
- `def initialize` bodies that only assign ivars, and `def to_s`, `inspect`, `hash`, `==`, `eql?`,
  `<=>`, `method_missing`, `respond_to_missing?` bodies
- string and symbol literals that are arguments of a suppressed call (a log message is not a fault
  site)
- `__FILE__`, `__dir__`, `__method__`, `freeze`, `.frozen?`, `# frozen_string_literal: true`
- Sorbet declarations: receiverless `sig`, `abstract!`, `interface!`, `final!`, `sealed!`,
  `mixes_in_class_methods`, `requires_ancestor`
- type arguments of `T.let` / `T.cast` / `T.bind` / `T.assert_type!` / `T.must_because` (the value
  argument stays mutable; `T.must(x)` stays mutable because dropping it removes a nil check)
- type arguments of `const` / `prop` inside a `T::Struct` / `T::InexactStruct` class (`default:` /
  `factory:` stay mutable)
- compound node: arid iff every child is arid

Statement deletion (`sbr`) also refuses to delete a `def` that is immediately preceded by a
receiverless `sig` call: re-evaluating that file only raises under sorbet-runtime.
