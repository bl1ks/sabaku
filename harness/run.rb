#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs every practical acceptance case in its own process and prints one line per case.
# Exits nonzero when a case fails, times out, or crashes. See harness/README.md for the
# criteria these cases encode.

require "json"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
CASES = File.join(ROOT, "harness", "cases")
DEFAULT_BUDGET = 300

only = ARGV.filter_map { |arg| arg.delete_prefix("--only=") if arg.start_with?("--only=") }
list = ARGV.include?("--list")

cases = Dir[File.join(CASES, "*")]
        .select { |dir| File.file?(File.join(dir, "check.rb")) }
        .sort
cases.select! { |dir| only.include?(File.basename(dir)) } unless only.empty?

if cases.empty?
  warn "practical: no cases in #{CASES}"
  exit 2
end

if list
  cases.each { |dir| puts File.basename(dir) }
  exit 0
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Kills the case's whole process group: a campaign forks grandchildren, and a case that
# overruns its budget must not leave them behind.
def terminate(pid)
  Process.kill("-TERM", pid)
rescue Errno::ESRCH
  nil
ensure
  deadline = now + 3
  loop do
    begin
      break if Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      break
    end
    break if now > deadline

    sleep 0.1
  end
  begin
    Process.kill("-KILL", pid)
  rescue Errno::ESRCH
    nil
  end
end

def budget_for(dir)
  path = File.join(dir, "case.json")
  return DEFAULT_BUDGET unless File.file?(path)

  Integer(JSON.parse(File.read(path)).fetch("budget", DEFAULT_BUDGET))
rescue JSON::ParserError, ArgumentError, KeyError
  DEFAULT_BUDGET
end

def run_case(dir)
  check = File.join(dir, "check.rb")
  budget = budget_for(dir)
  started = now

  out_r, out_w = IO.pipe
  err_r, err_w = IO.pipe
  pid = Process.spawn(RbConfig.ruby, check, pgroup: true, chdir: ROOT, out: out_w, err: err_w)
  out_w.close
  err_w.close
  out_thread = Thread.new { out_r.read }
  err_thread = Thread.new { err_r.read }

  status = nil
  deadline = started + budget
  loop do
    begin
      reaped, child_status = Process.waitpid2(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      reaped = nil
      child_status = nil
    end
    if reaped
      status = child_status
      break
    end
    break if now > deadline

    sleep 0.1
  end

  timed_out = status.nil?
  terminate(pid) if timed_out

  out = out_thread.value.to_s
  err = err_thread.value.to_s
  out_r.close
  err_r.close

  seconds = now - started
  verdict_line = out.lines.reverse.find { |line| line.start_with?("PASS ", "FAIL ") }

  if timed_out
    { name: File.basename(dir), ok: false, seconds: seconds, reason: "timeout after #{budget}s",
      detail: err.lines.last(12).join }
  elsif verdict_line&.start_with?("PASS ") && status.success?
    { name: File.basename(dir), ok: true, seconds: seconds, reason: verdict_line.strip, detail: "" }
  else
    reason = verdict_line&.strip || "no verdict (exit #{status.exitstatus.inspect})"
    detail = (err.lines.last(20) + out.lines.last(10)).join
    { name: File.basename(dir), ok: false, seconds: seconds, reason: reason, detail: detail }
  end
end

results = cases.map { |dir| run_case(dir) }

results.each do |result|
  format_string = result[:ok] ? "  ok    %-12s %6.1fs  %s" : "  RED   %-12s %6.1fs  %s"
  puts format_string % [result[:name], result[:seconds], result[:reason]]
  next if result[:ok] || result[:detail].to_s.empty?

  result[:detail].lines.each { |line| puts "          #{line.chomp}" }
end

passed = results.count { |result| result[:ok] }
puts
puts "practical: #{passed}/#{results.size} cases passed"
puts "A red case is an engine bug or a harness bug, never a budget. See harness/README.md."
exit(passed == results.size ? 0 : 1)
