# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "stringio"
require "json"

class CLITest < Minitest::Test
  def in_project
    Dir.mktmpdir("ruby-mutation-cli") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "subject.rb"), "def add(a, b)\n  a + b\nend\n")
      Dir.chdir(dir) { yield }
    end
  end

  def start(argv)
    out = StringIO.new
    err = StringIO.new
    code = Mutation::CLI.start(argv, out: out, err: err)
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

  def test_since_restricts_the_mutants_to_the_lines_a_revision_changed
    Dir.mktmpdir("ruby-mutation-cli-git") do |dir|
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

  private

  def write_test(assertion)
    File.write("test/counter_test.rb", <<~RUBY)
      require "minitest/autorun"
      require "counter"

      class CounterTest < Minitest::Test
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
