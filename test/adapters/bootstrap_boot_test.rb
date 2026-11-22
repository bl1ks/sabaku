# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"
require "json"
require "rbconfig"
require "tmpdir"

# A first-load child boots the project the way the fork parent does: the setup's
# require paths, the preload, after_boot, and only then a target nothing required.
class BootstrapBootTest < Minitest::Test
  include AdapterTestHelpers

  def test_a_target_nothing_required_is_applied_after_the_whole_boot
    root = fixture_dir("after_boot_minitest")
    Dir.mktmpdir("sabaku-boot-order") do |dir|
      mutated = File.join(dir, "mutant.rb")
      File.write(mutated, File.read(File.join(root, "lib/booted.rb")).sub("    1", "    2"))
      reader, writer = IO.pipe
      env = {
        "SABAKU_ROOT" => root,
        "SABAKU_TEST_IDS" => JSON.generate(["BootedTest#test_value"]),
        "SABAKU_MUTANT_PATH" => "lib/booted.rb",
        "SABAKU_MUTATED_FILE" => mutated,
        "SABAKU_PAYLOAD_FD" => "3",
        "SABAKU_SETUP" => File.join(root, "sabaku.rb"),
        "SABAKU_TEST_GLOBS" => JSON.generate(["test/*_case.rb"])
      }
      pid = Process.spawn(env, RbConfig.ruby, "-I", Sabaku::Runner::SABAKU_LIB,
                          Sabaku::Runner::BOOTSTRAP, 3 => writer, chdir: root)
      writer.close
      payload = JSON.parse(reader.gets)
      _, status = Process.waitpid2(pid)

      refute payload["boot_error"], payload["error"]
      assert_equal "BootedTest#test_value", payload["failed_id"]
      assert_equal 1, status.exitstatus
    ensure
      reader&.close
    end
  end
end
