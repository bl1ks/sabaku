# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"

# Shared plumbing for the practical harness. A case is one directory under harness/cases/,
# holding check.rb (assertions, run in its own process by harness/run.rb) and project/ (a
# minitest project the case copies to a scratch directory).
module Harness
  ROOT = File.expand_path("../..", __dir__)
  CASES = File.join(ROOT, "harness", "cases")
  BIN = File.join(ROOT, "bin", "mutation")

  class Failure < StandardError; end

  # One case run. Collects assertion failures instead of raising, so a check reports every
  # problem in one pass rather than one per run.
  class Case
    attr_reader :name, :assertions, :failures, :notes

    def initialize(name)
      @name = name
      @assertions = 0
      @failures = []
      @notes = []
    end

    def dir(*parts) = File.join(CASES, name, *parts)
    def project(*parts) = dir("project", *parts)

    # ---- assertions ----------------------------------------------------------

    def assert(label, ok, detail = nil)
      @assertions += 1
      return true if ok

      @failures << (detail ? "#{label}: #{detail}" : label)
      false
    end

    def assert_equal(label, expected, actual, detail = nil)
      assert(label, expected == actual, detail || "expected #{expected.inspect}, got #{actual.inspect}")
    end

    def assert_operator(label, expected, operator, actual, detail = nil)
      ok = expected.public_send(operator, actual)
      assert(label, ok, detail || "expected #{expected.inspect} #{operator} #{actual.inspect}")
    end

    def assert_includes(label, collection, item)
      assert(label, collection.include?(item), "#{item.inspect} not in #{collection.inspect}")
    end

    def note(text) = @notes << text

    # ---- running the engine --------------------------------------------------

    # Runs bin/mutation in `root`. Returns [stdout, stderr, exit code]. An engine run that
    # blocks past `timeout` is a harness failure, not a silent hang.
    def run(root, *args, env: {}, timeout: 300)
      out = err = nil
      status = nil
      Timeout.timeout(timeout) do
        out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args, chdir: root)
      end
      [out, err, status.exitstatus]
    end

    def campaign(root, *args, env: {}, timeout: 300)
      out, err, code = run(root, "run", "--report=json", *args, env: env, timeout: timeout)
      raise Failure, "expected exit 0, got #{code}\n--- stderr\n#{err}\n--- stdout\n#{out}" unless code.zero?

      payload = parse_report(out)
      raise Failure, "no JSON report on stdout\n--- stdout\n#{out}" if payload.nil?

      payload
    end

    def parse_report(out)
      line = out.lines.reverse.find { |candidate| candidate.start_with?("{") }
      return nil if line.nil?

      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    # mutant id => status. The id pins path, scope, AST path, operator and replacement, so it
    # is the identity the cache uses and the only key that survives a source move.
    def verdicts(payload)
      payload.fetch("results").to_h { |result| [result.fetch("mutant").fetch("id"), result.fetch("status")] }
    end

    def statuses(payload)
      verdicts(payload).values.tally
    end

    # Status per mutant for two runs, ignoring mutants the cheap path leaves uncovered.
    def comparable(cheap, oracle)
      cheap_verdicts = verdicts(cheap)
      oracle_verdicts = verdicts(oracle)
      ids = cheap_verdicts.keys & oracle_verdicts.keys
      ids.reject { |id| cheap_verdicts[id] == "uncovered" || oracle_verdicts[id] == "uncovered" }
         .map { |id| [id, cheap_verdicts[id], oracle_verdicts[id]] }
    end

    def diff_rows(rows)
      rows.select { |_id, cheap, oracle| cheap != oracle }
    end

    # ---- scratch projects ----------------------------------------------------

    # `project/` is read-only in spirit: the engine writes a cache file next to the suite and
    # a case may add a test, so every run gets a fresh copy.
    def copy_project
      source = project
      raise Failure, "missing #{source}" unless File.directory?(source)

      Dir.mktmpdir("practical-#{name}") do |dir|
        FileUtils.cp_r(File.join(source, "."), dir)
        FileUtils.rm_f(File.join(dir, ".mutation-cache.json"))
        yield dir
      end
    end

    def write(root, relative, text)
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      path
    end

    def elapsed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    # ---- result --------------------------------------------------------------

    def finish
      return unless $PROGRAM_NAME.end_with?("check.rb")

      if failures.empty?
        puts "PASS #{name} (#{assertions} assertions, #{notes.join(' ')})"
        exit 0
      end

      warn "FAIL #{name} (#{failures.size} of #{assertions} assertions)"
      failures.first(12).each { |failure| warn "  - #{failure}" }
      warn "  ... and #{failures.size - 12} more" if failures.size > 12
      exit 1
    end
  end

  def self.case(name)
    instance = Case.new(name)
    begin
      yield instance
    rescue Failure => e
      instance.assert("case aborted", false, e.message.lines.first.to_s.strip)
      warn "  detail: #{e.message.lines.drop(1).join.strip}" if e.message.lines.size > 1
    end
    instance.finish
  end
end

def practical_case(name)
  Harness.case(name) { |kase| yield kase }
end
