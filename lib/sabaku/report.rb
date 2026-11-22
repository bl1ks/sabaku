# frozen_string_literal: true

require "json"

require_relative "result"

module Sabaku
  # Turns the result list into the two shapes a user sees: a terminal summary and JSON.
  # Everything is derived from Result values, so the report never re-runs or re-parses.
  class Report
    ORDER = %i[killed survived timeout uncovered error skipped].freeze

    MATRIX_LIST_LIMIT = 20

    REASON_LABELS = {
      not_detected: "not detected", not_infected: "not infected",
      deadline: "deadline",
      not_loaded: "not loaded", uninstrumented: "uninstrumented", load_time_only: "load-time only",
      not_reached: "not reached",
      environment_crash: "environment crash", unverified_kill: "unverified kill", harness: "harness",
      fail_fast: "fail-fast", mutation_unloadable: "mutation does not load",
      suite_unloadable: "suite does not load"
    }.freeze

    # A skipped mutant whose reason the user cannot read off the count: --fail-fast is
    # the one they asked for.
    UNMEASURED = (Result::REASONS[:skipped] - %i[fail_fast]).freeze

    # Advice printed under a not-measured group whose message names a known cause. A hint
    # never changes a status or a reason.
    SkipHint = Data.define(:pattern, :doc)
    SKIP_HINTS = [
      SkipHint.new(pattern: /You called sig twice/, doc: "docs/rails.md#sorbet"),
      SkipHint.new(pattern: /Multiple(?:Included|Prepend)Blocks/, doc: "docs/rails.md#concerns")
    ].freeze

    attr_reader :results, :config, :kill_matrix

    # kill_matrix: a KillMatrix when the campaign ran with --kill-matrix, else nil.
    # coverage_files: CoverageMap#files, how the coverage pass saw each target file.
    def initialize(results, config, kill_matrix: nil, coverage_files: {})
      @results = results
      @config = config
      @kill_matrix = kill_matrix
      @coverage_files = coverage_files
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

    # status => {reason => count}, for the statuses with at least one reasoned result.
    # Survivors use `survivor_reasons`, so an unclassified one counts as not_detected.
    def reasons
      @reasons ||= begin
        tally = results.filter_map do |result|
          reason = result.respond_to?(:reason) ? result.reason : nil
          [result.status, reason] unless reason.nil? || result.status == :survived
        end.group_by(&:first).transform_values { |pairs| pairs.map(&:last).tally }
        tally[:survived] = survivor_reasons unless survivor_reasons.empty?
        ORDER.filter_map { |status| [status, tally[status]] if tally[status] }.to_h
      end
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
      out << kill_matrix_lines
      out
    end

    def header
      files = results.map { |r| r.mutant.path }.uniq.size
      format("sabaku %s  files=%d  mutants=%d  jobs=%d\n\n",
             VERSION, files, results.size, config.jobs)
    end

    def status_lines
      out = +""
      width = ORDER.map { |s| s.to_s.length }.max
      ORDER.each do |status|
        count = counts[status]
        next if count.zero? && %i[uncovered error skipped].include?(status)

        share = results.empty? ? 0.0 : count.fdiv(results.size) * 100
        out << format("  %-#{width}s  %5d  %5.1f%%%s\n", status, count, share, note_for(status))
        out << reason_line(status) if reasons[status]
      end
      out << format("\n  mutation score  %5.1f%%  (killed / killed+survived+timeout)\n",
                    score_pct)
      out << "\n"
    end

    def reason_line(status)
      tally = reasons.fetch(status)
      shown = Result::REASONS.fetch(status).select do |reason|
        status == :survived || tally.fetch(reason, 0).positive?
      end
      "    #{shown.map { |reason| "#{REASON_LABELS.fetch(reason)} #{tally.fetch(reason, 0)}" }.join(", ")}\n"
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

    # Only an unmeasured mutant carries information the user cannot get from the
    # count, so the terminal names those and leaves the fail-fast remainder to the
    # status line.
    def unmeasured_lines
      unmeasured = results.select do |result|
        result.status == :skipped && result.respond_to?(:reason) && UNMEASURED.include?(result.reason)
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
        hint = SKIP_HINTS.find { |candidate| message.to_s.match?(candidate.pattern) }
        out << "         see #{hint.doc}\n" if hint
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
        out << format("  %-#{widest}s  %3d/%-3d %5.1f%%%s\n",
                      file[:path], file[:killed], file[:counted], file[:rate] * 100, file_note(file))
      end
      out
    end

    # A file with nothing scored says why, and a file a test loaded says which test, since
    # that test alone ran its class body.
    def file_note(file)
      described = @coverage_files[file[:path]]
      return "  (loaded lazily by #{described.loaded_by})" if described&.state == :loaded_during_test
      return "" unless file[:counted].zero?

      reasons = results.select { |r| r.mutant.path == file[:path] && r.status == :uncovered }.filter_map(&:reason)
      reasons.empty? ? "" : "  (#{reasons.tally.max_by(&:last).first.to_s.tr("_", " ")})"
    end

    # The files the coverage pass described that hold an uncovered mutant.
    def uncovered_files
      paths = results.select { |result| result.status == :uncovered }.map { |result| result.mutant.path }.uniq
      paths.sort.filter_map { |path| @coverage_files[path] }
    end

    def kill_matrix_lines
      return "" unless kill_matrix

      summary = kill_matrix.summary
      scored = kill_matrix.rows.size + kill_matrix.incomplete.size
      out = +"#{file_lines.empty? ? "" : "\n"}kill matrix: #{kill_matrix.rows.size} of #{scored} " \
             "killed+survived mutants have a complete row\n"
      if (focus = kill_matrix.focus)
        out << format("  focus: %s, %d of %d tests\n", config.kill_matrix_focus.join(", "), focus[:tests], focus[:of])
      end
      out << incomplete_lines unless kill_matrix.incomplete.empty?
      out << format("  tests %d: kept %d, subsumed %d, duplicate %d, zero kills %d, idle %d\n",
                    kill_matrix.verdicts.size, summary[:kept], summary[:subsumed],
                    summary[:duplicate], summary[:zero], summary[:idle])
      redundant = kill_matrix.verdicts.select(&:redundant?)
      unless redundant.empty?
        out << format("  redundant %d actionable, %d provisional (?), %d broad-only " \
                      "(every test of its class that ran those mutants killed them)\n",
                      summary[:actionable], redundant.count { |verdict| verdict.tier == :provisional },
                      summary[:artifact])
      end
      out << "\n"
      unused = kill_matrix.verdicts.select { |verdict| %i[zero idle].include?(verdict.kind) }
      out << matrix_list("zero kills", unused) do |verdict|
        if verdict.kind == :idle
          "never selected for a scored mutant"
        elsif verdict.tested.zero?
          "selected only for mutants without a complete row"
        else
          "ran against #{plural(verdict.tested, "mutant")}, killed none"
        end
      end
      actionable = kill_matrix.verdicts.select { |verdict| verdict.tier == :actionable }
      out << matrix_list("redundant", actionable) do |verdict|
        if verdict.kind == :duplicate
          "same #{plural(verdict.kills, "kill")} as #{verdict.by}"
        else
          "#{plural(verdict.kills, "kill")}, all also killed by #{verdict.by}"
        end
      end
      out << matrix_list("top unique killers", kill_matrix.ranking) do |verdict|
        format("unique %d  kills %d", verdict.unique, verdict.kills)
      end
      out
    end

    def incomplete_lines
      causes = kill_matrix.summary[:incomplete_causes].sort_by { |cause, count| [-count, cause] }
      named = causes.map { |cause, count| "#{cause.to_s.tr("_", " ")} #{count}" }.join(", ")
      out = +format("  %d incomplete%s; tests marked ? touch one\n", kill_matrix.incomplete.size,
                    named.empty? ? "" : ": #{named}")
      if causes.first&.first == :sweep_timeout
        out << format("  most incomplete rows hit the sweep deadline: raise --sweep-timeout (now %.1fs)\n",
                      config.sweep_timeout || config.timeout)
      end
      top = kill_matrix.incomplete_groups.first(5).map { |name, count| "#{name} #{count}" }
      out << "  incomplete by class: #{top.join(", ")}\n" if kill_matrix.scope == :class && top.any?
      out
    end

    def matrix_list(title, verdicts)
      return "" if verdicts.empty?

      shown = verdicts.first(MATRIX_LIST_LIMIT)
      widest = shown.map { |verdict| verdict.test.length }.max
      out = +"#{title}:\n"
      shown.each do |verdict|
        mark = verdict.provisional ? "?" : " "
        out << format("  %-#{widest}s %s %s\n", verdict.test, mark, yield(verdict))
      end
      if verdicts.size > MATRIX_LIST_LIMIT
        out << format("  ... and %d more\n", verdicts.size - MATRIX_LIST_LIMIT)
      end
      out << "\n"
    end

    def plural(count, noun) = "#{count} #{noun}#{count == 1 ? "" : "s"}"

    # A statement-block mutant carries a whole class body in its original text, so the
    # terminal gets the first line and the size, never a wall of source.
    def one_line(mutant, limit: 72)
      text = mutant.description.gsub(/\s+/, " ").strip
      text = "#{mutant.operator.to_s.upcase}: #{mutant.original.lines.first.strip} ... " \
             "(one statement of a #{mutant.original.lines.size}-line block)" if mutant.original.include?("\n")
      text.length > limit ? "#{text[0, limit - 1]}..." : text
    end

    def to_h
      hash = {
        version: VERSION,
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
        reasons: reasons.to_h { |status, tally| [status, tally.transform_keys(&:to_s)] },
        coverage_files: uncovered_files.map(&:to_h),
        survivors: survivors.map do |result|
          mutant = result.mutant
          { path: mutant.path, line: mutant.line, column: mutant.column,
            operator: mutant.operator, node: mutant.node_kind,
            original: mutant.original, replacement: mutant.replacement,
            description: mutant.description, test_ids: mutant.respond_to?(:test_ids) ? mutant.test_ids : nil }
        end
      }
      if kill_matrix
        matrix = kill_matrix.to_h
        matrix[:focus] = { globs: config.kill_matrix_focus, **matrix[:focus] } if matrix[:focus]
        hash[:kill_matrix] = matrix
      end
      hash
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end
end
