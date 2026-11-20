# frozen_string_literal: true

require_relative "../../lib/support"
require "fileutils"

# Claim: a 2k-line project with 60 tests finishes inside a budget, and selection is
# worth several times its own cost.
# Falsified by: exceeding the budget, or a sampled verdict that disagrees with the oracle.
#
# The project is generated into a temporary directory instead of being committed: 20
# classes of about 99 lines each and 60 tests over 10 files, all from one seed, so the
# manifest, the mutant set and the sample are the same on every run. Every source line
# is visible in BODIES below, which is what a reviewer needs to read the fixture.
module ScaleFixture
  SEED = 0x5CA1E
  FILE_COUNT = 20
  METHODS_PER_CLASS = 8
  TEST_COUNT = 60
  TEST_FILES = 10
  THREE_TEST_METHODS = 10
  ROWS = 2000

  METHOD_ORDER = %i[total classify label trim scale merge describe alternate].freeze

  # The class body: eight methods over arithmetic, branches, string building and
  # collections. Comment lines make each method's contract readable; blank lines are
  # there because real code has them.
  BODIES = {
    total: <<~'RUBY',
      # Adds a scaled base to a branch-dependent extra, then takes a modulo penalty.
      def total(value)
        return 0 if value <= 0
        return K if value == 1

        base = value * K + OFFSET
        extra = value > 10 ? base / 2 : base - 3
        penalty = value % 7 == 0 ? K : 0
        sum = base + extra - penalty
        sum.negative? ? 0 : sum
      end
    RUBY
    classify: <<~'RUBY',
      # Names the bucket a value falls into, with sign taking precedence over size.
      def classify(value)
        bucket = value % 5
        return "zero" if bucket.zero?
        return "below" if value.negative?

        case bucket
        when 1, 2 then "low"
        when 3 then "mid"
        else "high"
        end
      end
    RUBY
    label: <<~'RUBY',
      # Builds a stable label from a name and a value; blank names become "anon".
      def label(name, value)
        word = name.to_s.strip.downcase
        return "anon|0:#{K}" if word.empty?

        head = word[0, 2].to_s.upcase
        sign = value.negative? ? "neg" : "pos"
        "#{head}|#{word}|#{sign}:#{value}:#{K}"
      end
    RUBY
    trim: <<~'RUBY',
      # Keeps the items above the class constant, doubles them and sums the result.
      def trim(items)
        return 0 if items.empty?

        kept = items.select { |item| item > K }
        doubled = kept.map { |item| item * 2 }
        doubled.sum
      end
    RUBY
    scale: <<~'RUBY',
      # Multiplies every non-zero item by the factor and shifts it by the constant.
      def scale(items, factor)
        return [] if items.empty?

        items.map do |item|
          next item if item.zero?

          step = item * factor
          step + K
        end
      end
    RUBY
    merge: <<~'RUBY',
      # Concatenates two lists, drops duplicates and returns them in order.
      def merge(first, second)
        combined = first + second
        return [] if combined.empty?

        combined.uniq.sort
      end
    RUBY
    describe: <<~'RUBY',
      # Summarises a list as its first three items plus how many are left over.
      def describe(items)
        return "items=none rest=0" if items.empty?

        head = items.first(3).map { |item| item.to_s }.join(",")
        rest = items.drop(3).size
        label = items.empty? ? "none" : head
        "items=#{label} rest=#{rest} k=#{K}"
      end
    RUBY
    alternate: <<~'RUBY'
      # Halves even values, triples large odd ones and shifts the rest down.
      def alternate(value)
        return OFFSET if value.zero?

        if value.even?
          value / 2 + OFFSET
        elsif value > 20
          value * 3 - K
        else
          value - OFFSET
        end
      end
    RUBY
  }.freeze

  # How one test replays a method over ROWS rows. The call feeds the method under test
  # from a neighbouring method of the same class, so one test covers two methods;
  # `aggregate` reduces that method's return value so the block yields one integer.
  SHAPES = {
    total: { call: "unit.total(unit.alternate((i % 37) - 4))", aggregate: nil },
    classify: { call: "unit.classify(unit.alternate((i % 37) - 4))", aggregate: :length },
    label: { call: 'unit.label("unit", unit.total((i % 41) - 5))', aggregate: :length },
    trim: { call: "unit.trim(unit.scale([i % 9, i % 5], 2))", aggregate: nil },
    scale: { call: "unit.scale(unit.merge([i % 7, 3], [i % 4]), (i % 7) - 2)", aggregate: :sum },
    merge: { call: "unit.merge(unit.scale([i % 5, 2], 3), [i % 4])", aggregate: :sum },
    describe: { call: "unit.describe(unit.merge([i % 10, i % 9, i % 8], [i % 7, i % 6, i % 5]))",
                aggregate: :length },
    alternate: { call: "unit.alternate(unit.total((i % 41) - 5))", aggregate: nil }
  }.freeze

  # Exact values at the boundaries, appended to every test so a kill has a readable
  # failure instead of only a bare integer.
  SAMPLES = {
    total: [[0], [3], [11], [-4], [27]],
    classify: [[0], [3], [4], [-1], [9]],
    label: [[" Unit ", 3], ["", 0], ["x", -2]],
    trim: [[[]], [[1, 2]], [[5, 9, 20]]],
    scale: [[[], 2], [[1, 0, 3], 3], [[2, 7], -1]],
    merge: [[[1, 2], [2, 3]], [[], [4]], [[1, 1], [1]]],
    describe: [[[]], [[1, 2, 3, 4, 5, 6]]],
    alternate: [[0], [5], [8], [-3]]
  }.freeze

  module_function

  # -> { files:, lines:, tests: } for the case note.
  def generate(root)
    rng = Random.new(SEED)
    plans = Array.new(FILE_COUNT) do |index|
      { index: index, names: METHOD_ORDER.rotate(index).first(METHODS_PER_CLASS),
        k: 2 + (index % 5), offset: 10 + index }
    end
    plans.each { |plan| write_unit(root, plan) }
    plans.each { |plan| require File.join(root, "lib", "unit#{format('%02d', plan[:index])}.rb") }

    specs = plan_tests(plans, rng)
    write_tests(root, specs)
    { files: plans.size, lines: Dir[File.join(root, "lib", "*.rb")].sum { |f| File.readlines(f).size },
      tests: specs.size }
  end

  def write_unit(root, plan)
    klass = format("Unit%02d", plan[:index])
    body = plan[:names].map { |name| BODIES.fetch(name) }.join("\n")
               .gsub(/^/, "    ").gsub(/[ \t]+$/, "")
    text = <<~RUBY
      # frozen_string_literal: true

      module Bench
        # #{klass}: arithmetic, branches, string building and collection calls over one
        # small constant. Every method is a few expressions, so a one-per-line campaign has
        # a mutant to try on most of them.
        class #{klass}
          K = #{plan[:k]}
          OFFSET = #{plan[:offset]}

      #{body}
        end
      end
    RUBY
    path = File.join(root, "lib", "unit#{format('%02d', plan[:index])}.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # Ten seeded methods get three tests each, thirty more get one, the rest get none:
  # 60 tests over 160 methods, which is the uneven coverage the claim is about.
  def plan_tests(plans, rng)
    pairs = plans.flat_map do |plan|
      plan[:names].map { |name| [plan[:index], name] }
    end
    order = pairs.shuffle(random: rng)
    counts = {}
    order.first(THREE_TEST_METHODS).each { |pair| counts[pair] = 3 }
    order[THREE_TEST_METHODS, TEST_COUNT - (THREE_TEST_METHODS * 3)].each { |pair| counts[pair] = 1 }
    raise "test count mismatch" unless counts.values.sum == TEST_COUNT

    counts.flat_map do |(index, name), count|
      Array.new(count) { |ordinal| { index: index, name: name, ordinal: ordinal } }
    end
  end

  def write_tests(root, specs)
    helper = +"# frozen_string_literal: true\n\nrequire \"minitest/autorun\"\n"
    FILE_COUNT.times { |i| helper << "require \"unit#{format('%02d', i)}\"\n" }
    helper << "\n# Rows each bulk assertion replays a method over.\nROWS = #{ROWS}\n"
    FileUtils.mkdir_p(File.join(root, "test"))
    File.write(File.join(root, "test", "test_helper.rb"), helper)

    buckets = Array.new(TEST_FILES) { [] }
    specs.each_with_index { |spec, position| buckets[position % TEST_FILES] << spec }
    buckets.each_with_index do |bucket, file_index|
      text = +"# frozen_string_literal: true\n\nrequire_relative \"test_helper\"\n\n"
      text << "class Batch#{format('%02d', file_index)}Test < Minitest::Test\n"
      bucket.each_with_index { |spec, position| text << render_test(spec, position) }
      text << "end\n"
      File.write(File.join(root, "test", "batch#{format('%02d', file_index)}_test.rb"), text)
    end
  end

  def render_test(spec, position)
    name = spec[:name]
    klass = format("Bench::Unit%02d", spec[:index])
    shape = SHAPES.fetch(name)
    aggregate = shape[:aggregate] ? ".#{shape[:aggregate]}" : ""
    expression = "(1..ROWS).sum { |i| #{shape[:call]}#{aggregate} }"
    unit = Object.const_get(klass).new
    expected = eval(expression.sub("ROWS", ROWS.to_s), binding, __FILE__, __LINE__)

    out = +"\n  # #{klass}##{name}, test #{spec[:ordinal] + 1}: one bulk replay over ROWS rows\n"
    out << "  # plus exact values at the boundaries.\n"
    out << "  def test_unit#{format('%02d', spec[:index])}_#{name}_#{('a'.ord + position).chr}\n"
    out << "    unit = #{klass}.new\n"
    out << "    assert_equal #{expected}, #{expression}\n"
    SAMPLES.fetch(name).each do |args|
      value = unit.public_send(name, *args)
      out << "    assert_equal #{value.inspect}, unit.#{name}(#{args.map(&:inspect).join(', ')})\n"
    end
    out << "  end\n"
  end
end

# The cheap budget: the measured cold run on a 20-core machine is ~2.8s, so 15s is a
# little over 5x. That catches a blowup in analysis or a lost selection without going
# red on a loaded host.
CHEAP_BUDGET_SECONDS = 15

# Selection has to buy at least this much wall clock against the whole-suite oracle.
SELECTION_FACTOR = 3

# The oracle sample: 15 mutants drawn from the ids both sides measured, with a fixed
# seed so a red row can be reproduced. 15 of ~316 comparable mutants is enough to catch
# a systematic disagreement, which is the failure worth finding; the count is small
# because each row already carries both verdicts.
SAMPLE_SIZE = 15
SAMPLE_SEED = 0x5CA1E5

practical_case("scale") do |k|
  Dir.mktmpdir("practical-scale") do |dir|
    shape = ScaleFixture.generate(dir)
    k.note("generated #{shape[:files]} files, #{shape[:lines]} lines, #{shape[:tests]} tests;")

    # Each `./bin/rt` call is a fresh container, so the engine is cold in the sense that
    # matters: no cache entry from an earlier run can shorten either side.
    cold = { "RUBY_MUTATION_NO_CACHE" => "1" }

    # ---- 1. the cheap run ---------------------------------------------------------
    cheap_seconds = k.elapsed do
      @cheap = k.run(dir, "run", "lib", "--report=json", "--timeout=30", env: cold)
    end
    cheap_out, cheap_err, cheap_code = @cheap
    cheap = k.parse_report(cheap_out)
    k.assert_equal("cheap run exits 0", 0, cheap_code, cheap_err.to_s.lines.last.to_s)
    k.assert("cheap report parses", !cheap.nil?, cheap_out.to_s.lines.last(3).join)
    next if cheap.nil?

    k.assert_equal("cheap run reports no error mutants", 0, cheap["error"])
    k.assert_operator("cheap run measures at least 200 mutants", cheap["mutants"].to_i, :>=, 200)
    slowest = cheap["results"].map { |result| result["duration"].to_f }.max.to_f
    k.assert_operator("no mutant outlives the 30s deadline", slowest, :<=, 30.5,
                      "slowest was #{slowest.round(3)}s")

    # ---- 2. the cheap budget -----------------------------------------------------
    k.assert_operator("cheap run finishes inside #{CHEAP_BUDGET_SECONDS}s",
                      cheap_seconds, :<, CHEAP_BUDGET_SECONDS,
                      "took #{cheap_seconds.round(2)}s")

    # ---- 3. the oracle and the ratio ---------------------------------------------
    oracle_seconds = k.elapsed do
      @oracle = k.run(dir, "run", "lib", "--report=json", "--timeout=30",
                      "--no-coverage", "--no-weak", env: cold)
    end
    oracle_out, oracle_err, oracle_code = @oracle
    oracle = k.parse_report(oracle_out)
    k.assert_equal("oracle run exits 0", 0, oracle_code, oracle_err.to_s.lines.last.to_s)
    k.assert("oracle report parses", !oracle.nil?, oracle_out.to_s.lines.last(3).join)
    next if oracle.nil?

    k.assert_equal("oracle run reports no error mutants", 0, oracle["error"])
    k.assert_equal("both sides measured the same mutant set", cheap["mutants"], oracle["mutants"])
    ratio = oracle_seconds / cheap_seconds
    k.assert_operator("cheap is at least #{SELECTION_FACTOR}x faster than the oracle",
                      ratio, :>=, SELECTION_FACTOR,
                      "cheap #{cheap_seconds.round(2)}s, oracle #{oracle_seconds.round(2)}s, " \
                      "ratio #{ratio.round(2)}x")
    k.note(format("cheap %.2fs, oracle %.2fs, ratio %.1fx;", cheap_seconds, oracle_seconds, ratio))

    # ---- 4. the sampled verdicts -------------------------------------------------
    rows = k.comparable(cheap, oracle)
    k.note("#{rows.size} comparable mutants;")
    k.assert_operator("the sample has enough measured mutants to draw from",
                      rows.size, :>=, SAMPLE_SIZE)
    sample = if rows.size >= SAMPLE_SIZE
               rows.sample(SAMPLE_SIZE, random: Random.new(SAMPLE_SEED))
             else
               rows
             end
    disagreeing = k.diff_rows(sample)
    k.assert("the #{SAMPLE_SIZE} sampled verdicts match the oracle", disagreeing.empty?,
             disagreeing.map { |id, cheap_status, oracle_status|
               "#{id}: cheap #{cheap_status}, oracle #{oracle_status}"
             }.join("\n"))
    k.note("#{sample.size} sampled, #{disagreeing.size} disagree;")

    # ---- 5. jobs at size ----------------------------------------------------------
    jobs_seconds = k.elapsed do
      @parallel = k.run(dir, "run", "lib", "--report=json", "--timeout=30",
                        "--jobs=4", env: cold)
    end
    parallel_out, parallel_err, parallel_code = @parallel
    parallel = k.parse_report(parallel_out)
    k.assert_equal("--jobs=4 run exits 0", 0, parallel_code, parallel_err.to_s.lines.last.to_s)
    k.assert("--jobs=4 report parses", !parallel.nil?, parallel_out.to_s.lines.last(3).join)
    next if parallel.nil?

    k.assert_equal("--jobs=4 run reports no error mutants", 0, parallel["error"])
    k.assert_operator("--jobs=4 finishes faster than --jobs=1",
                      jobs_seconds, :<, cheap_seconds,
                      "--jobs=1 #{cheap_seconds.round(2)}s, --jobs=4 #{jobs_seconds.round(2)}s")
    serial_map = k.verdicts(cheap)
    parallel_map = k.verdicts(parallel)
    changed = (serial_map.keys | parallel_map.keys).sort.reject do |id|
      serial_map[id] == parallel_map[id]
    end
    k.assert("--jobs=4 reports the same status map as --jobs=1", changed.empty?,
             changed.first(5).map { |id|
               "#{id}: --jobs=1 #{serial_map[id].inspect}, --jobs=4 #{parallel_map[id].inspect}"
             }.join("\n"))
    k.note(format("jobs1 %.2fs, jobs4 %.2fs;", cheap_seconds, jobs_seconds))

    # Deleted before the case returns: the fixture is generated, never committed.
  end
end
