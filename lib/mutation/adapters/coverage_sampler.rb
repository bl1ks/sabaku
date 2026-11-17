# frozen_string_literal: true

require_relative "../coverage_map"

module Mutation
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
      def initialize(config, adapter, sources)
        @config = config
        @adapter = adapter
        @sources = Array(sources)
      end

      # -> CoverageMap
      def call
        require "coverage"

        targets = target_files
        started_here = false
        unless ::Coverage.running?
          if @adapter.respond_to?(:preloaded?) && @adapter.preloaded?
            raise Mutation::Error,
                  "coverage must be started before the adapter preloads the project; " \
                  "create the adapter, then sample, then run"
          end

          ::Coverage.start(lines: true)
          started_here = true
        end

        @adapter.preload!
        # In an embedded process another adapter may already have required the
        # mutated files before we started Coverage; Ruby only instruments files
        # when they are compiled, so those files would silently report no hits.
        # Reload exactly those targets now, while Coverage is on.
        ensure_targets_instrumented!(targets)
        previous = snapshot
        map = CoverageMap.empty

        @adapter.test_ids.each do |test_id|
          begin
            @adapter.run([test_id])
          rescue StandardError
            # A failing test still has valid coverage; keep sampling the rest.
            nil
          end
          current = snapshot
          hits = diff_hits(previous, current, targets)
          map.record(test_id, hits) unless hits.empty?
          previous = current
        end

        map
      ensure
        ::Coverage.result if started_here && ::Coverage.running?
      end

      private

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

      def snapshot
        raw = ::Coverage.peek_result
        result = {}
        raw.each do |file, data|
          lines = if data.is_a?(Hash)
                    data[:lines] || data["lines"]
                  else
                    data
                  end
          result[file] = lines if lines
        end
        result
      end

      # A target that was loaded before Coverage.start has no counters at all
      # (it is absent from peek_result). Re-load it under coverage once. In the
      # normal CLI path this is a no-op: preload! loaded the file while Coverage
      # was already running.
      def ensure_targets_instrumented!(targets)
        current = snapshot
        reloaded = {}
        targets.each do |absolute, relative|
          next if current.key?(absolute)
          next if reloaded[relative]
          next unless File.file?(absolute)

          begin
            quietly { load absolute }
            reloaded[relative] = true
          rescue StandardError, ScriptError => e
            raise Mutation::Error,
                  "failed to reload #{relative} for coverage: #{e.class}: #{e.message}"
          end
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
          fresh = []
          lines.each_with_index do |count, index|
            next unless count.is_a?(Integer) && count.positive?

            old = previous && previous[index]
            next if old.is_a?(Integer) && old >= count

            fresh << index + 1
          end
          hits[relative] = fresh unless fresh.empty?
        end
        hits
      end
    end
  end
end
