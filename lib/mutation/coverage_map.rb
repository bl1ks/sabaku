# frozen_string_literal: true

module Mutation
  # Which tests execute which line of which file.
  #
  # This is a plain value. Adapters do the measuring; the runner only ever asks
  # `tests_for(path, line)`, which is the hot lookup of a campaign. Paths are
  # repo-relative strings so the whole map survives a JSON round trip through
  # the cache and still lines up with `Mutant#path`.
  class CoverageMap
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
      map
    end

    def initialize
      # test_id => path => {line => true}
      @hits = {}
      # path => line => [test_id, ...] (already unique per test/line)
      @index = {}
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

    # Non-destructive union with another CoverageMap.
    def merge(other)
      unless other.is_a?(CoverageMap)
        raise ArgumentError, "can only merge a CoverageMap, got #{other.class}"
      end

      merged = self.class.new
      each_hit { |test_id, hits| merged.record(test_id, hits) }
      other.each_hit { |test_id, hits| merged.record(test_id, hits) }
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
    #   {"tests" => {test_id => {path => sorted_lines}}}
    def to_h
      tests = {}
      @hits.keys.sort.each do |test_id|
        paths = {}
        @hits[test_id].keys.sort.each do |path|
          paths[path] = @hits[test_id][path].keys.sort
        end
        tests[test_id] = paths
      end
      { "tests" => tests }
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
