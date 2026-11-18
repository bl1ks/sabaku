# ruby-mutation design contract

Frozen before implementation. Every subagent codes against this file. Deviations are surfaced,
not absorbed. Model follows Petrovic & Ivankovic, "State of Mutation Testing at Google" (ICSE-SEIP 2018).

## What the paper gives us, mapped to Ruby

| Paper | This library | Where |
| --- | --- | --- |
| Mutants on changed lines only (diff-based) | `--diff` / `Config#diff_ranges` filters mutants by line | `Analyzer` |
| Lines without statement coverage are not mutated | mutant without a covering test is `:uncovered`, never run | `Runner` |
| Arid nodes are suppressed (expert() on simple nodes, recursive AND on compound) | `Aridity#arid?(node, ancestors)` with Ruby rules | `lib/mutation/aridity.rb` |
| At most one mutant per line; operator picked at random from applicable ones | seed-derived pick per line, `Config#max_mutants_per_line` | `Analyzer` |
| Operators AOR, LCR, ROR, SBR, UOI | same ids, Ruby semantics | `lib/mutation/operators/` |
| Mutant killed / living, test target per file | `:killed` / `:survived`, `CoverageMap#tests_for` | `Runner`, `adapters/` |

## Data shapes

These are the core types. Every value object is frozen and `#to_h`-able so the report and the
JSON cache never need a second conversion path.

```ruby
# lib/mutation/config.rb
Config = Data.define(
  :paths,        # Array[String] files or globs to mutate
  :exclude,      # Array[String] globs
  :operators,    # Array[Symbol] enabled operator ids
  :adapter,      # Symbol, :minitest | :rspec
  :jobs,         # Integer >= 1
  :timeout,      # Float seconds per mutant
  :seed,         # Integer, makes operator choice reproducible
  :per_line,     # Integer (paper: 1) or Float::INFINITY for `--per-line=all`
  :diff_ranges,  # Hash[String => Array[Range]], nil when mutating whole files
  :coverage,     # Boolean, test selection on/off
  :isolation,    # Symbol, :fork | :process
  :report,       # Symbol, :terminal | :json | :quiet
  :output,       # String path | nil
  :env,          # Hash[String => String], set before the suite loads
  :requires,     # Array[String], required after Coverage.start, before the tests
  :setup,        # Mutation::Setup | nil, the --setup hooks
  :setup_path,   # String | nil, the file the setup came from (process isolation)
  :fail_fast,    # Boolean, stop at the first survivor
  :baseline      # Boolean, refuse to score a suite that is not green and re-check kills
)
Config.default(**overrides) -> Config

# lib/mutation/source.rb
Source.new(rel_path, text)
  #rel_path    -> String, path relative to the project root
  #text        -> String (frozen)
  #ast         -> Prism::Node (root, parsed once)
  #line_of(offset) -> Integer
  #slice(node) -> String, exactly node.location.slice
  flat_nodes  -> Enumerator[Prism::Node] (preorder, excluding the root)

# lib/mutation/mutant.rb
Mutant = Data.define(:id, :path, :operator, :line, :column, :node_kind, :original, :replacement)
  #id          String, stable: sha1("path\0start_offset\0end_offset\0replacement")[0, 16]
  #line        1-based line number of node start
  #column      0-based byte column of node start
  #node_kind   String, Prism node type, e.g. "CallNode"
  #original    String, exact source slice being replaced
  #replacement String, replacement source text
  #description String, e.g. "AOR: 4 + 5 -> 4 - 5"
  #to_h        Hash
Mutant#splice(text) -> String   # text with [start_offset, end_offset) replaced
Mutant#start_offset, #end_offset  Integers into the source
```

`Mutant` carries its own offsets because the offsets must survive a round trip through the JSON
cache. `splice` never re-parses.

```ruby
# lib/mutation/operators/registry.rb
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
```

```ruby
# lib/mutation/aridity.rb
Aridity.new #arid?(node, ancestors) -> Boolean
# simple node: expert(node, ancestors)
# compound node: all children arid (recursive, per paper equation 1)
```

```ruby
# lib/mutation/analyzer.rb
Analyzer.new(sources, config) #each -> Enumerator[Mutant]
Analyzer.new(...).mutants     -> Array[Mutant]  # deterministic order: path, offset, operator
```

```ruby
# lib/mutation/coverage_map.rb
CoverageMap.empty
CoverageMap#record(test_id, hits)         # hits: Hash[path => Array[Integer] | Set[Integer]]
CoverageMap#tests_for(path, line)         -> Array[String] sorted
CoverageMap#merge(other)                  -> CoverageMap
CoverageMap#to_h / .from_h                # JSON round trip
```

Adapters own per-test coverage collection; `CoverageMap` is a plain value that only answers
"which tests execute this file and line".

```ruby
# lib/mutation/adapters/base.rb
Adapter.for(:minitest, config) -> Adapter
Adapter#name            -> Symbol
Adapter#preload!        -> void          # loads the project's tests into this process
Adapter#test_ids        -> Array[String] # stable ids, framework native
Adapter#run(ids)        -> Outcome       # runs those ids only, in this process
Outcome = Data.define(:ok, :failed_id, :error)   # ok: Boolean, error: Exception | nil
```

`preload!` then repeated `run(ids)` in forked children is the fast path. `Adapter#run` must never
raise for an ordinary test failure, and must never call `exit`.

```ruby
# lib/mutation/runner.rb
Runner.new(config, analyzer:, adapter:, coverage_map:) #call -> Array[Result]
Result = Data.define(:mutant, :status, :duration, :failed_test, :message)
# status: :killed | :survived | :timeout | :error | :uncovered | :skipped
# :skipped means --fail-fast stopped before this mutant was scheduled, or no
# child could measure it (the file cannot be reloaded, or the mutation does not load)
```

Mutant lifecycle, the whole state machine:

```
candidate --(arid)--> dropped
candidate --(diff filter)--> dropped
candidate --(no covering test)--> uncovered
candidate --(covering tests)--> queued --> running --(child exits 0)--> survived
                                                 |--(child exits 1)--> killed
                                                 |--(child killed by signal / deadline)--> timeout
                                                 |--(child exits 1 with no summary)--> killed
                                                 |--(file cannot be reloaded)--> skipped
                                                 |--(mutated file does not load)--> skipped
                                                 '--(other child failure)--> error
candidate --(--fail-fast saw a survivor first)--> skipped
```

`score` = killed / (killed + survived + timeout), reported with `uncovered` and `error` counted
separately and never folded into the denominator. That matches how the paper reports living
mutants apart from unrun lines.

## Mutation application (the one load-bearing trick)

Ruby has no supported API to replace a defined method body, so the child re-executes the source
file after the splice:

1. Parent: `preload!` loads the framework and the project tests once. Test code is now resident.
2. Per mutant: `fork`.
3. Child: write `mutant.splice(source.text)` to `Dir.mktmpdir/<basename>.rb`, then `load` it.
   Re-executing the file re-opens the classes it declares and replaces their method bodies.
4. Child: `adapter.run(selected_ids)`, then `exit!(0)` or `exit!(1)`.
5. Parent: wait with deadline, classify.

Limits, documented in the README and reported rather than silently passed: mutations inside
`define_method` blocks, inside `Struct`/`Data` field lists, or in a file whose reload redefines a
constant differently raise or warn on reload. A child that raises during `load` is not attributed
to the mutant until the runner has evaluated the original file once more in the same child shape.
If the unmutated file also raises, the file cannot be reloaded in fork isolation and the mutant is
`:skipped` with the file's error; if only the mutated file raises, the mutation does not load and
the mutant is `:skipped` with that error. Neither is `:survived`, and neither is scored.

`isolation: :process` replaces steps 2 to 4 with a fresh `ruby` process per mutant running the
adapter with a filter flag. Slower, and the only option when a project cannot be reloaded.

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
- every node inside a `# rubocop:disable`-free comment-free blank region: whitespace only
- `__FILE__`, `__dir__`, `__method__`, `freeze`, `.frozen?`, `# frozen_string_literal: true`
- compound node: arid iff every child is arid

## Verified framework APIs (probed, not guessed)

Ruby in the dev image is 3.4.12, minitest 6.1.0, rspec 3.13.2. These were checked in the
container before the adapters were written, because both APIs changed from what the obvious
documentation suggests.

minitest 6:

```ruby
# Minitest.run_one_method does NOT exist in 6.x. This does:
inst = TestClass.new("test_name")
inst.run
inst.failures.empty?          # true means the test passed; a failure never raises out of #run
```

`require "minitest/autorun"` installs an at_exit that runs the whole suite. `bin/mutation` ends
with `exit!(status)` after flushing so a campaign does not re-run the suite it just measured.
`inst.run` prints through the class reporter, so subsets need a null reporter.

rspec 3.13:

```ruby
RSpec::Core::Runner.new(RSpec::Core::ConfigurationOptions.new(["spec"]),
                        RSpec.configuration, RSpec.world).setup(err_io, out_io)
examples = RSpec.world.example_groups.flat_map(&:descendants).flat_map(&:examples)
reporter = RSpec::Core::Reporter.new(RSpec.configuration)
example.run(example.example_group.new, reporter)
example.execution_result.status      # :passed or :failed, no raise
```

`setup` takes exactly `(err, out)` and already loads `spec/**/*_spec.rb`, so loading again
doubles every example. `ConfigurationOptions.new([])` leaves `files_to_run` empty and loads
nothing. `RSpec::Core::Configuration#reporter=` does not exist.
