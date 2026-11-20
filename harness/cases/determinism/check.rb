# frozen_string_literal: true

require_relative "../../lib/support"
require "json"

# Claim: the same tree gives the same report, cold or warm, and a new test changes it.
# Falsified by: cold runs that differ, a cache that returns a stale verdict, or a new
# covering test that leaves the survivor in place.
practical_case("determinism") do |k|
  cold_env = { "RUBY_MUTATION_NO_CACHE" => "1" }
  # --per-line=all is what puts the boundary comparison in the campaign: the default
  # one-per-line keeps a whole-condition replacement instead, which the suite already
  # kills and which says nothing about the missing edge.
  run_args = ["run", "lib", "--per-line=all", "--report=json"]

  campaign = lambda do |dir, env|
    out = err = nil
    code = nil
    wall = k.elapsed { out, err, code = k.run(dir, *run_args, env: env, timeout: 120) }
    { payload: k.parse_report(out), code: code, err: err.to_s, out: out.to_s, wall: wall }
  end

  # Every id whose status differs between two status maps, in the first map's order.
  differing = lambda do |left, right|
    (left.keys | right.keys).reject { |id| left[id] == right[id] }
  end

  cache_json = lambda do |path|
    next nil unless File.file?(path)

    JSON.parse(File.read(path))
  rescue SystemCallError, JSON::ParserError
    nil
  end

  k.copy_project do |dir|
    # The untested tier boundary, located by text so the fixture can move without the
    # case aiming at a stale line number.
    source = File.readlines(k.project("lib", "billing.rb"))
    boundary_index = source.index { |text| text.include?("total > SMALL_TOTAL") }
    k.assert("the fixture contains the untested boundary", !boundary_index.nil?)
    next if boundary_index.nil?

    boundary_line = boundary_index + 1

    # ---- 1. three cold runs must agree -------------------------------------
    colds = Array.new(3) { campaign.call(dir, cold_env) }
    colds.each_with_index do |run, index|
      k.assert_equal("cold run #{index + 1} exits 0", 0, run[:code], run[:err].lines.last(5).join)
      k.assert("cold run #{index + 1} prints a JSON report", !run[:payload].nil?,
               "#{run[:err].lines.last(5).join}#{run[:out].lines.last(3).join}")
    end
    next if colds.any? { |run| run[:payload].nil? }

    base_payload = colds.first[:payload]
    base = k.verdicts(base_payload)
    base_score = base_payload["score"]
    k.assert_operator("the fixture leaves survivors for a new test to kill", base_payload["survived"], :>, 0)
    k.assert_operator("the fixture leaves kills for the cache to keep", base_payload["killed"], :>, 0)
    k.assert_equal("no cold mutant failed to run", 0, base_payload["error"])

    colds.each_with_index do |run, index|
      changed = differing.call(base, k.verdicts(run[:payload]))
      k.assert("cold run #{index + 1} gives the same status map", changed.empty?,
               "#{changed.size} ids differ: #{changed.first(6).inspect}")
      k.assert_equal("cold run #{index + 1} reports the same score", base_score, run[:payload]["score"])
      k.assert_equal("cold run #{index + 1} mutates the same number of sites", base_payload["mutants"],
                     run[:payload]["mutants"])
    end

    # ---- the survivor the new test will kill -------------------------------
    results = base_payload["results"]
    boundary = results.select do |result|
      mutant = result["mutant"]
      mutant["path"] == "lib/billing.rb" && mutant["line"] == boundary_line
    end
    boundary_survivors = boundary.select { |result| result["status"] == "survived" }
    k.assert_operator("the boundary line carries mutants", boundary.size, :>, 0)
    k.assert_equal("exactly one mutant survives the untested boundary", 1, boundary_survivors.size,
                   boundary_survivors.map { |result| "#{result["mutant"]["id"]} #{result["mutant"]["replacement"]}" }.inspect)
    target = boundary_survivors.first
    next if target.nil?

    target_id = target["mutant"]["id"]
    k.assert("the survivor is the relaxed `>` comparison", target["mutant"]["replacement"].to_s.include?(">="),
             target["mutant"]["replacement"].inspect)
    cold_durations = results.to_h { |result| [result["mutant"]["id"], result["duration"].to_f] }
    executed = cold_durations.select { |_id, seconds| seconds.positive? }.keys

    # ---- 2. a warm run on the same tree must agree, and cost nothing --------
    # The cold runs hold no cache, so the first cache-enabled run is the one that
    # pays; only the run after it can answer from the cache. Both must agree.
    prime = campaign.call(dir, {})
    k.assert_equal("the priming run exits 0", 0, prime[:code], prime[:err].lines.last(5).join)
    if prime[:payload]
      changed = differing.call(base, k.verdicts(prime[:payload]))
      k.assert("the priming run gives the same status map", changed.empty?, changed.first(6).inspect)
    else
      k.assert("the priming run prints a JSON report", false, prime[:out].lines.last(3).join)
    end

    warm = campaign.call(dir, {})
    k.assert_equal("the warm run exits 0", 0, warm[:code], warm[:err].lines.last(5).join)
    k.assert("the warm run prints a JSON report", !warm[:payload].nil?, warm[:out].lines.last(3).join)
    next if warm[:payload].nil?

    warm_map = k.verdicts(warm[:payload])
    changed = differing.call(base, warm_map)
    k.assert("the warm run gives the same status map as the cold runs", changed.empty?,
             "#{changed.size} ids differ: #{changed.first(6).inspect}")
    k.assert_equal("the warm run reports the same score", base_score, warm[:payload]["score"])

    warm_durations = warm[:payload]["results"].to_h { |result| [result["mutant"]["id"], result["duration"].to_f] }
    k.assert("the cold runs actually measured mutants", executed.size.positive?, "#{executed.size} of #{results.size}")
    measured = executed.select { |id| warm_durations.key?(id) }
    k.assert("at least one warm result is a cache hit", measured.size.positive?,
             "#{measured.size} ids were measured cold and answered warm")
    stale = measured.select { |id| warm_durations[id] != 0.0 }
    k.assert_equal("every cached result reports duration 0.0", [], stale)
    k.note(format("cache hits=%d/%d", measured.size, executed.size))

    fastest_cold = colds.map { |run| run[:wall] }.min
    k.assert("the warm run is strictly faster in wall clock", warm[:wall] < fastest_cold,
             "warm #{format("%.3f", warm[:wall])}s vs fastest cold #{format("%.3f", fastest_cold)}s")
    k.note(format("cold walls=%s warm=%.3fs", colds.map { |run| format("%.3f", run[:wall]) }.join("/"), warm[:wall]))

    # ---- 6. the cache file a warm run leaves behind -------------------------
    cache_path = File.join(dir, ".mutation-cache.json")
    cache = cache_json.call(cache_path)
    k.assert("the cached run writes .mutation-cache.json", File.file?(cache_path))
    k.assert("the cache file parses as JSON", cache.is_a?(Hash),
             File.file?(cache_path) ? File.read(cache_path)[0, 120] : "missing")
    k.assert("the cache file records a format version", cache.is_a?(Hash) && cache["version"].is_a?(Integer))
    entries = cache.is_a?(Hash) && cache["entries"].is_a?(Hash) ? cache["entries"] : {}
    k.assert_operator("the cache file holds the warm run's answers", entries.size, :>, 0)

    # ---- 3. the missing test must kill the survivor -------------------------
    learning = <<~RUBY
      # frozen_string_literal: true

      require "minitest/autorun"
      require "billing"

      # The boundary the suite was missing: at exactly the tier the refund still pays
      # the handling fee, so relaxing `>` to `>=` becomes visible.
      class LearningTest < Minitest::Test
        def test_charges_the_fee_at_the_tier_boundary
          assert_equal 5, Billing::Refund.new(Billing::Refund::SMALL_TOTAL).handling_fee
        end
      end
    RUBY
    k.write(dir, "test/learning_test.rb", learning)
    learned = campaign.call(dir, {})
    k.assert_equal("the run after the new test exits 0", 0, learned[:code], learned[:err].lines.last(5).join)
    k.assert("the run after the new test prints a JSON report", !learned[:payload].nil?,
             learned[:out].lines.last(3).join)
    next if learned[:payload].nil?

    learned_map = k.verdicts(learned[:payload])
    learned_score = learned[:payload]["score"]
    k.assert_equal("the mutant set is unchanged by the new test", base.keys.sort, learned_map.keys.sort)
    k.assert_equal("the new covering test kills the boundary mutant", "killed", learned_map[target_id],
                   "mutant #{target_id} (#{target["mutant"]["replacement"]}): " \
                   "cold=#{base[target_id].inspect}, warm=#{warm_map[target_id].inspect}, " \
                   "with learning test=#{learned_map[target_id].inspect}")
    k.assert_operator("the score rises with the new test", learned_score, :>, base_score,
                      "cold #{base_score}, with learning test #{learned_score}")
    k.assert_equal("the new test changes only the boundary mutant", [target_id],
                   differing.call(base, learned_map))
    k.note(format("scores cold=%.4f learned=%.4f", base_score, learned_score))

    # ---- 4. deleting the test must bring the verdict back -------------------
    File.unlink(File.join(dir, "test", "learning_test.rb"))
    removed = campaign.call(dir, {})
    k.assert_equal("the run after the deletion exits 0", 0, removed[:code], removed[:err].lines.last(5).join)
    k.assert("the run after the deletion prints a JSON report", !removed[:payload].nil?,
             removed[:out].lines.last(3).join)
    next if removed[:payload].nil?

    removed_map = k.verdicts(removed[:payload])
    k.assert_equal("deleting the test returns the mutant to survived", "survived", removed_map[target_id],
                   "mutant #{target_id}: with learning test=#{learned_map[target_id].inspect}, " \
                   "after deletion=#{removed_map[target_id].inspect}")
    k.assert_equal("deleting the test returns the cold score", base_score, removed[:payload]["score"])
    k.assert("deleting the test restores the cold report", differing.call(base, removed_map).empty?,
             differing.call(base, removed_map).first(6).inspect)

    # ---- 5. an edit that cannot change a verdict must not break the report ---
    refunds = File.join(dir, "test", "refund_test.rb")
    original = File.read(refunds)
    needle = "assert_equal 5, Billing::Refund.new(10).handling_fee"
    k.assert("the fixture has an assertion to annotate", original.include?(needle))
    k.write(dir, "test/refund_test.rb", original.sub(needle, "#{needle}, \"the small tier still pays a fee\""))
    annotated = campaign.call(dir, {})
    k.assert_equal("a message-only edit exits 0", 0, annotated[:code], annotated[:err].lines.last(5).join)
    k.assert("a message-only edit prints a JSON report", !annotated[:payload].nil?,
             annotated[:out].lines.last(3).join)
    next if annotated[:payload].nil?

    k.assert_equal("a message-only edit changes no verdict", [], differing.call(base, k.verdicts(annotated[:payload])))
    k.assert_equal("a message-only edit keeps the score", base_score, annotated[:payload]["score"])
    k.assert_equal("a message-only edit leaves no mutant erroring", 0, annotated[:payload]["error"])

    cache = cache_json.call(cache_path)
    k.assert("the cache file still parses after a re-invalidating edit",
             cache.is_a?(Hash) && cache["entries"].is_a?(Hash),
             File.file?(cache_path) ? File.read(cache_path)[0, 120] : "missing")
    k.assert_operator("the cache file still holds entries",
                      cache.is_a?(Hash) && cache["entries"].is_a?(Hash) ? cache["entries"].size : 0, :>, 0)
  end
end
