# frozen_string_literal: true

require_relative "../boot"
require_relative "../coverage_map"
require_relative "../test_selection"
require_relative "../source"
require_relative "../weak"

module Sabaku
  module Adapters
    # Runs every test once with Ruby's stdlib Coverage enabled and records which
    # mutated source lines each test executed.
    #
    # Correctness notes (this feeds test selection, so they matter):
    #
    #   * Coverage must be started *before* `adapter.preload!`, because Ruby
    #     instruments files when they are loaded. The sampler owns that order.
    #   * `Coverage.peek_result` does not reset counters, so each test is
    #     measured as a delta against the snapshot taken immediately before it.
    #     A line hit by two tests therefore records both tests.
    #   * Only files handed in as `sources` are recorded, keyed by the source's
    #     repo-relative path so `CoverageMap#tests_for(mutant.path, ...)` lines
    #     up with `Mutant#path`.
    class CoverageSampler
      # What the probe pass learned, or nil when probes were off or none could run.
      attr_reader :weak_report, :probe_failures

      def initialize(config, adapter, sources, mutants: nil)
        @config = config
        @adapter = adapter
        @sources = Array(sources)
        @mutants = mutants.nil? ? nil : Array(mutants)
        @weak_enabled = !config.respond_to?(:weak) || config.weak
        @weak_report = nil
        @probe_failures = []
      end

      # -> CoverageMap
      def call
        require "coverage"
        Boot.env(@config)

        targets = target_files
        @wanted_lines = @mutants && wanted_lines
        started_here = false
        unless ::Coverage.running?
          if @adapter.respond_to?(:preloaded?) && @adapter.preloaded?
            raise Sabaku::Error,
                  "coverage must be started before the adapter preloads the project; " \
                  "create the adapter, then sample, then run"
          end

          ::Coverage.start(lines: true)
          started_here = true
        end

        # The application has to boot under coverage, or its files are compiled
        # before counters exist and report no hits. `--require` is the seam.
        Boot.require_paths(@config)
        @adapter.preload!
        Boot.fire(@config, :after_boot)
        # In an embedded process the project may already have required the
        # mutated files before we started Coverage; Ruby only instruments files
        # when they are compiled, so those files would silently report no hits.
        # Reload exactly those targets now, while Coverage is on.
        unreloadable = ensure_targets_instrumented!(targets)
        previous = snapshot
        map = CoverageMap.empty
        files = describe_boot(targets, previous, unreloadable)

        failures = []
        @adapter.test_ids.each do |test_id|
          outcome = begin
            @adapter.run([test_id])
          rescue StandardError => e
            MinitestAdapter::Outcome.new(ok: false, failed_id: test_id, error: e)
          end
          # A failing test still has valid coverage; keep sampling so the report
          # can name every test that has to be fixed.
          failures << [test_id, outcome] unless outcome.ok?
          current = snapshot
          hits = diff_hits(previous, current, targets)
          map.record(test_id, hits) unless hits.empty?
          note_first_loads(files, hits, test_id)
          previous = current
        end
        files.each_value { |file| map.describe(file) }

        verify_baseline!(failures)
        @weak_report = collect_weak(targets, map)
        map
      ensure
        Weak.test_id = nil
        ::Coverage.result if started_here && ::Coverage.running?
      end

      private

      # The weak pass runs after the coverage pass, because code compiled by `eval` is
      # not instrumented: doing both in one pass would erase the probed files' line
      # counts. The price is one extra run of the selected suites, paid only when there
      # are mutants a probe can decide.
      def collect_weak(targets, map)
        return nil unless @weak_enabled && @mutants

        eligible = Weak.eligible(@mutants)
        return nil if eligible.empty?

        ids = weak_test_ids(eligible, map)
        return nil if ids.empty?

        Weak.reset!
        install_probes!(targets, eligible)
        ids.each do |test_id|
          Weak.test_id = test_id
          begin
            @adapter.run([test_id])
          rescue StandardError
            nil
          end
        end
        Weak.report
      ensure
        Weak.test_id = nil
      end

      # A probe can only decide a mutant when every test the runner would select for
      # it runs under the probe. The union of those selections is the whole job.
      def weak_test_ids(eligible, map)
        selection = TestSelection.new(map)
        by_path = @sources.to_h { |source| [source.rel_path, source] }
        wanted = {}
        eligible.each do |mutant|
          source = by_path[mutant.path]
          next if source.nil?

          selection.tests_for(mutant, source).each { |id| wanted[id] = true }
        end
        @adapter.test_ids.select { |id| wanted[id] }
      end

      # Methods are redefined in place, so a test that calls them afterwards runs the
      # probe; the probe returns the original value, so this pass only measures.
      def install_probes!(targets, eligible)
        by_path = eligible.group_by(&:path)
        root = (@adapter.respond_to?(:root) && @adapter.root) || Dir.pwd
        sources = @sources.to_h { |source| [source.rel_path, source] }
        by_path.each do |path, mutants|
          source = sources[path]
          next if source.nil?

          absolute = File.expand_path(path, root)
          next unless File.file?(absolute) && loaded_feature?(absolute)

          instrumented = Weak.instrument(source, mutants)
          next if instrumented.nil?

          begin
            quietly { TOPLEVEL_BINDING.eval(instrumented.first, absolute, 1) }
          rescue StandardError, ScriptError => e
            @probe_failures << "#{path} (#{e.class}: #{e.message})"
          end
        end
      end

      # The neutral mutation, without a second suite run: the coverage pass has
      # already executed every test once. A test that fails with no mutation
      # applied kills every mutant it covers, so the score would be a lie.
      def verify_baseline!(failures)
        return if failures.empty?
        return unless @config.respond_to?(:baseline) && @config.baseline

        total = @adapter.test_ids.size
        shown = failures.first(10).map do |test_id, outcome|
          detail = outcome.error ? "#{outcome.error.class}: #{outcome.error.message}" : "assertion failed"
          "#{test_id} (#{detail})"
        end
        more = failures.size > shown.size ? " and #{failures.size - shown.size} more" : ""
        raise BaselineError,
              "#{failures.size} of #{total} tests fail with no mutation applied: " \
              "#{shown.join(", ")}#{more}. Every mutant those tests cover would be reported " \
              "as killed. Fix the suite, or pass --no-baseline to score it anyway."
      end

      # absolute path => repo-relative path from the Source objects.
      def target_files
        root = (@adapter.respond_to?(:root) && @adapter.root) || Dir.pwd
        targets = {}
        @sources.each do |source|
          path = if source.respond_to?(:path)
                   source.path.to_s
                 elsif source.respond_to?(:rel_path)
                   source.rel_path.to_s
                 else
                   source.to_s
                 end
          next if path.empty?

          relative = path.sub(%r{\A\./}, "")
          absolute = File.expand_path(relative, root)
          targets[absolute] = relative
          begin
            real = File.realpath(absolute)
            targets[real] = relative if real != absolute
          rescue StandardError
            nil
          end
        end
        targets
      end

      # relative path => FileCoverage, from the snapshot taken right after boot. A file
      # whose reload raised has counters for an iseq the program no longer runs, and a
      # file absent from the snapshot is uninstrumented when Ruby already loaded it and
      # not loaded otherwise; the last may still change while a test runs.
      def describe_boot(targets, boot, unreloadable)
        files = {}
        targets.group_by { |_absolute, relative| relative }.each do |relative, pairs|
          absolutes = pairs.map(&:first)
          lines = absolutes.filter_map { |absolute| boot[absolute] }.first
          state = if unreloadable.include?(relative)
                    :uninstrumented
                  elsif lines
                    :instrumented
                  elsif absolutes.any? { |absolute| loaded_feature?(absolute) }
                    :uninstrumented
                  else
                    :not_loaded
                  end
          boot_lines = state == :instrumented ? changed_lines(lines, nil, @wanted_lines && @wanted_lines[relative]) : []
          files[relative] = CoverageMap::FileCoverage.new(path: relative, state: state, boot_lines: boot_lines)
        end
        files
      end

      # A test that requires a file the boot did not load owns its class body.
      def note_first_loads(files, hits, test_id)
        hits.each_key do |relative|
          file = files[relative]
          next unless file&.state == :not_loaded

          files[relative] = file.with(state: :loaded_during_test, loaded_by: test_id)
        end
      end

      # The lines the runner can ask about: every mutant's own span plus the
      # statement span it falls back to when line coverage is coarse. Recording
      # only these lines keeps every selection query identical while skipping
      # the rest of each source.
      def wanted_lines
        by_path = @sources.to_h { |source| [source.rel_path, source] }
        spans = {}
        wanted = @sources.to_h { |source| [source.rel_path, {}] }
        @mutants.each do |mutant|
          source = by_path[mutant.path]
          next unless source

          lines = wanted[mutant.path]
          add_lines(lines, source.line_of(mutant.start_offset), source.line_of(mutant.end_offset - 1))
          span = (spans[mutant.path] ||= Source.statement_spans(source.ast))[
            [mutant.start_offset, mutant.end_offset]
          ]
          next unless span

          add_lines(lines, source.line_of(span[0]), source.line_of(span[1] - 1))
        end
        wanted.transform_values { |lines| lines.keys.sort }
      end

      def add_lines(lines, first, last)
        (first..last).each { |line| lines[line - 1] = true }
      end

      def snapshot
        raw = ::Coverage.peek_result
        result = {}
        raw.each do |file, data|
          lines = data.is_a?(Hash) ? data[:lines] : data
          if lines.nil? && data.is_a?(Hash)
            raise CoverageError,
                  "Coverage is already running without line counters (#{data.keys.join(", ")}), " \
                  "so no test can be attributed to a line. Start the suite without it: for " \
                  "SimpleCov, skip SimpleCov.start under sabaku, e.g. --env=SKIP_SIMPLECOV=1 " \
                  "with a guard in test_helper"
          end
          result[file] = lines if lines
        end
        result
      end

      # A target that was loaded before Coverage.start has no counters at all
      # (it is absent from peek_result). Re-load it under coverage once. This
      # only applies to files already in $LOADED_FEATURES: a source the tests
      # never load must stay unloaded (its mutants are legitimately uncovered,
      # and loading it here could run side effects). A file that refuses the
      # second load stays without live counters; the others are still sampled.
      # -> Array[String] the relative paths whose reload raised
      def ensure_targets_instrumented!(targets)
        current = snapshot
        reloaded = {}
        failed = []
        targets.each do |absolute, relative|
          next if current.key?(absolute)
          next if reloaded[relative]
          next unless File.file?(absolute)
          next unless loaded_feature?(absolute)

          reloaded[relative] = true
          begin
            quietly { load absolute }
          rescue StandardError, ScriptError
            failed << relative
          end
        end
        failed
      end

      def loaded_feature?(absolute)
        return true if $LOADED_FEATURES.include?(absolute)

        begin
          $LOADED_FEATURES.include?(File.realpath(absolute))
        rescue SystemCallError
          false
        end
      end

      def quietly
        previous = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = previous
      end

      def diff_hits(before, after, targets)
        hits = {}
        after.each do |file, lines|
          relative = targets[file]
          next unless relative

          previous = before[file]
          indices = @wanted_lines && @wanted_lines[relative]
          fresh = changed_lines(lines, previous, indices)
          hits[relative] = fresh unless fresh.empty?
        end
        hits
      end

      def changed_lines(lines, previous, indices)
        fresh = []
        (indices || lines.each_index).each do |index|
          count = lines[index]
          next unless count.is_a?(Integer) && count.positive?

          old = previous && previous[index]
          next if old.is_a?(Integer) && old >= count

          fresh << index + 1
        end
        fresh
      end
    end
  end
end
