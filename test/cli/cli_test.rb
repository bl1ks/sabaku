# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "stringio"
require "json"

class CLITest < Minitest::Test
  def in_project
    Dir.mktmpdir("sabaku-cli") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "subject.rb"), "def add(a, b)\n  a + b\nend\n")
      Dir.chdir(dir) { yield }
    end
  end

  def start(argv)
    out = StringIO.new
    err = StringIO.new
    code = Sabaku::CLI.start(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  def test_list_help_prints_the_options_and_lists_nothing
    in_project do
      code, out, = start(["list", "--help"])

      assert_equal 0, code
      assert_includes out, "usage: mutation"
      refute_match(/^\d+ mutants$/, out)
    end
  end

  def test_run_help_prints_the_options_and_runs_nothing
    in_project do
      code, out, err = start(["run", "--limit=0", "--help"])

      assert_equal 0, code
      assert_includes out, "usage: mutation"
      refute_includes err, "no mutants to run"
    end
  end

  def test_the_removed_adapter_flag_is_rejected
    in_project do
      code, _out, err = start(["list", "--adapter=rspec"])

      assert_equal 2, code
      assert_includes err, "invalid option: --adapter=rspec"
    end
  end

  def test_doctor_reports_minitest_only
    in_project do
      code, out, err = start(["doctor"])

      assert_equal 0, code, err
      assert_includes out, "minitest"
      refute_includes out, "rspec"
    end
  end

  def test_since_restricts_the_mutants_to_the_lines_a_revision_changed
    Dir.mktmpdir("sabaku-cli-git") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("lib")
        File.write("lib/subject.rb", "def one(a, b)\n  a + b\nend\n\ndef two(a, b)\n  a * b\nend\n")
        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        git("add", "-A")
        git("-c", "maintenance.auto=false", "-c", "gc.auto=0", "commit", "-qm", "one")

        File.write("lib/subject.rb", "def one(a, b)\n  a + b\nend\n\ndef two(a, b)\n  a / b\nend\n")
        code, out, err = start(["list", "--since=HEAD"])

        assert_equal 0, code, err
        lines = out.scan(/^[ \t]+(\d+)[ \t]+[a-z]+/).flatten.map(&:to_i).uniq
        refute_empty lines
        assert_equal [6], lines, "only the changed line should be mutated:\n#{out}"
      end
    ensure
      reap_stragglers
    end
  end

  def test_per_line_all_keeps_every_candidate
    in_project do
      File.write("lib/subject.rb", "def add(a, b)\n  a + b\nend\n")
      File.write("lib/more.rb", "x = [1, 2]\nxs = [3]\n")

      _code, one, = start(["list", "--per-line=1"])
      _code, all, = start(["list", "--per-line=all"])

      assert_operator total(all), :>, total(one)
    end
  end

  def test_env_requires_a_value
    in_project do
      code, _out, err = start(["list", "--env=NOPE"])

      assert_equal 2, code
      assert_includes err, "--env"
    end
  end

  def glob_project
    File.write("lib/glob_subject.rb", "class GlobSubject\n  def add(a, b)\n    a + b\n  end\nend\n")
    FileUtils.mkdir_p("test")
    File.write("test/glob_subject_case.rb", <<~RUBY)
      require "minitest/autorun"
      require "glob_subject"

      class GlobSubjectCase < Minitest::Test
        def test_add
          assert_equal 5, GlobSubject.new.add(2, 3)
        end
      end
    RUBY
  end

  def test_tests_flag_chooses_the_test_files
    in_project do
      glob_project

      code, out, err = start(["run", "lib/glob_subject.rb", "--tests=test/*_case.rb", "--report=json"])

      assert_equal 0, code, err
      assert_operator JSON.parse(out.lines.last)["killed"], :>, 0
    end
  end

  def test_the_test_glob_environment_variable_is_read_by_the_cli
    in_project do
      glob_project
      ENV["SABAKU_TEST_GLOB"] = "test/*_case.rb"

      cfg = Sabaku::CLI.new([]).send(:build_config, {})

      assert_equal ["test/*_case.rb"], cfg.test_globs
      assert_equal ["test/x_case.rb"], Sabaku::CLI.new([]).send(:build_config, { tests: ["test/x_case.rb"] }).test_globs
    ensure
      ENV.delete("SABAKU_TEST_GLOB")
    end
  end

  def test_fail_fast_reports_the_rest_as_skipped
    in_project do
      File.write("lib/subject.rb", <<~RUBY)
        class Subject
          def add(a, b)
            a + b
          end

          def mul(a, b)
            a * b
          end
        end
      RUBY
      FileUtils.mkdir_p("test")
      File.write("test/subject_test.rb", <<~RUBY)
        require "minitest/autorun"
        require "subject"

        class SubjectTest < Minitest::Test
          def test_add_is_truthy
            assert Subject.new.add(2, 3)
          end

          def test_mul_is_truthy
            assert Subject.new.mul(2, 3)
          end
        end
      RUBY

      code, out, err = start(["run", "lib", "--fail-fast", "--jobs=1", "--limit=3",
                              "--report=json"])
      payload = JSON.parse(out.lines.last)

      assert_equal 0, code, err
      assert_equal 1, payload["survived"]
      assert_equal 1, payload["skipped"]
      assert_equal 0, payload["killed"]
    end
  end

  # A survivor the probe pass proved costs no child, so --fail-fast has to stop before the
  # first fork. Before this, a not_infected survivor was known before execution started and
  # the campaign still ran every remaining mutant, which made the flag a no-op on exactly
  # the suites the weak pass is good at.
  def test_fail_fast_stops_at_a_survivor_the_probe_pass_proved
    in_project do
      # Its own file and class: two campaigns in one process share $LOADED_FEATURES, so a
      # second test reusing "subject" would silently keep the previous project's class.
      File.write("lib/tier_gate.rb", <<~RUBY)
        class TierGate
          def tier(weight)
            weight > 10 ? 50 : 20
          end

          def add(a, b)
            a + b
          end
        end
      RUBY
      FileUtils.mkdir_p("test")
      File.write("test/tier_gate_test.rb", <<~RUBY)
        require "minitest/autorun"
        require "tier_gate"

        class TierGateTest < Minitest::Test
          def test_the_light_tier
            assert_equal 20, TierGate.new.tier(2)
          end

          def test_add
            assert_equal 5, TierGate.new.add(2, 3)
          end
        end
      RUBY

      code, out, err = start(["run", "lib/tier_gate.rb", "--fail-fast", "--jobs=1", "--report=json"])
      payload = JSON.parse(out.lines.last)

      assert_equal 0, code, err
      assert_equal 1, payload["survived"], "the tier boundary is the survivor"
      assert_equal 0, payload["killed"], "the killable mutants must not run after the halt"
      assert_operator payload["skipped"], :>=, 1
      halted = payload["results"].find { |result| result["status"] == "skipped" }
      assert_match(/--fail-fast/, halted["message"].to_s)
    end
  end

  # Ruby's line coverage marks an endless method's line while the class body runs and never
  # increments it on a call, so a per-test diff attributes it to no test. That used to make
  # the mutant `uncovered`, which drops it from the score without ever running it. The line
  # cannot be attributed, so the runner must run the suite for it instead of grading itself
  # on nothing.
  def test_an_endless_method_line_is_measured_instead_of_uncovered
    in_project do
      File.write("lib/endless.rb", <<~RUBY)
        class Endless
          def value = 7
        end

        class Plain
          def unused
            41
          end
        end
      RUBY
      FileUtils.mkdir_p("test")
      File.write("test/endless_test.rb", <<~RUBY)
        require "minitest/autorun"
        require "endless"

        class EndlessTest < Minitest::Test
          def test_value
            assert_equal 7, Endless.new.value
          end
        end
      RUBY

      code, out, err = start(["run", "lib/endless.rb", "--per-line=all", "--report=json"])
      payload = JSON.parse(out.lines.last)
      by_line = payload["results"].group_by { |result| result["mutant"]["line"] }

      assert_equal 0, code, err
      endless = by_line.fetch(2, [])
      plain = by_line.fetch(7, [])
      refute_empty endless, "the endless method must still yield mutants"
      assert_equal ["killed"], endless.map { |result| result["status"] }.uniq
      refute_empty plain, "the untested method must still yield a mutant"
      assert_equal ["uncovered"], plain.map { |result| result["status"] }.uniq
    end
  end

  def test_a_campaign_where_no_mutant_can_run_exits_2
    in_project do
      FileUtils.mkdir_p("test")
      File.write("test/subject_test.rb", "require \"missing_gem_xyz\"\n")

      code, out, err = start(["run", "lib", "--no-coverage", "--report=json"])
      payload = JSON.parse(out.lines.last)

      assert_equal 2, code
      assert_operator payload["error"], :>, 0
      assert_equal 0, payload["killed"]
      assert_includes err, "produced no result"
      assert_includes err, "first error at"
    end
  ensure
    reap_stragglers
  end

  # A basename of its own: `require` resolves by feature name, so a second
  # project with lib/subject.rb in the same process would silently reuse the
  # first project's copy and this test would pass for the wrong reason.
  def test_strengthening_a_test_invalidates_the_cached_verdict
    in_project do
      File.write("lib/counter.rb", "class Counter\n  def mul(a, b)\n    a * b\n  end\nend\n")
      FileUtils.mkdir_p("test")
      write_test("assert Counter.new.mul(2, 3)\n")

      _code, out, = start(["run", "lib", "--operators=aor", "--report=json"])
      weak = JSON.parse(out.lines.last)

      write_test("assert_equal 6, Counter.new.mul(2, 3)\n")
      _code, out, = start(["run", "lib", "--operators=aor", "--report=json"])
      strong = JSON.parse(out.lines.last)

      assert_operator weak["survived"], :>, 0, "the weak suite should have survivors"
      assert_equal 0, strong["survived"], "a cached verdict outlived the test that produced it"
      assert_operator strong["killed"], :>, 0
    end
  end

  # A probe decides this survivor from the dry run, so its duration proves no child ran.
  def test_weak_probes_decide_a_survivor_without_running_it
    in_project do
      File.write("lib/spin.rb", "class Spin\n  def sub(a, b)\n    a - b\n  end\nend\n")
      FileUtils.mkdir_p("test")
      write_test("assert_equal 5, Spin.new.sub(5, 0)\n", basename: "spin", klass: "SpinTest")

      code, out, err = start(["run", "lib", "--operators=aor", "--per-line=all", "--report=json"])
      payload = JSON.parse(out.lines.last)

      assert_equal 0, code, err
      infected = payload["results"].select { |result| result["reason"] == "not_infected" }
      assert_equal 1, infected.size
      assert_equal "a + b", infected.first["mutant"]["replacement"]
      assert_equal 0.0, infected.first["duration"]
      assert_equal({ "not_infected" => 1 }, payload["survived_reasons"])
    end
  end

  def test_no_weak_runs_the_mutant_and_records_not_detected
    in_project do
      File.write("lib/spinner.rb", "class Spinner\n  def sub(a, b)\n    a - b\n  end\nend\n")
      FileUtils.mkdir_p("test")
      write_test("assert_equal 5, Spinner.new.sub(5, 0)\n", basename: "spinner", klass: "SpinnerTest")

      code, out, err = start(["run", "lib", "--operators=aor", "--per-line=all",
                              "--no-weak", "--report=json"])
      payload = JSON.parse(out.lines.last)

      assert_equal 0, code, err
      assert_equal({ "not_detected" => 1 }, payload["survived_reasons"])
    end
  end

  def test_kill_matrix_adds_rows_and_keeps_the_exit_code
    in_project do
      File.write("lib/tally.rb", "class Tally\n  def self.sum(a, b)\n    a + b\n  end\nend\n")
      FileUtils.mkdir_p("test")
      File.write("test/tally_test.rb", <<~RUBY)
        require "minitest/autorun"
        require "tally"

        class TallyTest < Minitest::Test
          def test_a_sum
            assert_equal 5, Tally.sum(2, 3)
          end

          def test_b_again
            assert_equal 4, Tally.sum(2, 2)
          end
        end
      RUBY
      argv = ["run", "lib/tally.rb", "--operators=aor", "--report=json", "--min-score=100"]

      off_code, off_out, off_err = with_env("SABAKU_NO_CACHE" => "1") { start(argv) }
      on_code, on_out, on_err = with_env("SABAKU_NO_CACHE" => "1") { start(argv + ["--kill-matrix"]) }

      assert_equal 0, off_code, off_err
      assert_equal off_code, on_code, on_err
      off = JSON.parse(off_out.lines.last)
      on = JSON.parse(on_out.lines.last)
      assert_equal off["score"], on["score"]
      assert(off["results"].none? { |result| result.key?("kills") })
      killed = on["results"].select { |result| result["status"] == "killed" }
      refute_empty killed
      killed.each do |result|
        assert_includes result["kills"]["killers"], result["failed_test"]
      end
    end
  end

  def test_kill_matrix_scope_keeps_redundancy_inside_a_test_class
    in_project do
      File.write("lib/ledger.rb", "class Ledger\n  def self.sum(a, b)\n    a + b\n  end\nend\n")
      FileUtils.mkdir_p("test")
      File.write("test/ledger_test.rb", <<~RUBY)
        require "minitest/autorun"
        require "ledger"

        class LedgerTest < Minitest::Test
          def test_sum
            assert_equal 5, Ledger.sum(2, 3)
          end
        end

        class LedgerRequestTest < Minitest::Test
          def test_sum
            assert_equal 5, Ledger.sum(2, 3)
          end
        end
      RUBY
      argv = ["run", "lib/ledger.rb", "--operators=aor", "--report=json", "--kill-matrix"]

      verdicts = lambda do |*extra|
        code, out, err = with_env("SABAKU_NO_CACHE" => "1") { start(argv + extra) }
        assert_equal 0, code, err
        matrix = JSON.parse(out.lines.last)["kill_matrix"]
        [matrix["scope"], matrix["tests"].to_h { |test| [test["id"], test["verdict"]] }]
      end

      assert_equal ["class", { "LedgerRequestTest#test_sum" => "kept", "LedgerTest#test_sum" => "kept" }],
                   verdicts.call
      assert_equal ["suite", { "LedgerRequestTest#test_sum" => "kept", "LedgerTest#test_sum" => "duplicate" }],
                   verdicts.call("--kill-matrix-scope=suite")
    end
  end

  def test_help_lists_the_kill_matrix_flag
    code, out, = start(["help"])

    assert_equal 0, code
    assert_includes out, "--kill-matrix"
    assert_includes out, "--sweep-timeout"
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def write_test(assertion, basename: "counter", klass: "CounterTest")
    File.write("test/#{basename}_test.rb", <<~RUBY)
      require "minitest/autorun"
      require "#{basename}"

      class #{klass} < Minitest::Test
        def test_mul
          #{assertion.strip}
        end
      end
    RUBY
  end

  def total(list_output)
    list_output[/^(\d+) mutants$/, 1].to_i
  end

  def git(*args)
    system("git", *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  def reap_stragglers
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    loop do
      pid = begin
        Process.waitpid(-1, Process::WNOHANG)
      rescue Errno::ECHILD
        return
      end
      return if pid.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(0.01) if pid.nil?
    end
  end
end
