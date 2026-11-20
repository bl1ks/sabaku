# frozen_string_literal: true

require_relative "../../lib/support"

require "json"
require "open3"
require "rbconfig"
require "timeout"

# Claim: a mutation that hangs costs the deadline and nothing more.
# Falsified by: a hang reported `survived`, or a campaign that outlives
# mutants x timeout.
#
# The fixture hangs two ways. Counter#down's decrement is one arithmetic mutation
# from ascending forever, and the suite's armed test sleeps 30s when a mutated
# guard lets its block run for a negative delay. Both have to come back as
# `timeout` at the deadline, the campaign has to finish inside mutants x timeout,
# and the process table has to be clean afterwards.
module TimeoutCase
  # A killed child is reparented before it can be seen; give the kernel a beat.
  SETTLE = 0.5
  # A campaign this case cannot finish in 150s is a harness failure, not a red
  # claim: the run.rb budget is the one that reports an overrun.
  GUARD = 150

  module_function

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # `ps -e -o pid,ppid,stat,command` when the image has procps; ruby:3.4-slim
  # does not, so /proc is read directly. Both rows carry the same four fields,
  # and /proc is what ps reads.
  def process_table
    ps_table || proc_table
  end

  def ps_table
    out, _err, status = Open3.capture2e("ps", "-e", "-o", "pid,ppid,stat,command")
    return nil unless status.success?

    out.lines.drop(1).filter_map do |line|
      pid, ppid, state, command = line.strip.split(/\s+/, 4)
      next unless pid.to_s.match?(/\A\d+\z/)

      { pid: pid.to_i, ppid: ppid.to_i, state: state.to_s[0], command: command.to_s }
    end
  rescue StandardError
    nil
  end

  def proc_table
    Dir.children("/proc").grep(/\A\d+\z/).sort.filter_map do |entry|
      dir = File.join("/proc", entry)
      stat = File.read(File.join(dir, "stat"))
      close = stat.rindex(")")
      next nil if close.nil?

      head = stat[0...close]
      comm = head[/\((.*)\z/m, 1].to_s
      state, ppid, pgrp = stat[(close + 1)..].split(" ")
      command = File.binread(File.join(dir, "cmdline")).tr("\0", " ").strip
      { pid: head[/\A\d+/].to_i, ppid: ppid.to_i, pgrp: pgrp.to_i, state: state.to_s,
        command: command.empty? ? comm : command }
    rescue SystemCallError, IOError
      nil
    end
  end

  # Rows that could only be a campaign process: its own process group, or a copy
  # of the CLI that escaped the group. Our own pid is the harness, never a
  # campaign. A zombie keeps its pgrp, so a child the campaign never reaped is
  # still listed here.
  def campaign_rows(rows, pgid)
    rows.select do |row|
      next false if row[:pid] == Process.pid

      row[:pgrp] == pgid || row[:command].include?("bin/sabaku")
    end
  end

  def zombie_children(rows)
    rows.select { |row| row[:state] == "Z" && row[:ppid] == Process.pid }
  end

  def describe(rows, limit: 4)
    return "none" if rows.empty?

    rows.first(limit).map do |row|
      "pid=#{row[:pid]} ppid=#{row[:ppid]} state=#{row[:state]} #{row[:command][0, 64]}"
    end.join("; ")
  end

  # The campaign under test, run the way honouring the claim requires: in its own
  # process group, so anything it fails to kill and reap is still attributable
  # after it has exited.
  def measured(root, *args)
    before = process_table
    started = clock
    stdin, stdout, stderr, waiter = Open3.popen3(
      RbConfig.ruby, Harness::BIN, "run", "--report=json", *args,
      chdir: root, pgroup: true
    )
    stdin.close
    out_thread = Thread.new { stdout.read }
    err_thread = Thread.new { stderr.read }
    # Sample the table while the campaign runs. A clean table afterwards only
    # means something if the campaign really had children to leave behind.
    seen = 0
    pgid = waiter.pid
    sampler = Thread.new do
      loop do
        rows = campaign_rows(process_table, pgid)
        seen = rows.size if rows.size > seen
        sleep 0.05
      end
    end
    status = begin
      Timeout.timeout(GUARD) { waiter.value }
    rescue Timeout::Error
      kill_group(pgid)
      raise Harness::Failure, "campaign exceeded #{GUARD}s: #{args.inspect}"
    ensure
      sampler.kill
    end
    seconds = clock - started
    stdout_text = out_thread.value
    stderr_text = err_thread.value
    stdout.close unless stdout.closed?
    stderr.close unless stderr.closed?
    sleep SETTLE
    after = process_table
    { status: status, payload: parse(stdout_text), stdout: stdout_text,
      stderr: stderr_text, seconds: seconds, pgid: pgid, seen: seen,
      before: before, after: after }
  end

  def parse(text)
    line = text.lines.reverse.find { |candidate| candidate.start_with?("{") }
    return nil if line.nil?

    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def kill_group(pgid)
    Process.kill("KILL", -pgid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def timeout_ids(payload)
    payload["results"].select { |result| result["status"] == "timeout" }
                       .map { |result| result["mutant"]["id"] }
  end

  # Items 1-3 for one campaign: green, deadline-bounded, nothing left behind.
  def assert_campaign(k, label, run, timeout:)
    code = run[:status]&.exitstatus
    k.assert_equal("#{label}: campaign exits 0", 0, code,
                   "exit #{code.inspect}; stderr: #{run[:stderr].lines.last(6).join.strip}")
    payload = run[:payload]
    k.assert("#{label}: report parses", !payload.nil?, run[:stdout].lines.last(3).join.strip)
    return nil unless payload

    counts = payload.slice("killed", "survived", "timeout", "error")
    results = payload["results"]
    timeouts = results.select { |result| result["status"] == "timeout" }
    durations = results.map { |result| result["duration"] }
    slowest = durations.max.to_f

    k.assert_operator("#{label}: the fixture really hangs", counts["timeout"], :>=, 2,
                      "counts: #{counts.inspect}")
    k.assert_equal("#{label}: no mutant errored", 0, counts["error"],
                   results.select { |r| r["status"] == "error" }.map { |r| r["message"] }.first(3).inspect)
    k.assert_operator("#{label}: no duration exceeds #{timeout + 0.5}s", slowest, :<=,
                      timeout + 0.5, "max duration #{slowest}")

    denominator = counts["killed"] + counts["survived"] + counts["timeout"]
    expected_score = denominator.zero? ? 0.0 : counts["killed"].fdiv(denominator).round(4)
    k.assert_equal("#{label}: score counts the timeouts", expected_score, payload["score"],
                   "killed=#{counts['killed']} survived=#{counts['survived']} " \
                   "timeout=#{counts['timeout']} reported=#{payload['score']}")

    # The deadline is what ended each hanging child. A timeout that came back in
    # a fraction of the deadline was killed by something else, and a `survived`
    # hang is the falsification this case exists for.
    shortest = timeouts.map { |result| result["duration"] }.min.to_f
    k.assert_operator("#{label}: every timeout ran to the deadline", shortest, :>=,
                      (timeout * 0.9).round(3), "shortest timeout duration #{shortest}")

    bound = payload["mutants"] * timeout + 20
    k.assert_operator("#{label}: campaign is bounded by mutants x timeout",
                      run[:seconds].round(2), :<=, bound,
                      format("%.1fs > %.1fs (mutants=%d, timeout=%s)",
                             run[:seconds], bound, payload["mutants"], timeout))

    leftover = campaign_rows(run[:after], run[:pgid])
    k.assert("#{label}: no campaign process survives", leftover.empty?, describe(leftover))
    zombies = zombie_children(run[:after])
    k.assert("#{label}: no zombie children of the harness", zombies.empty?, describe(zombies))
    k.assert_operator("#{label}: the campaign really forked", run[:seen], :>=, 2,
                      "the campaign never had a child in the table while it ran")

    k.note(format("%s mutants=%d timeouts=%d maxdur=%.3fs wall=%.1fs bound=%.1fs " \
                  "leftovers=%d before=%d seen=%d",
                  label, payload["mutants"], counts["timeout"], slowest, run[:seconds], bound,
                  leftover.size, campaign_rows(run[:before], run[:pgid]).size, run[:seen]))
    payload
  end
end

practical_case("timeout") do |k|
  parallel = nil
  serial = nil

  # Cold: a fresh copy per run, so no verdict is carried over and every hang has
  # to be paid for again.
  k.copy_project do |dir|
    parallel = TimeoutCase.assert_campaign(
      k, "jobs=2", TimeoutCase.measured(dir, "lib", "--timeout=1", "--jobs=2", "--per-line=all"),
      timeout: 1.0
    )
  end

  k.copy_project do |dir|
    serial = TimeoutCase.assert_campaign(
      k, "jobs=1", TimeoutCase.measured(dir, "lib", "--timeout=1", "--jobs=1", "--per-line=all"),
      timeout: 1.0
    )
  end

  # Two jobs or one, the same mutants hang: the pool only changes how much of
  # the deadline is paid at once.
  if parallel && serial
    k.assert_equal("jobs does not change the verdicts",
                   parallel.slice("killed", "survived", "timeout", "error"),
                   serial.slice("killed", "survived", "timeout", "error"))
    k.assert_equal("jobs does not change which mutants hang",
                   TimeoutCase.timeout_ids(parallel).sort, TimeoutCase.timeout_ids(serial).sort)
  end

  # The deadline is the knob: halving it times out the same mutants, sooner.
  k.copy_project do |dir|
    halved = TimeoutCase.assert_campaign(
      k, "timeout=0.5",
      TimeoutCase.measured(dir, "lib", "--timeout=0.5", "--jobs=2", "--per-line=all"),
      timeout: 0.5
    )
    next unless parallel && halved

    expected = TimeoutCase.timeout_ids(parallel).sort
    actual = TimeoutCase.timeout_ids(halved).sort
    k.assert_equal("timeout=0.5 reports the same hanging mutants", expected, actual,
                   "timeout=1: #{expected.inspect}, timeout=0.5: #{actual.inspect}")

    halved_slowest = halved["results"].select { |r| r["status"] == "timeout" }
                                    .map { |r| r["duration"] }.max.to_f
    k.assert_operator("the shorter deadline is the one that fired", halved_slowest, :<, 0.9,
                      "slowest timeout at 0.5s was #{halved_slowest}s")
    k.assert_equal("the statuses survive a shorter deadline",
                   parallel.slice("killed", "survived", "timeout"),
                   halved.slice("killed", "survived", "timeout"))
  end

  # The one path that can call a mutant `survived` without running a child is the
  # weak probe pass. A hang that hides anywhere hides there, so compare the
  # deadline's verdicts against the full-run path: a mutant the default run calls
  # survived and this run times out is exactly the falsification.
  k.copy_project do |dir|
    full = TimeoutCase.assert_campaign(
      k, "no-weak",
      TimeoutCase.measured(dir, "lib", "--timeout=1", "--jobs=2", "--per-line=all", "--no-weak"),
      timeout: 1.0
    )
    next unless parallel && full

    k.assert_equal("the weak pass hides no hang", TimeoutCase.timeout_ids(parallel).sort,
                   TimeoutCase.timeout_ids(full).sort,
                   "without the probe pass the engine times out " \
                   "#{TimeoutCase.timeout_ids(full).size} mutants, not " \
                   "#{TimeoutCase.timeout_ids(parallel).size}")
    k.assert_equal("no survivor is a hang on the full-run path",
                   [], (TimeoutCase.timeout_ids(full) &
                        parallel["results"].select { |r| r["status"] == "survived" }
                                        .map { |r| r["mutant"]["id"] }),
                   "these ids survive the default run and time out without the weak pass")
  end

  # A deadline must not turn a green suite red: the same project, one second,
  # default depth.
  k.copy_project do |dir|
    plain = TimeoutCase.measured(dir, "lib", "--timeout=1")
    code = plain[:status]&.exitstatus
    k.assert_equal("a green suite at --timeout=1 exits 0", 0, code,
                   "exit #{code.inspect}; stderr: #{plain[:stderr].lines.last(6).join.strip}")
    payload = plain[:payload]
    k.assert("the green-suite run reports", !payload.nil?, plain[:stdout].lines.last(3).join.strip)
    k.assert_equal("the green-suite run has no error", 0, payload && payload["error"],
                   payload && payload["results"].select { |r| r["status"] == "error" }
                                         .map { |r| r["message"] }.first(3).inspect)
    leftover = TimeoutCase.campaign_rows(plain[:after], plain[:pgid])
    k.assert("the green-suite run leaves nothing behind", leftover.empty?,
             TimeoutCase.describe(leftover))
    k.note(format("plain mutants=%s timeouts=%s wall=%.1fs leftovers=%d seen=%d",
                  payload && payload["mutants"], payload && payload["timeout"],
                  plain[:seconds], leftover.size, plain[:seen]))
  end
end
