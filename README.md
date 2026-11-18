# ruby-mutation

Mutation testing for Ruby test suites. It rewrites one AST node of your source at a time, runs
**only the tests that cover that line**, and reports the mutants your suite failed to notice.

The measurement follows Petrovic and Ivankovic, *"State of Mutation Testing at Google"*
(ICSE-SEIP 2018). Four of their ideas decide the design here:

| Paper | This library |
| --- | --- |
| Mutate only the lines a change touches | `--diff=FILE.json` restricts mutants to listed lines |
| Never mutate a line without statement coverage | a mutant with no covering test is `uncovered`, never run, never scored |
| Suppress *arid* nodes that tests cannot usefully assert on | `Mutation::Aridity`, Ruby rules, recursive over compound nodes |
| At most one mutant per line | deterministic seed-derived pick per line, `--per-line=N` to widen |

## Install

```ruby
# Gemfile
gem "ruby-mutation", require: false
```

Requires Ruby 3.2 or newer. Prism (the parser) ships with Ruby from 3.3. Verified against
minitest 5.25 and 6.1, and rspec 3.13, on Ruby 3.4.12.

## Run

```sh
# from your project root: minitest suite in test/, sources in lib/
mutation run --adapter=minitest

# rspec suite in spec/
mutation run --adapter=rspec

# only mutate the lines in a diff
mutation run --diff=changed_lines.json --adapter=minitest

# what would run, without running it
mutation list

# environment check
mutation doctor
```

```
ruby-mutation 0.1.0  adapter=minitest  files=1  mutants=11  jobs=1

  killed         8   72.7%
  survived       2   18.2%  <- your tests did not notice these
  timeout        0    0.0%  <- killed by the clock, not by a test
  uncovered      1    9.1%  (no test covers the line; not scored)

  mutation score   80.0%  (killed / killed+survived+timeout)

survivors:
  lib/pricing.rb:25  ROR: volume >= 5 -> volume == 5
  lib/pricing.rb:26  AOR: subtotal * 0.05 -> subtotal % 0.05
```

Exit codes are `0` ok, `1` when the reported score is below `--min-score`, `2` error,
so CI can gate on the score:

```sh
mutation run --adapter=rspec --min-score=70 --report=json --output=mutation.json
```

The reported score is printed at one decimal and `--min-score` compares that same value, so the
number in the output and the exit code cannot disagree.

A survivor names a line and the rewrite that survived. Line 25 above says the five-item volume
tier has no test at all: the suite only exercises the ten-item tier.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `--adapter=minitest\|rspec` | `minitest` | which suite to drive |
| `--jobs=N` | `1` | mutants in flight at once |
| `--timeout=SEC` | `5` | per-mutant deadline |
| `--seed=N` | `0` | fixes the per-line operator choice |
| `--operators=aor,ror,...` | all | restrict mutation operators |
| `--per-line=N\|all` | `1` | mutants kept per line; `all` keeps every candidate |
| `--diff=PATH` | off | JSON `{"path" => [lines]}` allowlist |
| `--since=REV` | off | only mutate the lines that changed since a git revision |
| `--fail-fast` | off | stop at the first survivor and report the rest as `skipped` |
| `--[no-]baseline` | on | abort when a test fails with no mutation applied |
| `--env=KEY=VALUE` | none | set an ENV entry before the suite loads (repeatable) |
| `--require=PATH` | none | require after coverage starts, before the tests (repeatable) |
| `--setup=PATH` | none | Ruby file with boot hooks for Rails and friends |
| `--[no-]coverage` | on | test selection; `--no-coverage` runs the whole suite per mutant |
| `--isolation=fork\|process` | `fork` | reload a preloaded suite, or boot a fresh process |
| `--report=terminal\|json\|quiet` | `terminal` | output |
| `--output=PATH` | none | write the JSON report |
| `--min-score=PCT` | none | exit 1 when the reported score is below this |
| `--exclude=GLOB` | none | skip files |
| `--limit=N` | none | cap the mutant count |

Run it from the project root. `lib`, `test` and `spec` are put on `$LOAD_PATH`, and test files
are discovered with `test/**/*_test.rb` or `spec/**/*_spec.rb`. Set `RUBY_MUTATION_TEST_GLOB`
to override the pattern. Set `RUBY_MUTATION_NO_CACHE=1` to ignore the result cache.

## What it does, in five stages

```
Source (Prism AST) --operators--> candidates --aridity--> --diff--> --per line--> Mutants
                                                                                 |
CoverageMap (which test hits which line) --- tests_for ---> selected test ids --->|
                                                                                 v
                                              Runner: fork, reload mutated file, run ids
                                                                                 |
                        survived | killed | timeout | error | uncovered  <--------'
```

1. **Analyze.** Each file is parsed once with Prism. Every node the enabled operators claim
   produces candidate rewrites as byte-range splices. `Replacement#original` must equal the
   exact source slice or the run fails loudly rather than emitting a no-op mutant.
2. **Suppress aridity.** Nodes whose mutation no test can meaningfully assert on are dropped,
   along with the guarded debug-log lines that only serve logging.
3. **Select per line.** Candidates are grouped by `(path, line)`; one survives, chosen from a
   seed so two runs on the same code pick the same mutant. That is the paper's one-mutant-per-line
   rule, which keeps the report readable and stops the same line being surfaced five times.
4. **Collect coverage.** The suite runs once, instrumented, and every test's newly-hit lines are
   recorded. A mutant with no covering test is `uncovered`: not run, not scored.
5. **Execute.** For each remaining mutant the parent forks, the child re-evaluates the mutated
   file, runs the selected tests, and reports through a pipe. The parent enforces the deadline,
   kills and reaps, and classifies the exit.

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
whole pool the way mutant does.

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

A compound node is arid when every child is arid, which is the paper's rule. The database,
network or filesystem call in an `if` body keeps that `if` live.

## Rails

`--setup` gives a Rails app the four hooks it needs: `env`, `require_path`, `after_boot`
(`eager_load!`), `before_fork` (disconnect the pool), and `child_start` (per-child database).
[`docs/rails.md`](docs/rails.md) has the recipes for transactional fixtures, per-child SQLite
copies, and PostgreSQL templates, plus what can and cannot be targeted.

## Cost

Measured by `bench/`, which was written before the engine and still runs against it. Ruby 3.4.12,
20 cores, 5 alternating repetitions per mode, container startup outside the timed region.

Primitive costs (`bench/micro.rb`, median):

| operation | median | limiter |
| --- | ---: | --- |
| fork + wait | 2.09 ms | fork syscall and scheduler wakeup; bimodal 0.7 / 2.2 ms |
| spawn `ruby -e ''` | 29.97 ms | interpreter boot |
| Prism parse, 27-line file | 50.6 µs | parse |
| Prism parse, 500-line file | 610.9 µs | parse |
| `Coverage.start` + `peek_result` + load | 126.9 µs | coverage instrumentation |

Campaign on the minitest fixture (`bench/campaign.rb`, 5 reps, wall/mutant):

| mode | wall/mutant | what it measures |
| --- | ---: | --- |
| fresh process, whole suite per mutant | 48.7 ms | what a naive tool costs |
| forked child, whole suite per mutant | 6.7 ms | preload reuse without test selection |
| this engine, 11 mutants | 8.8 ms | startup dominates at small N |
| this engine, 30 mutants | 2.95 ms | fixed startup amortised, child p50 1.5 ms |

Selection is what buys the last factor: a mutant runs one or two tests instead of six on that
fixture. A fresh process per mutant is capped at about 33 mutants/s by interpreter boot, which is
why fork is the default isolation and process is the fallback.

## Limits

These are real and deliberate; know them before trusting a score.

- **Mutations are applied by re-evaluating the file.** Method bodies, constants and class-level
  code re-execute correctly. Code behind `define_method` (the block is not re-run), `Struct` and
  `Data` field lists, and anything that would change a superclass cannot be redefined this way.
- **`require_relative` and `__FILE__` resolve against the original path**, because the child
  evaluates the mutated text with that path. Files that depend on load order or on `END` blocks
  may not reload cleanly.
- **Per-test coverage is collected by running the suite once, instrumented.** On a large suite
  that pass is the dominant fixed cost of a campaign. It is not cached.
- **`before(:suite)` / `after(:suite)` hooks do not run for a selected subset**, and rspec
  filters (`:focus`, `:if`) are ignored when selecting.
- **Lines executed only at load time** are not attributed to any test, so a mutant whose only
  execution is class-body code is `uncovered`.
- **`uncovered` and `error` never enter the score.** They are reported separately so a file with
  no coverage cannot inflate the number.

## Development

There is no Ruby on the host machine used for this work, so everything runs in the dev container:

```sh
./bin/check                                             # unit + e2e under minitest 5 and 6,
                                                        # bench gate, packaged gem smoke test
./bin/rt ruby -Ilib -Itest test/e2e/campaign_test.rb   # end to end against the fixtures
./bin/rt sh -c 'cd /app && ruby -Ilib -Itest -e "Dir[\"test/{core,adapters,cli}/**/*_test.rb\"].sort.each { |f| require File.expand_path(f) }"'
./bin/rt ruby bench/micro.rb && ./bin/rt ruby bench/campaign.rb && ./bin/rt ruby bench/report.rb
```

`docs/DESIGN.md` is the contract the implementation was built against: value objects, operator
protocol, mutant lifecycle, aridity rules, harness JSON schema, and the framework APIs that were
verified by probing rather than guessed. `fixture/` holds two small projects with deliberately
weak assertions, one per framework.
