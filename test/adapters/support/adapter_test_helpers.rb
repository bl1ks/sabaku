# frozen_string_literal: true

# Shared helpers for the adapter/runner tests. Every test file still requires
# test_helper (which loads the library); this file only adds fixture plumbing.
module AdapterTestHelpers
  TEST_FIXTURES = File.expand_path("../fixtures", __dir__)
  REPO_ROOT = File.expand_path("../../..", __dir__)

  # Projects used by the library's own fixtures live at <repo>/fixture; the
  # tiny projects this slice owns live at test/adapters/fixtures.
  def fixture_dir(name)
    local = File.join(TEST_FIXTURES, name)
    return local if File.directory?(local)

    File.join(REPO_ROOT, "fixture", name)
  end

  # Adapting to the seam: the project root is Dir.pwd, so tests chdir into the
  # fixture and restore the original directory no matter what. Inline fixtures
  # deliberately name their test files `*_case.rb` so the suite's own
  # `test/adapters/**/*_test.rb` glob never tries to require them; the adapter
  # is pointed at them with the custom-glob env var.
  def in_project(name, glob: nil)
    directory = fixture_dir(name)
    previous = Dir.pwd
    previous_glob = ENV["RUBY_MUTATION_TEST_GLOB"]
    ENV["RUBY_MUTATION_TEST_GLOB"] = glob if glob
    Dir.chdir(directory)
    yield directory
  ensure
    ENV["RUBY_MUTATION_TEST_GLOB"] = previous_glob if defined?(previous_glob) && previous_glob
    ENV.delete("RUBY_MUTATION_TEST_GLOB") if defined?(previous_glob) && previous_glob.nil?
    Dir.chdir(previous) if defined?(previous) && previous
  end

  def config_for(overrides = {})
    defaults = {
      paths: ["lib"],
      adapter: :minitest,
      jobs: 1,
      timeout: 5.0,
      coverage: true,
      report: :quiet
    }
    Mutation::Config.default(**defaults.merge(overrides))
  end

  # Mutants are Data objects with byte offsets; find the (unique) original text
  # in the fixture file and hand those offsets to Mutant.new.
  def build_mutant(root:, path: "lib/calc.rb", line:, original:, replacement:,
                   operator: :aor, node_kind: "CallNode")
    text = File.binread(File.join(root, path))
    offset = text.index(original.b)
    raise ArgumentError, "#{original.inspect} not found in #{path}" if offset.nil?

    Mutation::Mutant.new(
      path: path,
      operator: operator,
      line: line,
      column: 0,
      node_kind: node_kind,
      original: original,
      replacement: replacement,
      start_offset: offset,
      end_offset: offset + original.bytesize
    )
  end
end
