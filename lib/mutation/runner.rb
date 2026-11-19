# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

require_relative "boot"
require_relative "cache"
require_relative "coverage_map"
require_relative "errors"
require_relative "fingerprint"
require_relative "load_hazard"
require_relative "result"
require_relative "source"

module Mutation
  # Turns candidate mutants into Results, following the lifecycle in
  # docs/DESIGN.md:
  #
  #   candidate --(no covering test)--> uncovered
  #   candidate --(covering tests)--> queued --> running
  #        child exits 0            -> survived
  #        child exits 1            -> killed
  #        child killed by signal   -> timeout
  #        anything/everything else -> error
  #
  # Two checks guard the score, both built from the same job shape as a mutant
  # and both skipped when the project turns --no-baseline on:
  #
  #   baseline   every test, no mutation, on the campaign's own isolation surface
  #   kill check one test that failed, with the target file loaded a second time
  #              and no mutation, for files that run code at load time
  #
  # The parent preloads the adapter once, then forks one child per mutant (the
  # fast path) or spawns a fresh Ruby running runtime/bootstrap.rb (the portable
  # path). A pipe write from the child is the completion signal; a deadline is
  # enforced with IO.select and SIGKILL, and every child is reaped.
  class Runner
    MUTATION_LIB = File.expand_path("..", __dir__)
    BOOTSTRAP = File.join(MUTATION_LIB, "mutation", "runtime", "bootstrap.rb")

    Entry = Struct.new(:index, :mutant, :selected_ids, :source_text, :cache_key, :result,
                       :first_load, keyword_init: true) do
      def done?
        !result.nil?
      end
    end

    Job = Struct.new(:pid, :reader, :started_at, :deadline, :entry, :temp_path, :pgroup,
                     :control, keyword_init: true)

    # A run of the same child shape with no mutation applied. `reload` re-executes
    # the target file first, which is what the fork path does to a mutant, so a
    # verdict here answers "did the harness itself break this test".
    Control = Struct.new(:key, :index, :ids, :reload, :path, :text, :first_load, :grace,
                         keyword_init: true)

    def initialize(config, analyzer: nil, adapter:, coverage_map: nil, weak: nil)
      @config = config
      @analyzer = analyzer
      @adapter = adapter
      @coverage_map = coverage_map || CoverageMap.empty
      @weak = weak
      @jobs = [Integer(config.respond_to?(:jobs) ? (config.jobs || 1) : 1), 1].max
      @timeout = Float(config.respond_to?(:timeout) ? (config.timeout || 5.0) : 5.0)
      @isolation = (config.respond_to?(:isolation) ? config.isolation : :fork).to_sym
      @coverage_enabled = config.respond_to?(:coverage) ? config.coverage : true
      @fail_fast = config.respond_to?(:fail_fast) ? config.fail_fast : false
      @baseline = config.respond_to?(:baseline) ? config.baseline : true
      @halted = false
      @cache = Cache.new(Cache.default_path(config), enabled: !Cache.disabled?)
      @source_cache = {}
      @statement_spans = {}
      @all_test_ids = nil
      @temp_dir = nil
      @fingerprint = nil
      @controls = {}
      @load_hazards = {}
      @unmeasured = []
    end

    # mutants: Array[Mutant] -> Array[Result] in the same order.
    def call(mutants)
      Boot.env(@config)
      list = Array(mutants)
      @entries = list.each_with_index.map { |mutant, index| prepare_entry(mutant, index) }
      pending = @entries.reject(&:done?)
      execute(pending) unless pending.empty?
      persist_results
      @entries.map(&:result)
    ensure
      cleanup_temp_dir
    end

    private

    # ---- preparation: selection + cache -------------------------------------

    def prepare_entry(mutant, index)
      source = source_for(mutant.path)
      selected = selected_test_ids(mutant, source)
      if selected.empty?
        message = if @coverage_enabled
                    "no covering test for #{mutant.path}:#{mutant.line}"
                  else
                    "no tests found in the project"
                  end
        return Entry.new(
          index: index,
          mutant: mutant,
          selected_ids: [],
          result: Result.new(mutant: mutant, status: :uncovered, duration: 0.0, message: message)
        )
      end

      mutated = mutant.splice(source.text)
      key = cache_key(mutant, mutated, selected)

      if (hit = @cache.fetch(key))
        return Entry.new(
          index: index,
          mutant: mutant,
          selected_ids: selected,
          cache_key: key,
          result: Result.new(
            mutant: mutant,
            status: hit[:status],
            duration: 0.0,
            failed_test: hit[:failed_test],
            message: hit[:message],
            reason: hit[:reason]
          )
        )
      end

      # A mutant whose covering tests all evaluated the expression and never saw a
      # different value cannot be killed. The dry run already paid for that answer, so
      # no child is spent repeating it.
      if @weak && @weak.decision(mutant, selected) == :not_infected
        return Entry.new(
          index: index,
          mutant: mutant,
          selected_ids: selected,
          cache_key: key,
          result: Result.new(
            mutant: mutant,
            status: :survived,
            duration: 0.0,
            reason: :not_infected,
            message: "not infected: every covering test saw the same value"
          )
        )
      end

      Entry.new(index: index, mutant: mutant, selected_ids: selected,
                source_text: source.text, cache_key: key)
    rescue StandardError => e
      Entry.new(
        index: index,
        mutant: mutant,
        selected_ids: [],
        result: Result.new(
          mutant: mutant,
          status: :error,
          duration: 0.0,
          message: "#{e.class}: #{e.message}"
        )
      )
    end

    def selected_test_ids(mutant, source)
      unless @coverage_enabled
        # Without coverage we cannot tell which tests cover the line, so the
        # state machine says run all of them.
        return all_test_ids
      end

      tests = @coverage_map.ordered_tests_for_span(mutant.path, mutant.line,
                                                   source.line_of(mutant.end_offset - 1))
      return tests unless tests.empty?

      # Ruby's line coverage is coarse inside one expression: a five-line `a && b && c`
      # chain is reported as its first and last line only. Fall back to the statement the
      # mutant belongs to, or a mutant in a multi-line expression is silently dropped from
      # the score as uncovered.
      span = statement_span(source, mutant)
      return [] if span.nil?

      @coverage_map.ordered_tests_for_span(mutant.path, source.line_of(span[0]),
                                           source.line_of(span[1] - 1))
    end

    # Maps [start_offset, end_offset] of every node to the span of the statement that
    # contains it. Built once per file with one AST walk.
    def statement_span(source, mutant)
      spans = (@statement_spans[source.rel_path] ||= Source.statement_spans(source.ast))
      spans[[mutant.start_offset, mutant.end_offset]]
    end

    # Memoised per file: the parse is 50us and a campaign asks for the same file once
    # per mutant, so every mutant of a file shares one Source.
    def source_for(path)
      absolute = File.expand_path(path.to_s)
      @source_cache[absolute] ||= Source.new(path.to_s, File.read(absolute))
    end

    def cache_key(mutant, mutated_source, selected)
      Digest::SHA256.hexdigest(
        [
          "ruby-mutation-cache-v2",
          fingerprint,
          mutant.id.to_s,
          Digest::SHA256.hexdigest(mutated_source.to_s),
          RUBY_VERSION,
          selected.map(&:to_s).sort.join("\u0000")
        ].join("\u0000")
      )
    end

    # The campaign inputs outside the mutated source, hashed once per run.
    def fingerprint
      @fingerprint ||= Fingerprint.for(@config, @adapter).digest
    end

    # With --no-coverage the state machine says run every test for every
    # mutant; enumerating test ids requires preloading the adapter.
    def all_test_ids
      @all_test_ids ||= begin
        @adapter.preload!
        @adapter.test_ids
      end
    end

    # ---- execution ----------------------------------------------------------

    def execute(entries)
      Boot.env(@config)
      Boot.require_paths(@config)
      case @isolation
      when :fork
        @adapter.preload!
        Boot.fire(@config, :after_boot)
        Boot.fire(@config, :before_fork)
        verify_baseline!
        run_pool(entries) { |entry| start_fork_job(entry) }
        attribute_unmeasured
        verify_kills(entries)
      when :process
        # No parent preload needed unless selection was disabled and test_ids
        # were enumerated above; the bootstrap preloads in its own process.
        verify_baseline!
        run_pool(entries) { |entry| start_process_job(entry) }
      else
        raise Mutation::Error,
              "unknown isolation #{@isolation.inspect} (expected :fork or :process)"
      end
    end

    # At most @jobs children in flight. IO.select wakes us on a completion
    # signal or at the nearest deadline, so one slow/timed-out child never
    # blocks the others.
    def run_pool(items, controls: false)
      queue = items.dup
      active = []

      loop do
        while !@halted && active.size < @jobs && !queue.empty?
          entry = queue.shift
          job = yield(entry)
          active << job if job
        end
        break if active.empty?

        now = clock
        wait = active.map { |job| job.deadline - now }.min
        wait = 0.0 if wait.nil? || wait.negative?
        ready = IO.select(active.map(&:reader), nil, nil, wait)

        if ready
          ready.first.each do |reader|
            job = active.find { |candidate| candidate.reader.equal?(reader) }
            next unless job

            finish_job(job, timed_out: false)
            halt_fast_fail(job)
            active.delete(job)
          end
        end

        now = clock
        active.select { |job| now >= job.deadline }.each do |job|
          finish_job(job, timed_out: true)
          active.delete(job)
        end
      end
      mark_skipped(queue) unless controls
    ensure
      active.each do |job|
        kill_process(job)
        reap(job.pid)
        begin
          job.reader.close unless job.reader.closed?
        rescue IOError
          nil
        end
        next if job.control

        job.entry.result ||= error_result(job.entry, "runner aborted before the child finished")
      end
    end

    # `--fail-fast` stops scheduling the moment the first survivor is known.
    # Children already running are allowed to finish: their work is paid for,
    # and their results are evidence the agent wants.
    def halt_fast_fail(job)
      return unless @fail_fast
      return unless job.entry.result&.survived?

      @halted = true
    end

    def mark_skipped(entries)
      return unless @halted

      entries.each do |entry|
        next if entry.done?

        entry.result = Result.new(
          mutant: entry.mutant,
          status: :skipped,
          duration: 0.0,
          message: "not run: --fail-fast stopped at the first survivor"
        )
      end
    end

    # ---- fork isolation -----------------------------------------------------

    def start_fork_job(entry)
      reader, writer = IO.pipe
      started = clock

      pid = fork do
        reader.close
        fork_child(entry, writer)
      end

      writer.close
      Job.new(pid: pid, reader: reader, started_at: started,
              deadline: started + @timeout, entry: entry, pgroup: false)
    rescue StandardError => e
      close_quietly(writer)
      close_quietly(reader)
      entry.result ||= error_result(entry, "#{e.class}: #{e.message}")
      nil
    end

    def start_control_job(control)
      reader, writer = IO.pipe
      started = clock

      pid = fork do
        reader.close
        control_child(control, writer)
      end

      writer.close
      Job.new(pid: pid, reader: reader, started_at: started,
              deadline: started + @timeout, control: control, pgroup: false)
    rescue StandardError => e
      close_quietly(writer)
      close_quietly(reader)
      @controls[control.key] = { ok: false, failed_id: nil, message: "#{e.class}: #{e.message}" }
      nil
    end

    def fork_child(entry, writer)
      begin
        Boot.fire(@config, :child_start, entry.index)
        absolute = File.expand_path(entry.mutant.path.to_s)
        source = entry.source_text || File.read(absolute)
        # eval with the original path rather than load of a temp copy: require_relative
        # and __FILE__ must resolve as they do in the real file, and skipping the write
        # keeps the per-mutant cost to a fork plus one parse.
        quietly { TOPLEVEL_BINDING.eval(entry.mutant.splice(source), absolute, 1) }
      rescue Exception => e # rubocop:disable Lint/RescueException
        write_payload(writer, "boot_error" => true, "error" => describe_exception(e))
        exit!(2)
      end

      run_tests(entry.selected_ids, writer)
    end

    def control_child(control, writer)
      begin
        Boot.fire(@config, :child_start, control.index)
        if control.reload
          absolute = File.expand_path(control.path.to_s)
          quietly { TOPLEVEL_BINDING.eval(control.text || File.read(absolute), absolute, 1) }
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        write_payload(writer, "boot_error" => true, "error" => describe_exception(e))
        exit!(2)
      end

      # A reload control only asks whether the file loads a second time; there
      # is no test to run and no project change for the adapter to observe.
      return run_tests(control.ids, writer) unless control.ids.empty?

      write_payload(writer, "ok" => true)
      exit!(0)
    end

    def run_tests(ids, writer)
      begin
        Boot.fire(@config, :before_test_run)
        outcome = @adapter.run(ids)
      rescue Exception => e # rubocop:disable Lint/RescueException
        write_payload(writer, "test_error" => true, "error" => describe_exception(e))
        exit!(2)
      end

      write_payload(writer,
                    "ok" => outcome.ok,
                    "failed_id" => outcome.failed_id&.to_s,
                    "error" => outcome.error && describe_exception(outcome.error))
      exit!(outcome.ok ? 0 : 1)
    end

    # ---- process isolation --------------------------------------------------

    def start_process_job(entry, grace: 0.0)
      spawn_process(
        entry,
        text: entry.mutant.splice(entry.source_text),
        ids: entry.selected_ids,
        path: entry.mutant.path.to_s,
        neutral: false,
        grace: grace
      )
    end

    # The baseline in process isolation: a bare child that boots the project as a
    # mutant child would, with no mutation applied at all.
    def start_process_control_job(control)
      spawn_process(
        control,
        text: control.text,
        ids: control.ids,
        path: control.path.to_s,
        neutral: control.text.nil?,
        grace: control.grace.to_f
      )
    end

    def spawn_process(subject, text:, ids:, path:, neutral:, grace: 0.0)
      temporary = temp_file_for(subject)
      File.write(temporary, text.to_s)

      reader, writer = IO.pipe
      environment = {
        "RUBY_MUTATION_ROOT" => @adapter.root.to_s,
        "RUBY_MUTATION_TEST_IDS" => JSON.generate(ids.map(&:to_s)),
        "RUBY_MUTATION_MUTANT_PATH" => path,
        "RUBY_MUTATION_MUTATED_FILE" => temporary,
        "RUBY_MUTATION_PAYLOAD_FD" => "3",
        "RUBY_MUTATION_CHILD_INDEX" => subject.index.to_s,
        "RUBY_MUTATION_ENV" => JSON.generate(@config.env),
        "RUBY_MUTATION_REQUIRES" => JSON.generate(@config.requires),
        "RUBY_MUTATION_SETUP" => @config.setup_path.to_s,
        "RUBY_MUTATION_NEUTRAL" => neutral ? "1" : "0"
      }
      started = clock

      pid = Process.spawn(
        environment,
        RbConfig.ruby, "-I", MUTATION_LIB, BOOTSTRAP,
        3 => writer,
        chdir: @adapter.root.to_s,
        pgroup: true
      )

      writer.close
      Job.new(pid: pid, reader: reader, started_at: started,
              deadline: started + @timeout + grace,
              entry: subject.respond_to?(:mutant) ? subject : nil,
              control: subject.respond_to?(:key) ? subject : nil,
              temp_path: temporary, pgroup: true)
    rescue StandardError => e
      close_quietly(writer)
      close_quietly(reader)
      if subject.respond_to?(:key)
        @controls[subject.key] = { ok: false, failed_id: nil, message: "#{e.class}: #{e.message}" }
      else
        subject.result ||= error_result(subject, "#{e.class}: #{e.message}")
      end
      nil
    end

    # ---- completion + classification ---------------------------------------

    def finish_job(job, timed_out:)
      payload = nil
      if timed_out
        kill_process(job)
      else
        payload = read_payload(job.reader)
      end
      _pid, status = reap(job.pid)
      duration = clock - job.started_at

      if job.control
        record_control(job.control, payload, status, timed_out, duration)
      elsif timed_out
        job.entry.result = Result.new(mutant: job.entry.mutant, status: :timeout, duration: duration,
                                      message: "exceeded #{format('%.3f', @timeout)}s deadline")
      else
        job.entry.result = classify(job.entry, payload, status, duration)
      end
    rescue StandardError => e
      if job.control
        @controls[job.control.key] = { ok: false, failed_id: nil,
                                      message: "#{e.class}: #{e.message}" }
      else
        job.entry.result ||= error_result(job.entry, "#{e.class}: #{e.message}", clock - job.started_at)
      end
    ensure
      begin
        job.reader.close unless job.reader.closed?
      rescue IOError
        nil
      end
    end

    def classify(entry, payload, status, duration)
      exit_status = status && status.exitstatus
      if status && status.signaled?
        return Result.new(mutant: entry.mutant, status: :timeout, duration: duration,
                          message: "child died with signal #{status.termsig}")
      end
      if payload.nil?
        # Exit status 1 already means "a selected test failed" (the child only
        # writes a payload on its way out). A child that ends itself mid-suite
        # leaves the status as the only evidence, and it is still a kill:
        # Active Support's test helpers call exit!, and its abstract_unit sets
        # Thread.abort_on_exception, either of which takes the process down
        # before the summary is written.
        if exit_status == 1
          return Result.new(mutant: entry.mutant, status: :killed, duration: duration,
                            message: "the selected tests stopped the child before it " \
                                     "could report (exit 1)")
        end

        return error_result(entry, "child produced no completion signal " \
                                  "(exit #{exit_status.inspect})", duration)
      end
      if payload["test_error"]
        return error_result(entry, payload["error"] || "the child failed while running tests",
                            duration)
      end
      if payload["boot_error"]
        return deferred_unmeasured(entry, payload, duration)
      end
      if payload["ok"] && exit_status == 0
        return Result.new(mutant: entry.mutant, status: :survived, duration: duration,
                          reason: :not_detected)
      end
      if !payload["ok"] && (exit_status == 1 || exit_status.nil?)
        return Result.new(mutant: entry.mutant, status: :killed, duration: duration,
                          failed_test: payload["failed_id"], message: payload["error"])
      end

      error_result(
        entry,
        "inconsistent child result (exit #{exit_status.inspect}, payload #{payload.inspect})",
        duration
      )
    end

    # A child that could not load its file has not tested the mutant. The two
    # causes look identical from here and only one is the mutation's fault: the
    # file may not be reloadable at all (fork isolation re-evaluates it over the
    # parent's copy, so a second load that raises or warns as :raise breaks
    # every mutant of that file), or the mutation itself may not load. The
    # answer needs a second child, so the result stays an error until the pool
    # drains and `attribute_unmeasured` can ask the question without holding up
    # the mutants still in flight.
    def deferred_unmeasured(entry, payload, duration)
      reason = payload["error"] || "the child failed while loading the mutated file"
      # A first-load child already applies the mutation the way the project
      # loads it, so a boot error there is the mutation's or the suite's, not a
      # second-load artefact. It stays unmeasured and the message names the
      # surface.
      if entry.first_load
        return Result.new(mutant: entry.mutant, status: :skipped, duration: duration,
                          message: "not measured: the suite could not load with this " \
                                   "mutation (#{reason})")
      end
      # Process isolation builds the child from the mutated file, so a boot
      # failure there can equally be a setup or harness failure. Only the fork
      # path can ask a second question and tell the two apart.
      return error_result(entry, reason, duration) unless @isolation == :fork

      @unmeasured << [entry, reason]
      error_result(entry, reason, duration)
    end

    # One reload control per distinct file, then rewrite each unexplained load
    # failure with the cause the control proved. Same shape as verify_kills: a
    # batch of controls after the pool, never inside finish_job.
    def attribute_unmeasured
      return if @unmeasured.empty?

      pending = @unmeasured
      @unmeasured = []
      paths = pending.map { |entry, _reason| entry.mutant.path.to_s }.uniq
      controls = paths.map do |path|
        Control.new(key: [:reload, path], index: -1, ids: [], reload: true,
                    path: path, text: source_for(path).text)
      end
      verdicts = run_controls(controls)

      retry_entries = []
      pending.each do |entry, reason|
        verdict = verdicts[[:reload, entry.mutant.path.to_s]]
        next if verdict.nil?

        if verdict[:ok]
          entry.result =
            Result.new(mutant: entry.mutant, status: :skipped,
                       duration: entry.result.duration,
                       message: "not measured: the mutated file does not load (#{reason})")
        else
          # The file itself cannot be loaded twice. The mutant may still be
          # measurable where it is loaded once, so it moves to that surface.
          entry.first_load = true
          retry_entries << entry
        end
      end

      measure_first_load(retry_entries) unless retry_entries.empty?
    end

    # The second surface: a fresh process whose suite loads in its normal order
    # and whose mutation is applied at the target's first load. The reload
    # control already proved the file, not the mutation, is why the fork child
    # could not load it, so this child only asks whether the mutant is
    # measurable at all. A boot error here is reported as skipped, never as a
    # kill or a survival.
    #
    # A neutral boot first measures what such a child costs before any test
    # runs. That fixed cost belongs to the surface, not to the mutant, so the
    # deadline carries it instead of charging it to every retry.
    def measure_first_load(entries)
      grace = first_load_grace
      if grace.nil?
        detail = @first_load_boot_message || "the fresh-process surface did not boot"
        entries.each do |entry|
          entry.result = Result.new(mutant: entry.mutant, status: :skipped,
                                    duration: entry.result.duration,
                                    message: "not measured: #{detail}")
        end
        return
      end

      without_halting do
        run_pool(entries) { |entry| start_process_job(entry, grace: grace) }
      end
      @unmeasured = []
    end

    # -> Float seconds for a bare first-load child, or nil when it cannot boot.
    def first_load_grace
      return @first_load_grace if defined?(@first_load_grace)

      control = Control.new(key: :first_load_boot, index: -1, ids: [], reload: false)
      verdict = run_controls([control]).fetch(:first_load_boot)
      if verdict && verdict[:ok]
        @first_load_grace = verdict[:duration].to_f
      else
        @first_load_boot_message = verdict && verdict[:message]
        @first_load_grace = nil
      end
    end

    # ---- neutral runs -------------------------------------------------------

    # -> {key => {ok:, failed_id:, message:}}
    def run_controls(controls)
      return {} if controls.empty?

      @controls = {}
      # --fail-fast stops the mutant pool, not the check on what it already
      # reported; a control run is a question about the harness, not a mutant.
      without_halting do
        if @isolation == :fork
          folder = controls.reject(&:first_load)
          first_load = controls.select(&:first_load)
          run_pool(folder, controls: true) { |control| start_control_job(control) } unless folder.empty?
          unless first_load.empty?
            run_pool(first_load, controls: true) { |control| start_process_control_job(control) }
          end
        else
          run_pool(controls, controls: true) { |control| start_process_control_job(control) }
        end
      end
      @controls
    end

    def without_halting
      halted = @halted
      fail_fast = @fail_fast
      @halted = false
      @fail_fast = false
      yield
    ensure
      @halted = halted
      @fail_fast = fail_fast
    end

    def record_control(control, payload, status, timed_out, duration)
      @controls[control.key] =
        if timed_out
          { ok: false, failed_id: nil, duration: duration,
            message: "exceeded #{format('%.3f', @timeout)}s deadline" }
        elsif payload.nil?
          { ok: false, failed_id: nil, duration: duration,
            message: "child produced no completion signal (exit #{status && status.exitstatus})" }
        elsif payload["boot_error"] || (status && status.exitstatus == 2)
          { ok: false, failed_id: payload["failed_id"], duration: duration,
            message: payload["error"] || "child boot error" }
        elsif payload["ok"] && status && status.exitstatus.zero?
          { ok: true, failed_id: nil, message: nil, duration: duration }
        else
          { ok: false, failed_id: payload["failed_id"], message: payload["error"],
            duration: duration }
        end
    end

    # The suite with no mutation applied, on the surface this campaign will use.
    # With coverage on, the sampler already ran every test once and reported the
    # baseline; without it nothing has checked the suite, and a red suite would
    # score every covered mutant as killed.
    def verify_baseline!
      return unless @baseline && !@coverage_enabled

      ids = @adapter.test_ids
      return if ids.empty?

      control = Control.new(key: :baseline, index: -1, ids: ids, reload: false)
      verdict = run_controls([control]).fetch(:baseline)
      return if verdict[:ok]

      detail = verdict[:failed_id].to_s
      detail = "#{detail} (#{verdict[:message]})" if verdict[:message]
      detail = verdict[:message].to_s if detail.empty?
      raise BaselineError,
            "the suite is not green with no mutation applied: #{detail}. Every mutant " \
            "that test covers would be reported as killed. Fix the suite, or pass " \
            "--no-baseline to score it anyway."
    end

    # A kill is evidence only if the same test passes with the target file loaded a
    # second time and no mutation applied. Fork isolation applies a mutant by
    # re-executing the file over the parent's copy, so a file that registers itself
    # at load time runs that registration twice and fails a test the mutation never
    # touched. Files with nothing but definitions cannot show this, so only those
    # that run unknown code at load time are checked.
    def verify_kills(entries)
      return unless @baseline

      suspects = entries.select do |entry|
        result = entry.result
        next false if result.nil? || !result.killed? || result.failed_test.nil?

        entry.first_load || load_sensitive?(entry.mutant.path)
      end
      return if suspects.empty?

      controls = suspects.uniq { |entry| kill_key(entry) }.map do |entry|
        Control.new(key: kill_key(entry), index: entry.index, ids: [entry.result.failed_test],
                    reload: true, path: entry.mutant.path, text: entry.source_text,
                    first_load: entry.first_load,
                    grace: entry.first_load ? @first_load_grace.to_f : 0.0)
      end
      verdicts = run_controls(controls)

      suspects.each do |entry|
        verdict = verdicts[kill_key(entry)]
        next if verdict.nil? || verdict[:ok]

        detail = verdict[:message] ? " (#{verdict[:message]})" : ""
        how = if entry.first_load
                "the file is loaded once, with no mutation"
              else
                "the file is loaded a second time and no mutation is applied"
              end
        message = "unverified kill: #{verdict[:failed_id] || "a test"} fails when #{how}#{detail}"
        entry.result = Result.new(mutant: entry.mutant, status: :error,
                                  duration: entry.result.duration,
                                  failed_test: entry.result.failed_test, message: message)
      end
    end

    def kill_key(entry)
      [entry.first_load ? :first_load : :fork, entry.mutant.path, entry.result.failed_test.to_s]
    end

    # Memoised per file: one AST walk says whether the fork path's extra load can
    # be observed by a test at all.
    def load_sensitive?(path)
      absolute = File.expand_path(path.to_s)
      @load_hazards.fetch(absolute) do
        @load_hazards[absolute] = LoadHazard.sensitive?(source_for(path).ast)
      end
    end

    def close_quietly(io)
      io.close if io && !io.closed?
    rescue IOError
      nil
    end

    def read_payload(reader)
      line = reader.gets
      return nil unless line

      JSON.parse(line)
    rescue IOError, JSON::ParserError
      nil
    end

    def reap(pid)
      Process.waitpid2(pid)
    rescue Errno::ECHILD
      nil
    end

    def kill_process(job)
      pid = job.pid
      if job.pgroup
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH, Errno::EPERM, Errno::EINVAL
          nil
        end
      end
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    def write_payload(io, payload)
      io.write(JSON.generate(payload) + "\n")
      io.flush
    rescue StandardError
      nil
    end

    # The message travels to the parent as one JSON line, so it has to be valid
    # UTF-8. Exceptions raised by a test can carry the project's bytes in any
    # encoding: Active Support's transliterate raises with an ASCII-8BIT message
    # holding a GB18030 byte. `JSON.generate` refuses that, and a swallowed
    # serialization error used to cost the parent the whole result.
    def describe_exception(exception)
      message = "#{exception.class}: #{exception.message}"
      unless message.encoding == Encoding::UTF_8 && message.valid_encoding?
        message = message.dup.force_encoding(Encoding::UTF_8).scrub("?")
      end
      message.length > 500 ? message[0, 500] : message
    rescue StandardError
      "unknown exception"
    end

    def quietly
      previous = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = previous
    end

    def error_result(entry, message, duration = 0.0)
      Result.new(mutant: entry.mutant, status: :error, duration: duration, message: message)
    end

    # ---- cache + temp files -------------------------------------------------

    def persist_results
      @entries.each do |entry|
        next if entry.cache_key.nil? || entry.result.nil?
        # A first-load verdict is real, but it was measured on a different
        # surface than the fingerprint names; caching it under the fork key
        # would let a later fork run reuse a number it did not measure.
        next if entry.first_load
        next unless %i[killed survived].include?(entry.result.status)

        @cache.store(entry.cache_key,
                     status: entry.result.status,
                     failed_test: entry.result.failed_test,
                     message: entry.result.message,
                     reason: entry.result.reason)
      end
      @cache.save!
    end

    def temp_dir
      @temp_dir ||= Dir.mktmpdir("ruby-mutation-runner")
    end

    def temp_file_for(entry)
      File.join(temp_dir, "mutant-#{entry.index}.rb")
    end

    def cleanup_temp_dir
      return unless @temp_dir
      return unless File.exist?(@temp_dir)

      FileUtils.remove_entry(@temp_dir)
    rescue StandardError
      nil
    ensure
      @temp_dir = nil
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
