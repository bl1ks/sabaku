# frozen_string_literal: true

require_relative "../errors"

module Sabaku
  module Adapters
    # Runs a minitest project: loads its test files once, then runs exact test
    # ids in this process.
    #
    # Contract:
    #
    #   MinitestAdapter.new(test_globs: []) -> adapter; [] means MINITEST_GLOB
    #   adapter.preload!    -> loads the framework + project tests once
    #   adapter.test_ids    -> Array[String], stable native ids
    #   adapter.run(ids)    -> Outcome(ok:, failed_id:, error:)
    #   adapter.sweep(ids)  -> Sweep(failed_ids:)
    #
    # `preload!` followed by repeated `run(ids)` in forked children is the fast
    # path. `run` must never raise for an ordinary test failure and must never
    # call `exit`; it runs exactly the ids it is given, in the current process.
    #
    # Verified against the container's minitest 6.1.0, which differs from
    # minitest 5 in ways this file depends on:
    #
    #   * Minitest::Runnable.run_one_method no longer exists
    #   * Minitest::Runnable.run(klass, method, reporter) still exists, but a
    #     direct `klass.new(method).run` already returns a Minitest::Result and
    #     captures assertion failures on the instance (the Result object is a
    #     clean view of it), so no raising reporter plumbing is needed.
    #   * Minitest::Test#run takes no arguments (minitest 5 took a reporter).
    #   * Reporter classes are Minitest::AbstractReporter / CompositeReporter /
    #     SummaryReporter / ProgressReporter; Minitest::Test has no `reporter=`.
    #
    # `klass.new(method).run` is silent and returns the Result, so the subset
    # runner is just: run each instance, inspect `failures`.
    class MinitestAdapter
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

      Sweep = Data.define(:failed_ids) do
        def killed? = !failed_ids.empty?
      end

      Failure = Data.define(:error)
      private_constant :Failure

      MINITEST_GLOB = "test/**/*_test.rb"

      attr_reader :root, :test_globs

      def initialize(test_globs: [])
        # The project root is the current working directory; the adapter never
        # assumes the library checkout is the project.
        @root = Dir.pwd
        @test_globs = test_globs.empty? ? [MINITEST_GLOB] : test_globs.map(&:to_s)
        @preloaded = false
      end

      def preload!
        return self if @preloaded

        @root = Dir.pwd
        setup_load_path!
        require "minitest"
        ::Minitest.seed ||= 0

        @test_files = test_files
        if @test_files.empty?
          raise Sabaku::Error,
                "no minitest files matched #{@test_globs.join(", ")} under #{@root}"
        end

        @registry_before = ::Minitest::Runnable.runnables.dup
        load_without_autorun(@test_files)

        @classes = discover_test_classes(@test_files)
        @id_to_pair = {}
        @test_ids = []
        @classes.each do |klass|
          test_methods_for(klass).each do |method_name|
            id = "#{safe_class_name(klass)}##{method_name}"
            @test_ids << id
            @id_to_pair[id] = [klass, method_name]
          end
        end
        @test_ids.sort!
        @test_ids.uniq!

        # A preloaded minitest project must not leak its test classes into the
        # embedding process: minitest/autorun installs an at_exit hook which
        # would otherwise run the whole suite again (and again) at exit. The
        # adapter owns these classes now; `run` uses @id_to_pair.
        unregister_test_classes(@classes)

        @preloaded = true
        self
      end

      def test_ids
        ensure_preloaded!
        @test_ids.dup
      end

      def run(ids)
        ensure_preloaded!

        Array(ids).each do |raw_id|
          id = raw_id.to_s
          failure = run_one(id)
          return Outcome.new(ok: false, failed_id: id, error: failure.error) if failure
        end

        Outcome.new(ok: true, failed_id: nil, error: nil)
      end

      # Every id runs, whatever the earlier ones did. `run` and `sweep` share `run_one`, so the
      # two never disagree about which ids fail.
      def sweep(ids)
        ensure_preloaded!

        Sweep.new(failed_ids: Array(ids).map(&:to_s).select { |id| run_one(id) })
      end

      def preloaded?
        @preloaded
      end

      # The repo-relative file that defines the test method, or nil for an unknown id.
      def test_path(id)
        ensure_preloaded!
        klass, method_name = @id_to_pair[id.to_s]
        location = klass&.instance_method(method_name)&.source_location
        location && repo_relative(location.first)
      end

      # The files this adapter will load, discovered without loading anything. The
      # runner fingerprints them for the result cache, so a test that changed
      # invalidates the verdicts it produced.
      def test_files
        @test_files ||= discover_test_files
      end

      def inspect
        "#<#{self.class} root=#{root.inspect} ids=#{@test_ids&.size.inspect}>"
      end

      protected

      # `<project>/lib` and `<project>/test` are the load-path roots the fixtures
      # and real projects expect. Only existing directories are added, and only
      # once, so repeated preloads do not grow $LOAD_PATH.
      def setup_load_path!
        %w[lib test].each do |dir|
          path = File.join(root, dir)
          next unless File.directory?(path)
          next if $LOAD_PATH.include?(path)

          $LOAD_PATH.unshift(path)
        end
      end

      def discover_test_files
        @test_globs.flat_map { |pattern| Dir.glob(File.expand_path(pattern, root)) }
                   .select { |file| File.file?(file) }.uniq.sort
      end

      def repo_relative(path)
        absolute = File.expand_path(path)
        prefix = root.end_with?("/") ? root : "#{root}/"
        absolute.start_with?(prefix) ? absolute[prefix.length..] : absolute
      end

      private

      def ensure_preloaded!
        return if @preloaded

        raise Sabaku::Error, "minitest adapter used before #preload!"
      end

      # -> Failure, or nil. A Failure carries an Exception only for an unexpected error; an
      # assertion failure leaves the error nil.
      def run_one(id)
        pair = @id_to_pair[id]
        unless pair
          return Failure.new(error: Sabaku::Error.new("unknown minitest test id #{id.inspect}"))
        end

        klass, method_name = pair
        # A project may override `run` (Active Support's isolation module does,
        # to fork the test). Anything it returns that is not a Result must come
        # back as this test's failure, not as an exception that takes the child
        # down: the adapter contract is to never raise for a failing test.
        begin
          instance = klass.new(method_name)
          result = instance.run
          return nil if result.passed? || result.skipped? || instance.passed? || instance.skipped?

          failure = result.failures.first || instance.failures.first
          # An assertion failure is identified by failed_id; only an unexpected
          # exception carries an Exception worth reporting separately.
          Failure.new(error: failure.is_a?(::Minitest::UnexpectedError) ? failure.error : nil)
        rescue Exception => e # rubocop:disable Lint/RescueException
          Failure.new(error: e)
        end
      end

      # Load the project's test files while making `require "minitest/autorun"`
      # a no-op for the duration. In a fresh CLI process this keeps minitest's
      # global at_exit suite-runner from being installed at all. In our own test
      # process autorun is already installed, and unregistering the loaded
      # classes (below) keeps that existing at_exit from running the fixture.
      def load_without_autorun(files)
        # minitest 5.25 (Ruby 3.4's bundled version) has no `installed_at_exit?`, so the
        # guard is feature-detected rather than version-sniffed. Without it, preloading a
        # project under 5.x crashed before a single mutant ran.
        suppress = !::Minitest.installed_at_exit? if ::Minitest.respond_to?(:installed_at_exit?)
        singleton = ::Minitest.singleton_class
        if suppress
          singleton.send(:alias_method, :__mutation_saved_autorun, :autorun)
          singleton.send(:define_method, :autorun) { nil }
        end

        files.each do |file|
          load file
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise e if e.is_a?(Interrupt)

          raise Sabaku::Error,
                "failed to load #{repo_relative(file)}: #{e.class}: #{e.message}"
        end
      ensure
        if suppress
          singleton.send(:alias_method, :autorun, :__mutation_saved_autorun)
          singleton.send(:remove_method, :__mutation_saved_autorun)
        end
      end

      def test_methods_for(klass)
        klass.runnable_methods.map(&:to_s).sort.uniq
      rescue StandardError, NotImplementedError
        klass.methods_matching(/^test_/).map(&:to_s).sort.uniq
      end

      # Find every test class whose test methods live in the files we just
      # loaded. The ObjectSpace pass makes a second preload of an
      # already-defined test file work even though re-opening a class does not
      # fire Minitest::Runnable.inherited again.
      def discover_test_classes(test_files)
        file_set = test_files.map { |file| File.expand_path(file) }
        candidates = ::Minitest::Runnable.runnables - @registry_before

        ::ObjectSpace.each_object(Class) do |klass|
          next unless klass < ::Minitest::Test
          next if safe_class_name(klass).nil?

          methods = test_methods_for(klass)
          next if methods.empty?
          next unless methods.any? { |method| defined_in?(klass, method, file_set) }

          candidates << klass
        end

        # Minitest::Spec only exists once minitest/spec is loaded; a Rails
        # test_helper requires minitest but not minitest/spec, so naming the
        # constant unconditionally raises NameError during preload.
        spec = defined?(::Minitest::Spec) ? ::Minitest::Spec : nil

        candidates
          .select { |klass| klass.is_a?(Class) && klass < ::Minitest::Test }
          .reject { |klass| klass == ::Minitest::Test || klass == spec }
          .reject { |klass| safe_class_name(klass).nil? || test_methods_for(klass).empty? }
          .uniq
          .sort_by { |klass| safe_class_name(klass).to_s }
      end

      # Module#name, not Class#name: generators like Faker::Travel::Airport.name raise.
      def safe_class_name(klass)
        Module.instance_method(:name).bind_call(klass)
      end

      def defined_in?(klass, method_name, file_set)
        location = klass.instance_method(method_name).source_location
        return false unless location

        file_set.include?(File.expand_path(location.first))
      rescue NameError
        false
      end

      def unregister_test_classes(classes)
        registry = ::Minitest::Runnable.runnables
        registry.delete_if { |klass| classes.include?(klass) }
      end
    end
  end
end

# The CLI reaches the optional coverage helper through
# `defined?(Adapters::CoverageSampler)` behind a guard, so loading it here makes
# the helper part of the adapter namespace whenever the adapter layer is loaded.
require_relative "coverage_sampler"
