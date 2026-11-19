# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require "timeout"

# The boot contract end to end: --env, --require, and the setup hooks run in the
# order a Rails application needs, against the real binary and a real
# forked campaign.
class BootCampaignTest < Minitest::Test
  BIN = File.expand_path("../../bin/mutation", __dir__)

  def test_hooks_and_requires_run_in_the_documented_order
    Dir.mktmpdir("ruby-mutation-boot") do |dir|
      write_project(dir)
      out, err, status = run_cli(dir, "run", "lib", "--jobs=1", "--report=json",
                                 "--setup=mutation.rb", "--env=MUTATION_PROBE=on")
      payload = JSON.parse(out.lines.last)

      assert_equal 0, status.exitstatus, err
      assert_operator payload["mutants"], :>, 0

      lines = File.readlines(File.join(dir, "boot.log"), chomp: true)
      assert_equal "required:on", lines.first, "the required file must see --env"

      hooks = lines.drop(1)
      after_campaign = hooks.pop
      assert_equal %w[after_boot before_fork], hooks.first(2)
      children = hooks.drop(2)
      refute_empty children
      children.each_slice(2) do |child_start, test_run|
        assert_match(/\Achild_start:\d+\z/, child_start.to_s)
        assert_equal "before_test_run", test_run
      end
      assert_equal "after_campaign", after_campaign
    end
  end

  def test_a_raising_after_campaign_hook_is_reported_without_changing_the_verdict
    Dir.mktmpdir("ruby-mutation-boot") do |dir|
      write_project(dir)
      File.write(File.join(dir, "mutation.rb"), <<~RUBY)
        after_campaign { raise "cleanup exploded" }
      RUBY

      out, err, status = run_cli(dir, "run", "lib", "--jobs=1", "--report=json",
                                 "--setup=mutation.rb", "--env=MUTATION_PROBE=on")

      assert_equal 0, status.exitstatus, err
      assert_includes err, "mutation: after_campaign hook failed: RuntimeError: cleanup exploded"
      assert_operator JSON.parse(out.lines.last)["mutants"], :>, 0
    end
  end

  def test_a_setup_file_can_abort_the_campaign_loudly
    Dir.mktmpdir("ruby-mutation-boot") do |dir|
      write_project(dir)
      File.write(File.join(dir, "mutation.rb"), <<~RUBY)
        after_boot { raise "no database for you" }
      RUBY

      _out, err, status = run_cli(dir, "run", "lib", "--setup=mutation.rb")

      assert_equal 2, status.exitstatus
      assert_includes err, "no database for you"
    end
  end

  private

  def run_cli(dir, *args)
    out, err, status = nil
    Timeout.timeout(120) do
      out, err, status = Open3.capture3(RbConfig.ruby, BIN, *args, chdir: dir)
    end
    [out, err, status]
  end

  def write_project(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    FileUtils.mkdir_p(File.join(dir, "test"))
    File.write(File.join(dir, "lib", "subject.rb"), <<~RUBY)
      class Subject
        def add(a, b)
          a + b
        end
      end
    RUBY
    File.write(File.join(dir, "test", "subject_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require "subject"

      class SubjectTest < Minitest::Test
        def test_add
          assert_equal 5, Subject.new.add(2, 3)
        end
      end
    RUBY
    log = File.join(dir, "boot.log")
    File.write(File.join(dir, "boot.rb"), <<~RUBY)
      File.open(#{log.inspect}, "a") { |file| file.puts("required:\#{ENV["MUTATION_PROBE"]}") }
    RUBY
    File.write(File.join(dir, "mutation.rb"), <<~RUBY)
      require_path "./boot.rb"
      after_boot { record(#{log.inspect}, "after_boot") }
      before_fork { record(#{log.inspect}, "before_fork") }
      child_start { |index| record(#{log.inspect}, "child_start:\#{index}") }
      before_test_run { record(#{log.inspect}, "before_test_run") }
      after_campaign { record(#{log.inspect}, "after_campaign") }
      MUTATION_BOOT_LOG = #{log.inspect}
      # A bare method so the hook blocks stay one line each.
      def record(path, line)
        File.open(path, "a") { |file| file.puts(line) }
      end
    RUBY
  end
end
