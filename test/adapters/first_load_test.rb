# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require_relative "../test_helper"
require "sabaku/runtime/first_load"

# The loader that applies a mutation at the target's first load. These tests run
# in the suite's own process, so each one resets the current loader and the
# load path it touched.
class FirstLoadTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("sabaku-first-load")
    @lib = File.join(@dir, "lib")
    FileUtils.mkdir_p(@lib)
    @path = File.join(@lib, "first_load_probe.rb")
    File.write(@path, <<~RUBY)
      module FirstLoadProbe
        def self.value
          1
        end
      end
    RUBY
    @before_features = $LOADED_FEATURES.dup
    @before_path = $LOAD_PATH.dup
    $LOAD_PATH.unshift(@lib)
  end

  def teardown
    Sabaku::Runtime::FirstLoad.current = nil
    $LOADED_FEATURES.replace(@before_features)
    $LOAD_PATH.replace(@before_path)
    FileUtils.remove_entry(@dir) if File.exist?(@dir)
  end

  def loader(source = nil)
    source ||= File.read(@path).sub("1", "2")
    Sabaku::Runtime::FirstLoad.new(target: @path, source: source, root: @dir,
                                     shim_dir: @dir).install
  end

  def test_a_require_loads_the_mutated_source_once
    instance = loader

    assert require("first_load_probe")
    assert instance.applied?
    assert_equal 2, FirstLoadProbe.value
    assert_includes $LOADED_FEATURES, @path
  end

  # Zeitwerk and Bootsnap call the module function, which a prepend to Kernel misses.
  def test_kernel_dot_require_loads_the_mutated_source
    instance = loader

    assert Kernel.require("first_load_probe")
    assert instance.applied?
    assert_equal 2, FirstLoadProbe.value
  end

  def test_an_autoload_is_redirected_to_the_shim
    instance = loader
    holder = Module.new
    holder.autoload(:FirstLoadProbe, "first_load_probe")

    assert_equal 2, holder.const_get(:FirstLoadProbe).value
    assert instance.applied?
    refute_empty instance.redirected_autoloads
    assert_equal [:FirstLoadProbe], instance.redirected_autoloads.map(&:last)
  end

  def test_a_require_of_another_file_is_not_intercepted
    instance = loader
    File.write(File.join(@lib, "other_probe.rb"), "OTHER_PROBE = 1\n")

    assert require("other_probe")
    refute instance.applied?
    refute_includes $LOADED_FEATURES, @path
  end

  def test_a_file_loaded_before_install_is_named
    require "first_load_probe"
    instance = loader

    refute instance.applied?
    assert instance.loaded_without_apply?
  end

  def test_a_file_the_project_never_loads_is_applied_explicitly
    instance = loader

    refute instance.applied?
    refute instance.loaded_without_apply?
    assert instance.apply
    assert_equal 2, FirstLoadProbe.value
  end
end
