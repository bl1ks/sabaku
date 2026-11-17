# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

require_relative "cache"
require_relative "coverage_map"
require_relative "errors"
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
  # The parent preloads the adapter once, then forks one child per mutant (the
  # fast path) or spawns a fresh Ruby running runtime/bootstrap.rb (the portable
  # path). A pipe write from the child is the completion signal; a deadline is
  # enforced with IO.select and SIGKILL, and every child is reaped.
  class Runner
    MUTATION_LIB = File.expand_path("..", __dir__)
    BOOTSTRAP = File.join(MUTATION_LIB, "mutation", "runtime", "bootstrap.rb")

    Entry = Struct.new(:index, :mutant, :selected_ids, :source_text, :cache_key, :result,
                       keyword_init: true) do
      def done?
        !result.nil?
      end
    end

    Job = Struct.new(:pid, :reader, :started_at, :deadline, :entry, :temp_path, :pgroup,
                     keyword_init: true)

    def initialize(config, analyzer: nil, adapter:, coverage_map: nil)
      @config = config
      @analyzer = analyzer
      @adapter = adapter
      @coverage_map = coverage_map || CoverageMap.empty
      @jobs = [Integer(config.respond_to?(:jobs) ? (config.jobs || 1) : 1), 1].max
      @timeout = Float(config.respond_to?(:timeout) ? (config.timeout || 5.0) : 5.0)
      @isolation = (config.respond_to?(:isolation) ? config.isolation : :fork).to_sym
      @coverage_enabled = config.respond_to?(:coverage) ? config.coverage : true
      @cache = Cache.new(Cache.default_path(config), enabled: !Cache.disabled?)
      @source_cache = {}
      @statement_spans = {}
      @all_test_ids = nil
      @temp_dir = nil
    end

    # mutants: Array[Mutant] -> Array[Result] in the same order.
    def call(mutants)
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
            message: hit[:message]
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

      tests = @coverage_map.tests_for_span(mutant.path, mutant.line,
                                           source.line_of(mutant.end_offset - 1))
      return tests unless tests.empty?

      # Ruby's line coverage is coarse inside one expression: a five-line `a && b && c`
      # chain is reported as its first and last line only. Fall back to the statement the
      # mutant belongs to, or a mutant in a multi-line expression is silently dropped from
      # the score as uncovered.
      span = statement_span(source, mutant)
      return [] if span.nil?

      @coverage_map.tests_for_span(mutant.path, source.line_of(span[0]),
                                   source.line_of(span[1] - 1))
    end

    # Maps [start_offset, end_offset] of every node to the span of the statement that
    # contains it. Built once per file with one AST walk.
    def statement_span(source, mutant)
      spans = (@statement_spans[source.rel_path] ||= build_statement_spans(source))
      spans[[mutant.start_offset, mutant.end_offset]]
    end

    def build_statement_spans(source)
      map = {}
      stack = [[source.ast, nil]]
      until stack.empty?
        node, statement = stack.pop
        span = [node.location.start_offset, node.location.end_offset]
        map[span] ||= statement || span
        if node.is_a?(Prism::StatementsNode)
          node.compact_child_nodes.each do |child|
            stack.push([child, [child.location.start_offset, child.location.end_offset]])
          end
        else
          node.compact_child_nodes.each { |child| stack.push([child, statement]) }
        end
      end
      map
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
          "ruby-mutation-cache-v1",
          mutant.id.to_s,
          Digest::SHA256.hexdigest(mutated_source.to_s),
          @adapter.name.to_s,
          RUBY_VERSION,
          selected.map(&:to_s).sort.join("\u0000")
        ].join("\u0000")
      )
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
      case @isolation
      when :fork
        @adapter.preload!
        run_pool(entries) { |entry| start_fork_job(entry) }
      when :process
        # No parent preload needed unless selection was disabled and test_ids
        # were enumerated above; the bootstrap preloads in its own process.
        run_pool(entries) { |entry| start_process_job(entry) }
      else
        raise Mutation::Error,
              "unknown isolation #{@isolation.inspect} (expected :fork or :process)"
      end
    end

    # At most @jobs children in flight. IO.select wakes us on a completion
    # signal or at the nearest deadline, so one slow/timed-out child never
    # blocks the others.
    def run_pool(entries)
      queue = entries.dup
      active = []

      loop do
        while active.size < @jobs && !queue.empty?
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
            active.delete(job)
          end
        end

        now = clock
        active.select { |job| now >= job.deadline }.each do |job|
          finish_job(job, timed_out: true)
          active.delete(job)
        end
      end
    ensure
      active.each do |job|
        kill_process(job)
        reap(job.pid)
        begin
          job.reader.close unless job.reader.closed?
        rescue IOError
          nil
        end
        job.entry.result ||= error_result(job.entry, "runner aborted before the child finished")
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
      begin
        writer.close if defined?(writer) && writer && !writer.closed?
      rescue IOError
        nil
      end
      begin
        reader.close if defined?(reader) && reader && !reader.closed?
      rescue IOError
        nil
      end
      entry.result ||= error_result(entry, "#{e.class}: #{e.message}")
      nil
    end

    def fork_child(entry, writer)
      begin
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

      begin
        outcome = @adapter.run(entry.selected_ids)
      rescue Exception => e # rubocop:disable Lint/RescueException
        write_payload(writer, "boot_error" => true, "error" => describe_exception(e))
        exit!(2)
      end

      write_payload(writer,
                    "ok" => outcome.ok,
                    "failed_id" => outcome.failed_id&.to_s,
                    "error" => outcome.error && describe_exception(outcome.error))
      exit!(outcome.ok ? 0 : 1)
    end

    # ---- process isolation --------------------------------------------------

    def start_process_job(entry)
      path = temp_file_for(entry)
      File.write(path, entry.mutant.splice(entry.source_text))

      reader, writer = IO.pipe
      environment = {
        "RUBY_MUTATION_ROOT" => @adapter.root.to_s,
        "RUBY_MUTATION_ADAPTER" => @adapter.name.to_s,
        "RUBY_MUTATION_TEST_IDS" => JSON.generate(entry.selected_ids.map(&:to_s)),
        "RUBY_MUTATION_MUTANT_PATH" => entry.mutant.path.to_s,
        "RUBY_MUTATION_MUTATED_FILE" => path,
        "RUBY_MUTATION_PAYLOAD_FD" => "3"
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
              deadline: started + @timeout, entry: entry, temp_path: path, pgroup: true)
    rescue StandardError => e
      begin
        writer.close if defined?(writer) && writer && !writer.closed?
      rescue IOError
        nil
      end
      begin
        reader.close if defined?(reader) && reader && !reader.closed?
      rescue IOError
        nil
      end
      entry.result ||= error_result(entry, "#{e.class}: #{e.message}")
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

      job.entry.result =
        if timed_out
          Result.new(mutant: job.entry.mutant, status: :timeout, duration: duration,
                     message: "exceeded #{format('%.3f', @timeout)}s deadline")
        else
          classify(job.entry, payload, status, duration)
        end
    rescue StandardError => e
      job.entry.result ||= error_result(job.entry, "#{e.class}: #{e.message}", clock - job.started_at)
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
        return error_result(entry, "child produced no completion signal " \
                                  "(exit #{exit_status.inspect})", duration)
      end
      if payload["boot_error"] || exit_status == 2
        return error_result(entry, payload["error"] || "child boot error", duration)
      end
      if payload["ok"] && exit_status == 0
        return Result.new(mutant: entry.mutant, status: :survived, duration: duration)
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

    def describe_exception(exception)
      message = "#{exception.class}: #{exception.message}"
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
        next unless %i[killed survived].include?(entry.result.status)

        @cache.store(entry.cache_key,
                     status: entry.result.status,
                     failed_test: entry.result.failed_test,
                     message: entry.result.message)
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
