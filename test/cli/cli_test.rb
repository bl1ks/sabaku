# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "stringio"

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
end
