# frozen_string_literal: true

module Sabaku
  # Which tests execute which line of which file.
  #
  # This is a plain value. Adapters do the measuring; the runner only ever asks
  # `tests_for(path, line)`, which is the hot lookup of a campaign. Paths are
  # repo-relative strings so the whole map survives a JSON round trip through
  # the cache and still lines up with `Mutant#path`.
  class CoverageMap
    # How the coverage pass saw one target file. A line no test ran means different
    # things depending on it: the file never loaded, it loaded without counters, or it
    # was measured and nothing reached the line.
    #
    #   boot_lines  lines with a count right after boot, before the first test
    #   loaded_by   the test during which the file first appeared (:loaded_during_test)
    FileCoverage = Data.define(:path, :state, :boot_lines, :loaded_by)

    class FileCoverage
      STATES = %i[not_loaded uninstrumented loaded_during_test instrumented].freeze

      def initialize(path:, state:, boot_lines: [], loaded_by: nil)
        state = state.to_sym
        raise ArgumentError, "unknown file coverage state #{state.inspect}" unless STATES.include?(state)

        super(path: path.to_s, state: state, boot_lines: boot_lines.map { |line| Integer(line) }.sort.freeze,
              loaded_by: loaded_by&.to_s)
      end
    end

    # An empty map is a valid map: it means "no line is covered by any test".
    def self.empty
      new
    end

    # Rebuild a map from `#to_h`. Accepts the wrapped (`{"tests" => ...}`) form
    # produced by `#to_h` and the bare (`{test_id => {path => lines}}`) form.
    def self.from_h(hash)
      map = new
      return map if hash.nil?
      return map unless hash.respond_to?(:each)

      tests = hash["tests"] || hash[:tests] || hash
      tests.each do |test_id, hits|
        next unless hits.respond_to?(:each)

        normalized = {}
        hits.each do |path, lines|
          normalized[path.to_s] = lines.respond_to?(:to_a) ? lines.to_a : Array(lines)
        end
        map.record(test_id.to_s, normalized)
      end
      (hash["files"] || hash[:files] || {}).each_value do |file|
        map.describe(FileCoverage.new(**file.transform_keys(&:to_sym)))
      end
      map
    end

    def initialize
      # test_id => path => {line => true}
      @hits = {}
      # path => line => [test_id, ...] (already unique per test/line)
      @index = {}
      # path => FileCoverage
      @files = {}
    end

    def describe(file)
      @files[file.path] = file
      self
    end

    def file(path)
      @files[path.to_s]
    end

    def files
      @files.dup
    end

    # The boot ran the line and no test did: a class body DSL, a `sig` block, a
    # schema declared at load time. Only a test that loaded or reloaded the file
    # could own it.
    def load_time_only?(path, line)
      described = file(path)
      return false if described.nil? || !described.boot_lines.include?(line)

      tests_for(path, line).empty?
    end

    # Record that +test_id+ hit +hits+ (path => Array[Integer] | Set[Integer]).
    # Recording the same test twice unions its hits.
    def record(test_id, hits)
      test_id = test_id.to_s
      per_test = (@hits[test_id] ||= {})
      hits.each do |path, lines|
        path = path.to_s
        line_set = (per_test[path] ||= {})
        values = lines.respond_to?(:to_a) ? lines.to_a : Array(lines)
        values.each do |line|
          line = Integer(line)
          next if line <= 0
          next if line_set[line]

          line_set[line] = true
          ((@index[path] ||= {})[line] ||= []) << test_id
        end
      end
      self
    end

    # Sorted Array[String] of the ids of every test that executes +line+ in
    # +path+. Empty when the line is not covered (or unknown).
    def tests_for(path, line)
      line = Integer(line)
      by_line = @index[path.to_s]
      return [] unless by_line

      (by_line[line] || []).sort
    rescue ArgumentError, TypeError
      []
    end

    # Tests that execute any line of [first_line, last_line].
    #
    # Ruby's line coverage marks only some lines of a multi-line expression: a
    # `a && b && c` chain spread over five lines is reported as its first and last
    # line, not the three in between. Asking for the mutated node's whole span keeps
    # a mutant on an interior line from being misreported as uncovered and dropped
    # from the score.
    def tests_for_span(path, first_line, last_line)
      first = Integer(first_line)
      last = Integer(last_line)
      return tests_for(path, first) if last <= first

      (first..last).flat_map { |line| tests_for(path, line) }.uniq.sort
    rescue ArgumentError, TypeError
      []
    end

    # How many lines of +path+ the test executes. This is the ordering signal:
    # a test that walks more of the file is more likely to assert on a mutated
    # line than a test that brushes one line of it, so it should run first.
    def reach(path, test_id)
      lines = @hits[test_id.to_s]
      return 0 if lines.nil?

      hits = lines[path.to_s]
      hits ? hits.size : 0
    end

    # `tests_for_span`, ordered by how much of the file each test exercises,
    # then by id for stability. The adapter stops at the first failing test, so
    # this order is what decides how many tests a kill costs.
    def ordered_tests_for_span(path, first_line, last_line)
      tests_for_span(path, first_line, last_line)
        .sort_by { |test_id| [-reach(path, test_id), test_id] }
    end

    # Every test that executed any line of +path+, sorted.
    def tests_for_file(path)
      by_line = @index[path.to_s]
      return [] unless by_line

      by_line.values.flatten.uniq.sort
    end

    # `tests_for_file`, ordered like `ordered_tests_for_span`.
    def ordered_tests_for_file(path)
      tests_for_file(path).sort_by { |test_id| [-reach(path, test_id), test_id] }
    end

    # Non-destructive union with another CoverageMap.
    def merge(other)
      unless other.is_a?(CoverageMap)
        raise ArgumentError, "can only merge a CoverageMap, got #{other.class}"
      end

      merged = self.class.new
      each_hit { |test_id, hits| merged.record(test_id, hits) }
      other.each_hit { |test_id, hits| merged.record(test_id, hits) }
      [files, other.files].each { |described| described.each_value { |file| merged.describe(file) } }
      merged
    end

    def test_ids
      @hits.keys.sort
    end

    def empty?
      @hits.empty?
    end

    def size
      @hits.size
    end

    def ==(other)
      other.is_a?(CoverageMap) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    # Deterministic JSON-friendly form:
    #   {"tests" => {test_id => {path => sorted_lines}}, "files" => {path => FileCoverage#to_h}}
    # "files" is present only when the sampler described a file.
    def to_h
      tests = {}
      @hits.keys.sort.each do |test_id|
        paths = {}
        @hits[test_id].keys.sort.each do |path|
          paths[path] = @hits[test_id][path].keys.sort
        end
        tests[test_id] = paths
      end
      hash = { "tests" => tests }
      unless @files.empty?
        hash["files"] = @files.keys.sort.to_h { |path| [path, @files[path].to_h.transform_keys(&:to_s)] }
      end
      hash
    end

    def inspect
      "#<#{self.class} tests=#{size}>"
    end

    protected

    # Yields test_id, {path => Array[Integer]} without exposing the internal
    # mutable hashes.
    def each_hit
      @hits.each do |test_id, paths|
        yield test_id, paths.transform_values { |lines| lines.keys.sort }
      end
    end
  end
end
