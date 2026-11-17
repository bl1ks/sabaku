# frozen_string_literal: true

require "json"

module Mutation
  # Turns the result list into the two shapes a user sees: a terminal summary and JSON.
  # Everything is derived from Result values, so the report never re-runs or re-parses.
  class Report
    ORDER = %i[killed survived timeout uncovered error].freeze

    attr_reader :results, :config

    def initialize(results, config)
      @results = results
      @config = config
    end

    def counts
      @counts ||= ORDER.to_h { |status| [status, results.count { |r| r.status == status }] }
    end

    def run_count = results.count(&:counted?)

    def score
      denominator = counts[:killed] + counts[:survived] + counts[:timeout]
      return 0.0 if denominator.zero?

      counts[:killed].fdiv(denominator)
    end

    def survivors = results.select(&:survived?)

    def per_file
      @per_file ||= results.group_by { |r| r.mutant.path }.sort.map do |path, list|
        counted = list.count(&:counted?)
        killed = list.count(&:killed?)
        { path: path, killed: killed, counted: counted,
          rate: counted.zero? ? 0.0 : killed.fdiv(counted) }
      end
    end

    def to_terminal
      out = +""
      out << header
      out << status_lines
      out << survivor_lines
      out << file_lines
      out
    end

    def header
      files = results.map { |r| r.mutant.path }.uniq.size
      format("ruby-mutation %s  adapter=%s  files=%d  mutants=%d  jobs=%d\n\n",
             VERSION, config.adapter, files, results.size, config.jobs)
    end

    def status_lines
      out = +""
      width = ORDER.map { |s| s.to_s.length }.max
      ORDER.each do |status|
        count = counts[status]
        next if count.zero? && %i[uncovered error].include?(status)

        share = results.empty? ? 0.0 : count.fdiv(results.size) * 100
        out << format("  %-#{width}s  %5d  %5.1f%%%s\n", status, count, share, note_for(status))
      end
      out << format("\n  mutation score  %5.1f%%  (killed / killed+survived+timeout)\n",
                    score * 100)
      out << "\n"
    end

    def note_for(status)
      case status
      when :survived then "  <- your tests did not notice these"
      when :timeout then "  <- killed by the clock, not by a test"
      when :uncovered then "  (no test covers the line; not scored)"
      when :error then "  <- the mutant could not be applied"
      else ""
      end
    end

    def survivor_lines
      return "" if survivors.empty?

      out = +"survivors:\n"
      survivors.first(50).each do |result|
        mutant = result.mutant
        out << format("  %s:%d  %s\n", mutant.path, mutant.line, mutant.description)
      end
      out << format("  ... and %d more\n", survivors.size - 50) if survivors.size > 50
      out << "\n"
    end

    def file_lines
      return "" if per_file.size < 2

      out = +"per file:\n"
      widest = per_file.map { |f| f[:path].length }.max
      per_file.each do |file|
        out << format("  %-#{widest}s  %3d/%-3d %5.1f%%\n",
                      file[:path], file[:killed], file[:counted], file[:rate] * 100)
      end
      out
    end

    def to_h
      {
        version: VERSION,
        adapter: config.adapter,
        isolation: config.isolation,
        seed: config.seed,
        operators: config.operators,
        mutants: results.size,
        killed: counts[:killed],
        survived: counts[:survived],
        timeout: counts[:timeout],
        uncovered: counts[:uncovered],
        error: counts[:error],
        score: score.round(4),
        wall_ms: (results.sum(&:duration) * 1000).round,
        files: per_file,
        results: results.map(&:to_h),
        survivors: survivors.map do |result|
          mutant = result.mutant
          { path: mutant.path, line: mutant.line, column: mutant.column,
            operator: mutant.operator, node: mutant.node_kind,
            original: mutant.original, replacement: mutant.replacement,
            description: mutant.description, test_ids: mutant.respond_to?(:test_ids) ? mutant.test_ids : nil }
        end
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end
end
