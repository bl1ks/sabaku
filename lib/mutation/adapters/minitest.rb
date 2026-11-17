# frozen_string_literal: true

require_relative "base"

module Mutation
  module Adapters
    # Minitest 6.1 adapter.
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
    class MinitestAdapter < Adapter
      def name
        :minitest
      end

      def preload!
        return self if @preloaded

        @root = Dir.pwd
        setup_load_path!
        require "minitest"
        ::Minitest.seed ||= 0

        @test_files = discover_test_files(MINITEST_GLOB)
        if @test_files.empty?
          raise Mutation::Error,
                "no minitest files matched #{MINITEST_GLOB.inspect} under #{@root}"
        end

        @registry_before = ::Minitest::Runnable.runnables.dup
        load_without_autorun(@test_files)

        @classes = discover_test_classes(@test_files)
        @id_to_pair = {}
        @test_ids = @classes.flat_map { |klass| test_methods_for(klass).map { |m| "#{klass.name}##{m}" } }
        @test_ids.sort!
        @test_ids.uniq!
        @test_ids.each do |id|
          class_name, _, method_name = id.partition("#")
          klass = @classes.find { |candidate| candidate.name == class_name }
          @id_to_pair[id] = [klass, method_name] if klass
        end

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
          pair = @id_to_pair[id]
          unless pair
            return Outcome.new(
              ok: false,
              failed_id: id,
              error: Mutation::Error.new("unknown minitest test id #{id.inspect}")
            )
          end

          klass, method_name = pair
          begin
            instance = klass.new(method_name)
            result = instance.run
          rescue Exception => e # rubocop:disable Lint/RescueException
            return Outcome.new(ok: false, failed_id: id, error: e)
          end

          next if result.passed? || result.skipped? || instance.passed? || instance.skipped?

          failure = result.failures.first || instance.failures.first
          # An assertion failure is identified by failed_id; only an unexpected
          # exception carries an Exception worth reporting separately.
          error = failure.is_a?(::Minitest::UnexpectedError) ? failure.error : nil
          return Outcome.new(ok: false, failed_id: id, error: error)
        end

        Outcome.new(ok: true, failed_id: nil, error: nil)
      end

      private

      def ensure_preloaded!
        return if @preloaded

        raise Mutation::Error, "minitest adapter used before #preload!"
      end

      # Load the project's test files while making `require "minitest/autorun"`
      # a no-op for the duration. In a fresh CLI process this keeps minitest's
      # global at_exit suite-runner from being installed at all. In our own test
      # process autorun is already installed, and unregistering the loaded
      # classes (below) keeps that existing at_exit from running the fixture.
      def load_without_autorun(files)
        suppress = !::Minitest.installed_at_exit?
        singleton = ::Minitest.singleton_class
        if suppress
          singleton.send(:alias_method, :__mutation_saved_autorun, :autorun)
          singleton.send(:define_method, :autorun) { nil }
        end

        files.each do |file|
          load file
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise e if e.is_a?(Interrupt)

          raise Mutation::Error,
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
          next if klass.name.nil?
          next unless klass < ::Minitest::Test

          methods = test_methods_for(klass)
          next if methods.empty?
          next unless methods.any? { |method| defined_in?(klass, method, file_set) }

          candidates << klass
        end

        candidates
          .select { |klass| klass.is_a?(Class) && klass < ::Minitest::Test }
          .reject { |klass| klass == ::Minitest::Test || klass == ::Minitest::Spec }
          .reject { |klass| klass.name.nil? || test_methods_for(klass).empty? }
          .uniq
          .sort_by(&:name)
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
