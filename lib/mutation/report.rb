# frozen_string_literal: true

require "json"

module Mutation
  # Turns the result list into the two shapes a user sees: a terminal summary and JSON.
  # Everything is derived from Result values, so the report never re-runs or re-parses.
  class Report
    ORDER = %i[killed survived timeout uncovered error skipped].freeze

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

    # The percentage the terminal prints and --min-score compares. One value and one rounding,
    # so a run cannot show 80.0% and exit as if it were below 80.
    def score_pct
      (score * 100).round(1)
    end

    def survivors = results.select(&:survived?)

    # How many survivors a real test noticed (not_detected) and how many never changed
    # a value the tests observe (not_infected). A survivor without a reason predates the
    # classification, so it counts as not_detected.
    def survivor_reasons
      @survivor_reasons ||= results.select { |result| result.status == :survived }.group_by do |result|
        reason = result.respond_to?(:reason) ? result.reason : nil
        reason || :not_detected
      end.transform_values(&:size)
    end

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
      out << error_lines
      out << unmeasured_lines
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
        next if count.zero? && %i[uncovered error skipped].include?(status)

        share = results.empty? ? 0.0 : count.fdiv(results.size) * 100
        out << format("  %-#{width}s  %5d  %5.1f%%%s\n", status, count, share, note_for(status))
      end
      if counts[:survived].positive?
        out << format("    not detected %d, not infected %d\n",
                      survivor_reasons.fetch(:not_detected, 0),
                      survivor_reasons.fetch(:not_infected, 0))
      end
      out << format("\n  mutation score  %5.1f%%  (killed / killed+survived+timeout)\n",
                    score_pct)
      out << "\n"
    end

    def note_for(status)
      case status
      when :survived then "  <- your tests did not notice these"
      when :timeout then "  <- killed by the clock, not by a test"
      when :uncovered then "  (no test covers the line; not scored)"
      when :error then "  <- no result: never tested, not scored"
      when :skipped then "  (not run or not measurable; not scored)"
      else ""
      end
    end

    def survivor_lines
      return "" if survivors.empty?

      out = +"survivors:\n"
      survivors.first(50).each do |result|
        mutant = result.mutant
        tag = result.reason == :not_infected ? "  (not infected)" : ""
        out << format("  %s:%d  %s%s\n", mutant.path, mutant.line, one_line(mutant), tag)
      end
      out << format("  ... and %d more\n", survivors.size - 50) if survivors.size > 50
      out << "\n"
    end

    # Errors are the one status the score cannot absorb and the one whose cause is
    # never in the score, so the terminal names them instead of leaving the count
    # to speak for itself.
    def error_lines
      errors = results.select { |result| result.status == :error }
      return "" if errors.empty?

      out = +"errors (not scored):\n"
      errors.first(10).each do |result|
        out << format("  %s:%d  %s\n", result.mutant.path, result.mutant.line,
                      clamp_message(result.message))
      end
      out << format("  ... and %d more\n", errors.size - 10) if errors.size > 10
      out << "\n"
    end

    def clamp_message(message, limit: 96)
      text = message.to_s.gsub(/\s+/, " ").strip
      return "(no message)" if text.empty?

      text.length > limit ? "#{text[0, limit - 1]}..." : text
    end

    # Skipped covers two very different things: --fail-fast stopped the run
    # (expected, the user asked for it) and a mutant nobody could measure (a
    # file that cannot be reloaded, or a mutation that does not load). Only the
    # second is information the user cannot get from the count, so the terminal
    # names those and leaves the fail-fast remainder to the status line.
    def unmeasured_lines
      unmeasured = results.select do |result|
        result.status == :skipped && result.message.to_s.start_with?("not measured: ")
      end
      return "" if unmeasured.empty?

      groups = unmeasured.group_by { |result| [result.mutant.path, result.message] }
                        .sort_by { |_key, list| -list.size }
      shown = groups.first(10)
      out = +"not measured (not scored):\n"
      shown.each do |(path, message), list|
        where = list.size == 1 ? "#{path}:#{list.first.mutant.line}" : path
        reason = message.delete_prefix("not measured: ")
        out << format("  %5d  %s  %s\n", list.size, where, clamp_message(reason, limit: 100))
      end
      rest = groups.drop(shown.size).sum { |_key, list| list.size }
      if rest.positive?
        out << format("  %5d  more in %d other reasons\n", rest, groups.size - shown.size)
      end
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

    # A statement-block mutant carries a whole class body in its original text, so the
    # terminal gets the first line and the size, never a wall of source.
    def one_line(mutant, limit: 72)
      text = mutant.description.gsub(/\s+/, " ").strip
      text = "#{mutant.operator.to_s.upcase}: #{mutant.original.lines.first.strip} ... " \
             "(one statement of a #{mutant.original.lines.size}-line block)" if mutant.original.include?("\n")
      text.length > limit ? "#{text[0, limit - 1]}..." : text
    end

    def to_h
      {
        version: VERSION,
        adapter: config.adapter,
        isolation: config.isolation,
        operators: config.operators,
        mutants: results.size,
        killed: counts[:killed],
        survived: counts[:survived],
        timeout: counts[:timeout],
        uncovered: counts[:uncovered],
        error: counts[:error],
        skipped: counts[:skipped],
        score: score.round(4),
        wall_ms: (results.sum(&:duration) * 1000).round,
        files: per_file,
        results: results.map(&:to_h),
        survived_reasons: survivor_reasons.transform_keys(&:to_s),
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
