# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class FingerprintTest < Minitest::Test
  AdapterDouble = Struct.new(:root, :test_files)

  def setup
    @dir = Dir.mktmpdir("sabaku-fingerprint")
    FileUtils.mkdir_p(File.join(@dir, "test"))
    @test = File.join(@dir, "test", "a_test.rb")
    @helper = File.join(@dir, "test", "test_helper.rb")
    File.write(@test, "class AT; end\n")
    File.write(@helper, "# helper\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def adapter(*files)
    AdapterDouble.new(@dir, files.empty? ? [@test] : files)
  end

  def digest(config = Sabaku::Config.default, files = [])
    Sabaku::Fingerprint.for(config, adapter(*files)).digest
  end

  def test_the_same_campaign_hashes_the_same
    assert_equal digest, digest
  end

  def test_changing_a_test_body_changes_the_digest
    before = digest
    File.write(@test, "class AT\n  def test_one\n    assert true\n  end\nend\n")

    refute_equal before, digest, "a test gained an assertion but the key did not move"
  end

  def test_changing_a_test_helper_changes_the_digest
    before = digest
    File.write(@helper, "# helper with a new global side effect\n")

    refute_equal before, digest
  end

  def test_isolation_and_timeout_are_part_of_the_digest
    fork = digest(Sabaku::Config.default(isolation: :fork, timeout: 5.0))
    process = digest(Sabaku::Config.default(isolation: :process, timeout: 5.0))
    impatient = digest(Sabaku::Config.default(isolation: :fork, timeout: 0.5))

    refute_equal fork, process
    refute_equal fork, impatient
  end

  def test_env_and_requires_are_part_of_the_digest
    base = digest(Sabaku::Config.default(env: { "A" => "1" }, requires: ["one"]))
    other_env = digest(Sabaku::Config.default(env: { "A" => "2" }, requires: ["one"]))
    other_require = digest(Sabaku::Config.default(env: { "A" => "1" }, requires: ["two"]))

    refute_equal base, other_env
    refute_equal base, other_require
  end

  def test_env_order_does_not_change_the_digest
    one = digest(Sabaku::Config.default(env: { "A" => "1", "B" => "2" }))
    two = digest(Sabaku::Config.default(env: { "B" => "2", "A" => "1" }))

    assert_equal one, two
  end

  def test_the_setup_file_is_part_of_the_digest
    path = File.join(@dir, "sabaku.rb")
    File.write(path, "require_path './config/environment'\n")
    before = digest(Sabaku::Config.default(setup_path: path, setup: Sabaku.setup(path)))

    File.write(path, "after_boot { Rails.application.eager_load! }\n")
    after = digest(Sabaku::Config.default(setup_path: path, setup: Sabaku.setup(path)))

    refute_equal before, after
  end

  def test_a_setup_block_is_part_of_the_digest
    hook = -> { :noop }
    with_hook = Sabaku.setup { after_boot(&hook) }
    without = Sabaku.setup { env "RAILS_ENV" => "test" }

    assert_equal digest(Sabaku::Config.default(setup: with_hook)),
                 digest(Sabaku::Config.default(setup: with_hook))
    refute_equal digest(Sabaku::Config.default(setup: with_hook)),
                 digest(Sabaku::Config.default(setup: without))
  end
end
