# sabaku

Mutation testing for minitest suites. It rewrites one AST node of your source at a time, runs
**only the tests that cover that line**, and reports the mutants your suite failed to notice.

The engine borrows the shape of Google's mutation service (Petrovic & Ivankovic, *"State of
Mutation Testing at Google"*, ICSE-SEIP 2018) and drops the parts that cost more than they pay:

| Idea | This library |
| --- | --- |
| Mutate only the lines a change touches | `--diff=FILE.json` restricts mutants to listed lines |
| Never mutate a line without coverage | a mutant with no covering test is `uncovered`, never run, never scored |
| Suppress *arid* nodes | `Sabaku::Aridity`, Ruby rules, recursive over compound nodes |
| Spend the line on the best operator, not a random one | `Registry::PRODUCTIVITY`, earliest offset as the tie break |
| A mutant is a place in the code, not a byte range | id hashes path, scope, AST path, operator and replacement |
| A survivor no test ever saw is not the same as one a test missed | the dry-run probe pass splits `not_infected` from `not_detected` |

## Install

```ruby
# Gemfile
gem "sabaku", require: false
```

Requires Ruby 3.2 or newer. Prism (the parser) ships with Ruby from 3.3. Verified against
minitest 5.25 and 6.1 on Ruby 3.4.12.

## Run

```sh
# from your project root: minitest suite in test/, sources in lib/
sabaku run

# only mutate the lines in a diff
sabaku run --diff=changed_lines.json

# what would run, without running it
sabaku list

# environment check
sabaku doctor
```

```
sabaku 0.1.0  files=1  mutants=11  jobs=1

  killed         8   72.7%
  survived       2   18.2%  <- your tests did not notice these
    not detected 1, not infected 1
  timeout        0    0.0%  <- killed by the clock, not by a test
  uncovered      1    9.1%  (no test covers the line; not scored)
    not reached 1

  mutation score   80.0%  (killed / killed+survived+timeout)

survivors:
  lib/pricing.rb:25  ROR: volume >= 5 -> volume == 5
  lib/pricing.rb:26  AOR: subtotal * 0.05 -> subtotal % 0.05
```

Exit codes are `0` ok, `1` when the reported score is below `--min-score`, `2` error,
so CI can gate on the score. A campaign that loses a mutant for a reason it cannot explain
exits `2`: the score is computed over the mutants that ran, so a run with errors is not a
measurement of the suite. A mutant no child could measure (a mutation that does not load on
either surface) is reported as `skipped` with the reason, stays out of the score, and does not
fail the run:

```sh
sabaku run --min-score=70 --report=json --output=mutation.json
```

Every unscored status names why, under its row in the terminal and in the JSON report's
`reasons` (`{"skipped" => {"mutation_unloadable" => 2}, ...}`): a timeout hit its `deadline`; an
error is an `environment_crash` (the child died of a signal before its deadline, so nothing was
measured), an `unverified_kill` or a `harness` failure; a skipped mutant was stopped by
`fail_fast`, or its mutation (`mutation_unloadable`) or the first-load suite (`suite_unloadable`)
does not load.

The reported score is printed at one decimal and `--min-score` compares that same value, so the
number in the output and the exit code cannot disagree.

A survivor names a line and the rewrite that survived. Line 25 above says the five-item volume
tier has no test at all: the suite only exercises the ten-item tier.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `--jobs=N` | `1` | mutants in flight at once |
| `--timeout=SEC` | `5` | per-mutant deadline |
| `--operators=aor,ror,...` | all | restrict mutation operators |
| `--per-line=N\|all` | `1` | mutants kept per line; `all` keeps every candidate |
| `--diff=PATH` | off | JSON `{"path" => [lines]}` allowlist |
| `--since=REV` | off | only mutate the lines that changed since a git revision |
| `--fail-fast` | off | stop at the first surviving mutant, probe-pass survivors included; the rest are `skipped` |
| `--[no-]baseline` | on | refuse to score a suite that is not green, and re-check each kill against a second load of the file |
| `--env=KEY=VALUE` | none | set an ENV entry before the suite loads (repeatable) |
| `--require=PATH` | none | require after coverage starts, before the tests (repeatable) |
| `--setup=PATH` | none | Ruby file with boot hooks for Rails and friends |
| `--[no-]coverage` | on | test selection; `--no-coverage` runs the whole suite per mutant |
| `--[no-]weak` | on | probe the dry run and decide uninfected survivors without running them |
| `--[no-]kill-matrix` | off | run every selected test against each killed mutant and report redundant tests; the score does not change |
| `--kill-matrix-scope=class\|suite` | `class` | a test is redundant only next to tests of its own class, or next to any test |
| `--sweep-timeout=SEC` | `--timeout` | deadline for one kill-matrix sweep, which runs every selected test after the first failure |
| `--isolation=fork\|process` | `fork` | reload a preloaded suite, or boot a fresh process |
| `--report=terminal\|json\|quiet` | `terminal` | output |
| `--output=PATH` | none | write the JSON report |
| `--min-score=PCT` | none | exit 1 when the reported score is below this |
| `--exclude=GLOB` | none | skip files |
| `--tests=GLOB` | `test/**/*_test.rb` | test files to load (repeatable) |
| `--limit=N` | none | cap the mutant count |

Run it from the project root. `lib` and `test` are put on `$LOAD_PATH`, and test files
are discovered with `test/**/*_test.rb`. `--tests=GLOB` replaces the pattern, and
`SABAKU_TEST_GLOB` sets one when the flag is absent. Set `SABAKU_NO_CACHE=1` to ignore the result cache.

### Kill matrix

A result names the first test that killed a mutant. `--kill-matrix` finds every test that kills
it, and from that, which tests add nothing. After the normal run, each killed mutant gets a second
child that runs the selected tests the first child never reached. The first failure plus that
tail is the mutant's full row. A survivor's row is already known: every selected test passed.
Each test gets one verdict:

| Verdict | Meaning |
| --- | --- |
| `kept` | no other test kills a superset of its kills |
| `subsumed` | another test kills everything it kills, and more; `by` names the strongest such test |
| `duplicate` | another test kills exactly the same mutants and sorts first; one test per such group is `kept` |
| `zero` | selected for a scored mutant and killed none: it runs the code and asserts too little |
| `idle` | never selected for a killed or survived mutant; a `--fail-fast` stop or an errored mutant can leave a covering test here |

A test is compared only with the tests of its own class (`Klass` in `Klass#test_x`). A small
unit test that kills a subset of what a request test kills is still `kept`: the two answer
different questions, and deleting the unit test is not the advice. `--kill-matrix-scope=suite`
compares every test with every other.

Removing every `subsumed` and `duplicate` test keeps every kill, so the score would not move.
The terminal lists only the redundant tests worth acting on. It counts two other kinds apart:

| Tier | Meaning |
| --- | --- |
| actionable | listed: a real subset or duplicate over complete rows |
| provisional | an incomplete row selected the test, so its verdict can still change (`?`) |
| broad-only | every mutant it kills was killed by every test of its class that ran it; nothing tells those tests apart, often because a constant table is not mutated and only its lookup is |

The JSON report gives each test its `group`, `confidence` (`strong` or `artifact`) and `tier`.
The kept tests are a cover, not a minimum one. The terminal lists zero-kill tests, redundant
tests and the tests with the most unique kills. The JSON report adds a `kill_matrix` section,
with tests sorted by id, and a `kills` row on each result.

The flag never changes a status, the score or the exit code. A sweep that times out, crashes,
or names a killer that also fails with the file reloaded and no mutation leaves the mutant's
status alone and gives it no row. The report counts these incomplete rows by cause
(`sweep_timeout`, `sweep_crash`, `bad_payload`, `unverified_killer`, `foreign_failed_test`,
`no_killer`), names the five test classes they touch most, and suggests `--sweep-timeout` when
the deadline is the main cause. It marks every test one of them selected with `?`; completing that row can still change that test's verdict. A
`?` test can also become the dominator of a kept test, so while any row is incomplete, read the
kept list and the unique counts as advice, not a settled answer. Rows are cached, and a cache
warmed without the flag only pays for the tails.

A mutant id is `sha1(path, scope, AST path, operator, replacement)`, so moving a method down a
file keeps its cached verdict. Editing the method changes the id of every mutant inside it, which
is the smallest unit the cache can safely reuse.

## What it does, in five stages

```
Source (Prism AST) --operators--> candidates --aridity--> --diff--> --per line--> Mutants
                                                                                 |
CoverageMap (which test hits which line) --- tests_for ---> selected test ids --->|
                                                                                 v
                                   weak pass: probe the value, decide not_infected |
                                                                                 v
                                              Runner: fork, reload mutated file, run ids
                                                                                 |
                 survived | killed | timeout | error | uncovered | skipped  <--------'
```

1. **Analyze.** Each file is parsed once with Prism. Every node the enabled operators claim
   produces candidate rewrites as byte-range splices. `Replacement#original` must equal the
   exact source slice or the run fails loudly rather than emitting a no-op mutant.
2. **Suppress aridity.** Nodes whose mutation no test can meaningfully assert on are dropped,
   along with the guarded debug-log lines that only serve logging.
3. **Select per line.** Candidates are grouped by `(path, line)` and sorted by operator
   productivity, then by offset. The line keeps the first `--per-line` that re-parse, with no
   random draw, so two runs on the same code keep the same mutants and the cache stays usable.
4. **Collect coverage.** The suite runs once, instrumented, and every test's newly-hit lines are
   recorded. A mutant with no covering test is `uncovered`: not run, not scored. Its reason
   says why: the file was `not_loaded` by any test, it was loaded without line counters
   (`uninstrumented`: loaded before Coverage started and not reloadable), only the boot ran the
   line and no test reached the file (`load_time_only`), or the file was measured and no test
   reached the line
   (`not_reached`). A file with nothing scored names the reason in `per file:`, the JSON report
   lists those files under `coverage_files`, and a file one test loaded lazily names that test.
   A project that starts Coverage itself without line counters (SimpleCov's oneshot mode) stops
   the campaign with that cause instead of reporting every file uninstrumented.
5. **Probe the values.** The suite runs a second time with probe-instrumented copies of the
   mutated files loaded over the originals. A probe returns the original value, then evaluates
   each replacement against it. Every covering test that reached the expression is recorded, and
   a mutant no test saw change is `survived` with reason `not_infected`, without a child.
6. **Execute.** For each remaining mutant the parent forks, the child re-evaluates the mutated
   file, runs the selected tests, and reports through a pipe. The parent enforces the deadline,
   kills and reaps, and classifies the exit. A survivor gets `reason: not_detected`.

### Operators

| id | What it does | Applicable to |
| --- | --- | --- |
| `aor` | arithmetic operator replacement (`a + b` -> `a - b`, ...) | `+ - * / %` calls |
| `ror` | relational replacement, plus `true` / `false` | `== != > >= < <=` |
| `lcr` | logical connector replacement (`a && b` -> `a`, `b`, `a \|\| b`, `true`, `false`) | `&&`, `\|\|`, `and`, `or` |
| `sbr` | statement block removal | multi-statement bodies |
| `uoi` | unary operator insertion (`if x` -> `if !(x)`) | `if`, `unless`, `while`, `until` |
| `bool` | boolean literal flip | `true` -> `false` |
| `str` | non-empty string literal -> `""` | string literals |
| `literal` | integer and float step by one, array and hash collapse to empty | integer, float, array, hash literals |
| `selector` | method name swap (`xs.map` -> `xs.each`, `a << 1` -> `a >> 1`) | the method replacement table |
| `call` | drop the receiver, drop the receiver and message, drop or nil an argument, lift a single argument into the call's place | call sites |
| `cond` | branch predicate becomes `true` and `false` | `if`, `unless` |
| `assign` | compound assignment becomes plain assignment (`x += 1` -> `x = 1`) | `+=`, `\|\|=`, `&&=`, ... |
| `return` | the method's last expression becomes `nil` (`def value; compute; end` -> `nil`) | method bodies |
| `control` | `break` and `next` swap | `break`, `next` |

Every operator is on by default. An operator widens the candidate pool; `--per-line` decides how
much of that pool a campaign runs, so `--per-line=1` stays cheap while `--per-line=all` runs the
whole pool.

The per-line budget goes to `ror`, `lcr`, `aor`, `cond`, `uoi`, `bool`, `literal`, `str`, `sbr`,
`selector`, `call`, `assign`, `return`, `control`, in that order. Relational and conditional
rewrites survive the most often in practice, literal and structural ones the least, so a budget
of one spends it where it teaches the most.

A mutation is applied by re-evaluating the file, and re-evaluation redefines a method but never
undefines one. `sbr` therefore never removes a
statement from a file body, a class body or a module body: deleting a `def` there cannot change
behaviour, so the mutant would always survive and teach nothing.

### Aridity

Suppressed because a unit test asserting them is not testing behaviour:

- `puts`, `print`, `p`, `pp`, `warn`, `printf`, `$stdout.*`, `$stderr.*`
- calls on `logger`, `@logger`, `Rails.logger`, `ActiveSupport::Logger`
- `require`, `require_relative`, `load`, `autoload`
- `attr_*`, `include`, `extend`, `prepend`, visibility methods, `alias_method`
- writes to an all-uppercase constant
- `initialize` bodies that only assign ivars, and `to_s` / `inspect` / `hash` / `==` / `eql?` /
  `<=>` / `method_missing` / `respond_to_missing?`
- string and symbol literals passed to a suppressed call (a log message is not a fault site)
- `__FILE__`, `__dir__`, `__method__`, `freeze`, `frozen?`
- an `if` / `unless` / `while` / `until` whose whole body is a logging call, because mutating the
  guard on a debug log is not actionable
- Sorbet `sig` / `abstract!` and the type arguments of `T.let` / `T.cast` / `T.bind` /
  `T.assert_type!` / `T.must_because`, and of `const` / `prop` on a `T::Struct` (the value, and
  `T.must(x)`, stay mutable)
- statement deletion also keeps a `def` that follows a `sig`, because that rewrite only fails to
  load under sorbet-runtime

A compound node is arid when every child is arid, which is the paper's rule. The database,
network or filesystem call in an `if` body keeps that `if` live.

## Rails

`--setup` gives a Rails app the hooks it needs: `env`, `require_path`, `after_boot`
(`eager_load!`), `before_fork` (disconnect the pool), `child_start` and `before_test_run`
(per-child database). [`docs/rails.md`](docs/rails.md) has the recipes for transactional
fixtures, per-child SQLite copies, PostgreSQL templates, and MySQL clones, plus what can and
cannot be targeted. `bin/check-rails` runs both campaigns, with a throwaway MySQL server for the
MySQL half.

## Limits

These are real and deliberate; know them before trusting a score.

- **Mutations are applied by re-evaluating the file.** Method bodies, constants and class-level
  code re-execute correctly. Code behind `define_method` (the block is not re-run), `Struct` and
  `Data` field lists, and anything that would change a superclass cannot be redefined this way.
- **`require_relative` and `__FILE__` resolve against the original path**, because the child
  evaluates the mutated text with that path. Files that depend on load order or on `END` blocks
  may not reload cleanly.
- **A file that cannot be reloaded is measured at its first load.** When a child cannot load its
  file, the runner evaluates the original file once more in the same child shape. If only the
  mutated file raises, the mutant does not load and is `skipped` with that error. If the original
  file also raises, the file cannot be loaded twice, so the mutant is retried in a fresh process
  where the suite loads in its normal order and the mutation is applied at the target's own
  `require` or `autoload`: the file's first load. A retry that still cannot load is `skipped`
  with the reason. Neither is scored. `--isolation=process` uses the same first-load loader for
  every mutant.
- **Per-test coverage is collected by running the suite once, instrumented. The weak pass then
  runs only the tests that can reach a probe.** On a large suite the first pass dominates the
  fixed cost of a campaign, and the tests a probe needs run twice. Neither pass is cached.
  `--no-weak` removes the second pass.
- **Weak probes only decide pure expressions.** Arithmetic, relational and logical nodes over
  literals, locals, ivars, `self` and constants. A method call anywhere in the expression keeps
  its mutant on the real-run path, so a missing `not_infected` label is not a correctness bug.
- **Lines executed only at load time** (a `validates` call, a `params do` schema block) have no
  per-test owner. Their mutants run every test that reached the file; with no such test they are
  `uncovered` with reason `load_time_only`.
- **An endless method (`def m = expr`) never reports a per-test hit** on its own line: Ruby marks
  that line while the class body runs, and a call does not increment it again. Those mutants are
  not `uncovered`; they run every test, because no counter can say which test called the method
  and calling one `uncovered` would score a mutant nobody measured.
- **The kill matrix assumes a test's verdict does not depend on the tests before it.** The sweep
  runs the tail without the prefix that already passed, so a suite with order-dependent tests
  can report a different killer set than one full run would. The status is never affected.
- **`uncovered`, `error`, and `skipped` never enter the score.** They are reported separately so a
  file with no coverage, or a file no child could measure, cannot inflate the number.

## Development

There is no Ruby on the host machine used for this work, so everything runs in the dev container:

```sh
./bin/check                                             # unit + e2e under minitest 5 and 6,
                                                        # packaged gem smoke test,
                                                        # formal regression probes
./bin/practical                                         # the acceptance harness: eight
                                                        # projects this engine was not
                                                        # developed against
./bin/rt ruby -Ilib -Itest test/e2e/campaign_test.rb   # end to end against the fixtures
./bin/rt sh -c 'cd /app && ruby -Ilib -Itest -e "Dir[\"test/{core,adapters,cli}/**/*_test.rb\"].sort.each { |f| require File.expand_path(f) }"'
```

`harness/` is the answer to "is this practical". Each case is a small project with a claim
written before the engine was allowed to see the result, and `harness/README.md` states the
criteria, the oracle rules and the rule that a criterion may be tightened but not loosened.

`example/` is a cart of 33 lines with a minitest suite, and it ships the campaign output that
suite produces, so a reader can see a report before reading the design. `AGENTS.md` is the working
agreement for changes to this repository.

`formal/` proves the engine's pure part in Lean and model-checks the runner's pool in Quint. Its
regression probes run at the end of `./bin/check`; the proofs need the Lean and Quint toolchain,
so `./bin/formal` runs them on their own. `formal/README.md` lists what is proven and what is
trusted.

`docs/DESIGN.md` is the contract the implementation was built against: value objects, operator
protocol, mutant lifecycle, aridity rules, and the minitest APIs that were verified by probing
rather than guessed. `fixture/` holds the small projects the tests run against: a minitest calc,
a load-time plugin, a source corpus, and a Rails app.
