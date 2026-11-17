# frozen_string_literal: true

require_relative "../errors"

module Mutation
  # A test-framework adapter is the only part of the library that knows how to
  # enumerate and run one project's tests.
  #
  # Contract (docs/DESIGN.md):
  #
  #   Adapter.for(:minitest, config) -> adapter
  #   adapter.name                   -> Symbol
  #   adapter.preload!               -> loads the framework + project tests once
  #   adapter.test_ids               -> Array[String], stable native ids
  #   adapter.run(ids)               -> Outcome(ok:, failed_id:, error:)
  #
  # `preload!` followed by repeated `run(ids)` in forked children is the fast
  # path. `run` must never raise for an ordinary test failure and must never
  # call `exit`; it runs exactly the ids it is given, in the current process.
  class Adapter
    Outcome = Data.define(:ok, :failed_id, :error) do
      def initialize(ok:, failed_id: nil, error: nil)
        super(ok: ok ? true : false, failed_id: failed_id, error: error)
      end

      def ok?
        ok
      end

      def failed?
        !ok
      end
    end

    # The test glob may be overridden per project; the defaults match the two
    # frameworks' conventional layouts.
    MINITEST_GLOB = "test/**/*_test.rb"
    RSPEC_GLOB = "spec/**/*_spec.rb"

    attr_reader :config, :root

    def self.for(name, config = nil)
      case name.to_sym
      when :minitest
        require_relative "minitest"
        Adapters::MinitestAdapter.new(config)
      when :rspec
        require_relative "rspec"
        Adapters::RSpecAdapter.new(config)
      else
        raise Mutation::Error,
              "unknown adapter #{name.inspect} (expected :minitest or :rspec)"
      end
    end

    def initialize(config = nil)
      @config = config
      # The project root is the current working directory; adapters never assume
      # the library checkout is the project.
      @root = Dir.pwd
      @preloaded = false
    end

    def name
      raise NotImplementedError, "#{self.class} must implement #name"
    end

    def preload!
      raise NotImplementedError, "#{self.class} must implement #preload!"
    end

    def test_ids
      raise NotImplementedError, "#{self.class} must implement #test_ids"
    end

    def run(_ids)
      raise NotImplementedError, "#{self.class} must implement #run(ids)"
    end

    def preloaded?
      @preloaded
    end

    def inspect
      "#<#{self.class} name=#{name.inspect} root=#{root.inspect} ids=#{@test_ids&.size.inspect}>"
    end

    protected

    # `<project>/lib`, `<project>/test`, `<project>/spec` are the load-path roots
    # the fixtures and real projects expect. Only existing directories are added,
    # and only once, so repeated preloads do not grow $LOAD_PATH.
    def setup_load_path!
      %w[lib test spec].each do |dir|
        path = File.join(root, dir)
        next unless File.directory?(path)
        next if $LOAD_PATH.include?(path)

        $LOAD_PATH.unshift(path)
      end
    end

    # ENV["RUBY_MUTATION_TEST_GLOB"] overrides the framework default.
    def discover_test_files(default_glob)
      pattern = ENV["RUBY_MUTATION_TEST_GLOB"]
      pattern = default_glob if pattern.nil? || pattern.empty?
      Dir.glob(File.expand_path(pattern, root)).select { |file| File.file?(file) }.sort
    end

    def repo_relative(path)
      absolute = File.expand_path(path)
      prefix = root.end_with?("/") ? root : "#{root}/"
      absolute.start_with?(prefix) ? absolute[prefix.length..] : absolute
    end
  end
end

# lib/mutation.rb (frozen) does not list the optional coverage helper, but the
# CLI reaches it through Adapters::CoverageSampler behind a `defined?` guard.
# Loading it here makes the helper part of the adapter namespace whenever the
# adapter layer is loaded.
require_relative "coverage_sampler"
