# Example: a cart with two gaps

A cart in 33 lines of Ruby, plus a minitest suite, to run the engine against before you point it at
your own code. The suite passes, and the report still names two gaps. One is a weak assertion. The
other is a method no test calls at all.

## Run it

From the repository root, inside the dev container:

```sh
./bin/rt sh -c 'cd example && ruby ../bin/mutation run'
```

With the gem installed, run `mutation run` from this directory instead. The output is the same.

```
ruby-mutation 0.1.0  files=1  mutants=5  jobs=1

  killed         3   60.0%
  survived       1   20.0%  <- your tests did not notice these
  timeout        0    0.0%  <- killed by the clock, not by a test
  uncovered      1   20.0%  (no test covers the line; not scored)
    not detected 1, not infected 0

  mutation score   75.0%  (killed / killed+survived+timeout)

survivors:
  lib/pricing.rb:22  AOR: subtotal - discount -> subtotal % discount
```

## What the report says

The analyzer produced five mutants. Each one ended as killed, survived or uncovered.

Three kills:

- `lib/pricing.rb:16` replaces `@prices.sum` with the array itself. Comparing that array with
  `BULK` raises `NoMethodError`, so the run is not green.
- `lib/pricing.rb:20` turns `subtotal < BULK` into `false`, so the 620 cart takes the discount
  path and returns 558. `assert_equal 620` fails.
- `lib/pricing.rb:26` rewrites `subtotal / 10` as `subtotal % 10`, which is 0 for a 1,500 cart.
  The total stays at 1,500 and `assert_operator total, :<, 1_500` fails.

One survivor:

- `lib/pricing.rb:22` rewrites `subtotal - discount` as `subtotal % discount`, which is 0 for the
  1,500 cart. The test asserts only that the total is below 1,500, and 0 is still below 1,500. The
  test ran, saw the new value, and passed. That is `not_detected`, and the fix is an exact value,
  not a new test.

One uncovered line:

- `lib/pricing.rb:30` is the body of `shipping`, and no test calls it. The mutant is never run and
  never scored, which is why the score is 3 of 4 and not 3 of 5. A line without coverage cannot be
  measured, so the engine says so instead of counting it as a survivor.

Run `mutation list` to see the five mutants without executing them. Pass `--min-score=100` and the
campaign exits 1 while any gap remains, so CI can gate on the number.

## Close the gaps

Replace the second test with an exact total, and cover `shipping` at both sides of its threshold:

```ruby
def test_total_above_the_bulk_threshold
  assert_equal 1_350, Shop::Pricing.new([1_500]).total
end

def test_shipping_is_charged_below_the_free_threshold
  assert_equal 500, Shop::Pricing.new([300, 320]).shipping
end

def test_shipping_is_free_above_the_free_threshold
  assert_equal 0, Shop::Pricing.new([6_000]).shipping
end
```

Run the campaign again:

```
ruby-mutation 0.1.0  files=1  mutants=5  jobs=1

  killed         5  100.0%
  survived       0    0.0%  <- your tests did not notice these
  timeout        0    0.0%  <- killed by the clock, not by a test

  mutation score  100.0%  (killed / killed+survived+timeout)
```

The exact assertion kills the survivor, because the mutant total is 0 and the test wants 1,350.
Two tests now execute `shipping`, and the `false` rewrite of its threshold fails the one that
expects 500.

## Keeping this page true

The output above was measured on 2026-11-20 at version 0.1.0. Re-run the command in "Run it" when a
change to the engine or to `lib/pricing.rb` changes the output, and update this page in the same
commit.
