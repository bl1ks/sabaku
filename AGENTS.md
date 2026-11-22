# Repository notes for agents

sabaku mutates one Ruby AST node at a time and runs only the tests that cover the mutated
line. `README.md` says what the tool does. `docs/DESIGN.md` is the contract the engine is built
against: value objects, the operator protocol, the mutant lifecycle, the aridity rules. Code
against that contract, and say so in the commit when a change has to deviate.

## Run the gates

The host has no Ruby. `bin/rt` runs one command inside `sabaku:dev` with this repository
mounted at `/app`, so paths inside a `bin/rt` payload are container paths. The `bin/*` wrappers
themselves run on the host.

| Command | What it covers |
| --- | --- |
| `./bin/check` | Unit and e2e on minitest 6 and minitest 5, a campaign through the built gem, the four formal regressions |
| `./bin/practical` | The ten acceptance cases in `harness/` |
| `./bin/formal` | Lean proofs, the Lean/Ruby replay, the Quint model at six steps. It runs `lake` and `quint` on the host, not in the container |
| `./bin/check-rails` | Rails on SQLite and MySQL, against a throwaway `mysql:8.4` container |

`bin/rt` needs its image once: `docker build -f docker/Dockerfile -t sabaku:dev .`.
`bin/check-rails` needs the Rails image first:
`docker build -f docker/rails.Dockerfile -t sabaku:rails .`.

For the fast loop, run one file:

```sh
./bin/rt ruby -Ilib -Itest test/e2e/campaign_test.rb
```

Two environment variables matter. `SABAKU_TEST_GLOB` overrides test discovery; the CLI reads it
into `Config#test_globs`, and the adapter only takes `test_globs:`.
`SABAKU_NO_CACHE=1` ignores the result cache, and a test that measures a campaign sets it,
because a warm cache hides a runner regression.

## Rules the code depends on

- The score is `killed / (killed + survived + timeout)`. `uncovered`, `error` and `skipped` never
  enter the denominator. A campaign that produced an `error` exits 2.
- Mutants are deterministic. There is no random draw and no seed, so the same tree keeps the same
  mutants. The id hashes path, scope, AST path, operator and replacement, so moving a method keeps
  its cache entry.
- An operator's `original` must equal `source.slice(node)` exactly. The analyzer raises on a
  mismatch instead of emitting a no-op mutant.
- A compound node is arid when every child is arid. A new expert rule only adds aridity.
- Value objects are frozen `Data` objects with `#to_h`, and the JSON report uses that shape.
- The parser is Prism and the test framework is minitest. The gem has no runtime dependency.
- `lib/sabaku/runner.rb` owns the pool. Fork isolation is the default. The first-load surface in
  `lib/sabaku/runtime/` is the fallback for a file that cannot be loaded twice.
- Files under `lib/` and `test/` open with `# frozen_string_literal: true`. Comments explain the
  reason for a non-obvious choice, not what the next line does.

## Surfaces that move together

- Engine change: add the test under `test/`, then run `./bin/check`.
- Covered code (`operators/`, `aridity.rb`, `analyzer.rb`, `report.rb`, `cache.rb`, `runner.rb`):
  run `./bin/formal` and follow `.dsh/skills/formal-verification/SKILL.md`. The record names the
  last commit that changed a covered file, so the model and the replay change in the same commit
  as the code.
- Behaviour a user can see: update `README.md` and `docs/DESIGN.md` in the same commit.
- A harness case is pre-registered. Tightening one is always allowed. Loosening one needs an entry
  in `harness/README.md` that names the invariant that turned out to be wrong. Removing one is not
  allowed.
- Rails hooks or database handling: update `docs/rails.md`, then run `./bin/check-rails`.

## Layout

```
bin/            rt (the container runner), check, practical, formal, check-rails
lib/sabaku/     the engine: config, source, mutant, analyzer, aridity, operators/, weak,
                coverage_map, test_selection, adapters/minitest, runner, report, cache, cli
test/           core, adapters, cli, e2e; small projects under test/**/fixtures
fixture/        projects the tests and the docs run against
example/        the teaching project. Run it, then read its README
formal/         Lean, Quint, replay, regressions. README says what is proven and trusted
harness/        acceptance cases with pre-registered criteria
docs/           DESIGN.md (the contract), rails.md, PERF-ACTIVESUPPORT.md
```

## Commits

The summary is `<area>: <lowercase sentence>`, with areas such as `engine:`, `runner:`, `cli:`,
`cache:`, `analysis:`, `docs:`, `test:`, `harness:`, `formal:`, `rails:`, `bench:` and `chore:`.
The body says what was wrong and why this change fixes it. End with a `Verified:` line naming the
commands that ran and their counts. A change to `lib/` gets `./bin/check` at minimum.

## Example

`example/` is the smallest project a reader can run. Its README prints the campaign output, so a
change that alters that output updates that page in the same commit.
