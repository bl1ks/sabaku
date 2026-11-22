# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"
require "yaml"

class PacksTest < Minitest::Test
  include FixtureHelper

  def graph = Sabaku::Packs.load(fixture_path("packs_app"))

  def test_a_pack_is_tested_by_its_own_tests_and_every_pack_that_depends_on_it
    assert_equal ["packs/billing/test/**/*_test.rb", "packs/ledger/test/**/*_test.rb", "test/**/*_test.rb"],
                 graph.test_globs_for(["packs/ledger/lib/ledger.rb"])
  end

  def test_a_pack_nothing_depends_on_brings_only_its_own_tests_and_the_root
    assert_equal ["packs/billing/test/**/*_test.rb", "test/**/*_test.rb"],
                 graph.test_globs_for(["packs/billing/lib/invoice.rb"])
  end

  def test_dependents_are_transitive
    Dir.mktmpdir("sabaku-packs") do |dir|
      pack(dir, ".", %w[packs/c])
      pack(dir, "packs/a", [])
      pack(dir, "packs/b", %w[packs/a])
      pack(dir, "packs/c", %w[packs/b])

      assert_equal %w[. packs/b packs/c], Sabaku::Packs.load(dir).dependents(["packs/a"]).map(&:name).sort
    end
  end

  def test_the_deepest_pack_owns_a_path
    Dir.mktmpdir("sabaku-packs") do |dir|
      pack(dir, ".", [])
      pack(dir, "packs/a", [])
      pack(dir, "packs/a/nested", [])
      packs = Sabaku::Packs.load(dir)

      assert_equal "packs/a/nested", packs.pack_of("packs/a/nested/lib/x.rb").name
      assert_equal "packs/a", packs.pack_of("packs/a/lib/x.rb").name
      assert_equal ".", packs.pack_of("app/models/x.rb").name
      assert_equal ".", packs.pack_of("packs/ab/lib/x.rb").name
    end
  end

  def test_vendored_packages_are_not_packs
    Dir.mktmpdir("sabaku-packs") do |dir|
      pack(dir, ".", [])
      pack(dir, "vendor/bundle/gems/some_gem", [])

      assert_equal ["."], Sabaku::Packs.load(dir).packs.map(&:name)
    end
  end

  def test_a_project_without_package_yml_is_an_error
    Dir.mktmpdir("sabaku-packs") do |dir|
      assert_raises(Sabaku::Error) { Sabaku::Packs.load(dir) }
    end
  end

  private

  def pack(dir, name, dependencies)
    path = File.join(dir, name, "package.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, dependencies.empty? ? "enforce_dependencies: true\n" : { "dependencies" => dependencies }.to_yaml)
  end
end
