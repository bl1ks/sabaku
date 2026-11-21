# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/adapter_test_helpers"
require "json"
require "rbconfig"
require "tmpdir"

class BootstrapSweepTest < Minitest::Test
  include AdapterTestHelpers

  def spawn_bootstrap(ids, sweep:)
    root = fixture_dir("matrix_minitest")
    Dir.mktmpdir("sabaku-sweep") do |dir|
      mutated = File.join(dir, "mutant.rb")
      File.write(mutated, File.read(File.join(root, "lib/matrix_calc.rb")).sub("a + b", "a * b"))
      reader, writer = IO.pipe
      env = {
        "SABAKU_ROOT" => root,
        "SABAKU_TEST_IDS" => JSON.generate(ids),
        "SABAKU_MUTANT_PATH" => "lib/matrix_calc.rb",
        "SABAKU_MUTATED_FILE" => mutated,
        "SABAKU_PAYLOAD_FD" => "3",
        "SABAKU_TEST_GLOB" => "test/*_case.rb",
        "SABAKU_SWEEP" => sweep ? "1" : "0"
      }
      pid = Process.spawn(env, RbConfig.ruby, "-I", Sabaku::Runner::SABAKU_LIB,
                          Sabaku::Runner::BOOTSTRAP, 3 => writer, chdir: root)
      writer.close
      payload = JSON.parse(reader.gets)
      _, status = Process.waitpid2(pid)
      [payload, status.exitstatus]
    ensure
      reader&.close
    end
  end

  def test_a_sweep_child_reports_every_failing_id_and_exits_zero
    ids = %w[MatrixTest#test_add_strong MatrixTest#test_sub_only MatrixTest#test_add_weak]

    payload, exit_status = spawn_bootstrap(ids, sweep: true)

    assert_equal 0, exit_status
    assert payload["swept"]
    assert_equal %w[MatrixTest#test_add_strong MatrixTest#test_add_weak], payload["failed_ids"]
  end

  def test_without_the_switch_the_child_stops_at_the_first_failure
    payload, exit_status = spawn_bootstrap(%w[MatrixTest#test_add_strong MatrixTest#test_add_weak],
                                           sweep: false)

    assert_equal 1, exit_status
    assert_equal "MatrixTest#test_add_strong", payload["failed_id"]
    refute payload.key?("swept")
  end
end
