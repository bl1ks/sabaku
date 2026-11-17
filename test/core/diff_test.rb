# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

class DiffTest < Minitest::Test
  def test_parses_new_side_hunk_ranges
    text = <<~DIFF
      diff --git a/lib/a.rb b/lib/a.rb
      index 111..222 100644
      --- a/lib/a.rb
      +++ b/lib/a.rb
      @@ -3 +3,2 @@
      -x
      +y
      +z
      @@ -10,2 +11,0 @@
      -gone
    DIFF

    assert_equal({ "lib/a.rb" => [3..4] }, Mutation::Diff.parse(text))
  end

  def test_deletion_only_hunks_change_nothing_in_the_new_file
    text = <<~DIFF
      --- a/lib/a.rb
      +++ b/lib/a.rb
      @@ -4,3 +4,0 @@
      -a
      -b
      -c
    DIFF

    assert_equal({}, Mutation::Diff.parse(text))
  end

  def test_quoted_paths_are_unquoted
    text = "--- \"a/lib/a.rb\"\n+++ \"b/lib/a b.rb\"\n@@ -1 +1 @@\n"
    assert_equal({ "lib/a b.rb" => [1..1] }, Mutation::Diff.parse(text))
  end

  def test_intersection_keeps_only_lines_both_filters_cover
    left = { "lib/a.rb" => [1..5, 9..10] }
    right = { "lib/a.rb" => [3..9], "lib/b.rb" => [1..2] }

    assert_equal({ "lib/a.rb" => [3..5, 9..9] }, Mutation::Diff.intersect(left, right))
    assert_equal right, Mutation::Diff.intersect(nil, right)
    assert_equal left, Mutation::Diff.intersect(left, nil)
  end

  def test_git_ranges_reads_the_working_tree_against_a_revision
    skip "git is not installed" unless system("git", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir("ruby-mutation-diff") do |dir|
      Dir.chdir(dir) do
        run_git("init", "-q")
        run_git("config", "user.email", "test@example.com")
        run_git("config", "user.name", "Test")
        FileUtils.mkdir_p("lib")
        File.write("lib/a.rb", "def a\n  1 + 1\nend\n")
        run_git("add", "-A")
        # `git commit` runs auto-maintenance as a detached child; it exits after
        # the commit, and an unrelated test that checks for orphans would see
        # it. Turning maintenance off for this test keeps the process table clean.
        run_git("-c", "maintenance.auto=false", "-c", "gc.auto=0", "commit", "-qm", "one")

        assert_equal({}, Mutation::Diff.git_ranges("HEAD"))

        File.write("lib/a.rb", "def a\n  1 + 2\nend\n")
        assert_equal({ "lib/a.rb" => [2..2] }, Mutation::Diff.git_ranges("HEAD"))
      end
    end
  ensure
    reap_stragglers
  end

  # Belt and braces: any child a git subcommand detached is reaped here, so
  # this test leaves the process table exactly as it found it.
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

  def run_git(*args)
    system("git", *args, out: File::NULL, err: File::NULL) ||
      raise("git #{args.join(' ')} failed")
  end
end
