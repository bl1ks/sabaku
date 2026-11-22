# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class SetupTest < Minitest::Test
  def with_setup_file(body)
    Dir.mktmpdir("sabaku-setup") do |dir|
      path = File.join(dir, "sabaku.rb")
      File.write(path, body)
      yield path
    end
  end

  def test_setup_file_records_env_paths_and_hooks_in_order
    with_setup_file(<<~RUBY) do |path|
      env "APP_MODE" => "test"
      require_path "./config/environment"
      after_boot { $setup_order << :after_boot }
      child_start { |index| $setup_order << [:child_start, index] }
      after_campaign { $setup_order << :after_campaign }
    RUBY
      setup = Sabaku.setup(path)

      assert_equal({ "APP_MODE" => "test" }, setup.env_vars)
      assert_equal ["./config/environment"], setup.require_paths
      refute setup.empty?

      $setup_order = []
      setup.fire(:child_start, 2)
      setup.fire(:after_boot)
      setup.fire(:after_campaign)
      assert_equal [[:child_start, 2], :after_boot, :after_campaign], $setup_order
    end
  end

  def test_block_form_is_the_same_value
    setup = Sabaku.setup do
      env("LANG" => "C")
      before_fork { :noop }
    end

    assert_equal({ "LANG" => "C" }, setup.env_vars)
    assert_equal 1, setup.hooks[:before_fork].size
  end

  def test_a_hook_without_a_block_is_rejected
    assert_raises(ArgumentError) { Sabaku::Setup.new.after_boot }
  end

  def test_boot_applies_env_before_anything_loads
    config = Sabaku::Config.default(env: { "SABAKU_BOOT_TEST" => "on" })
    previous = ENV["SABAKU_BOOT_TEST"]

    Sabaku::Boot.env(config)
    assert_equal "on", ENV["SABAKU_BOOT_TEST"]
  ensure
    ENV["SABAKU_BOOT_TEST"] = previous
    ENV.delete("SABAKU_BOOT_TEST") if previous.nil?
  end

  # `--require` and the setup's require_path are one list, required in that order on
  # every surface that boots the project.
  def test_boot_requires_the_cli_requires_before_the_setup_paths
    Dir.mktmpdir("sabaku-requires") do |dir|
      cli = File.join(dir, "cli_required.rb")
      File.write(cli, "$sabaku_boot_order = [:cli]\n")
      path = File.join(dir, "setup_required.rb")
      File.write(path, "$sabaku_boot_order << :setup\n")
      setup = Sabaku.setup { require_path path }

      Sabaku::Boot.require_paths(Sabaku::Config.default(requires: [cli], setup: setup))

      assert_equal %i[cli setup], $sabaku_boot_order
    end
  end

  def test_a_setup_without_hooks_is_empty
    assert Sabaku::Setup.new.empty?
  end
end
