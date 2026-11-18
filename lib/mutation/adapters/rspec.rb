# frozen_string_literal: true

require "stringio"

require_relative "base"

module Mutation
  module Adapters
    # RSpec 3.13 adapter.
    #
    # Verified against the container's rspec 3.13.2 / rspec-core 3.13.7:
    #
    #   * Runner#setup(err, out) configures RSpec and loads spec files without
    #     running them; it takes exactly two arguments.
    #   * Example ids are the native "./spec/x_spec.rb[1:2]" form.
    #   * An individual example is run in-process with
    #       example.run(example.example_group.new, reporter)
    #     where reporter is a fresh RSpec::Core::Reporter. Expectation failures
    #     are captured in example.execution_result, never raised.
    #   * Configuration#reporter= does not exist; pass the reporter to
    #     Example#run directly.
    #
    # Loading the spec files through Runner#setup (instead of a bare `load`) is
    # what keeps a second preload from doubling every example.
    class RSpecAdapter < Adapter
      def name
        :rspec
      end

      def test_glob
        RSPEC_GLOB
      end

      def preload!
        return self if @preloaded

        @root = Dir.pwd
        setup_load_path!
        require "rspec"

        @test_files = test_files
        if @test_files.empty?
          raise Mutation::Error,
                "no rspec files matched #{RSPEC_GLOB.inspect} under #{@root}"
        end

        # Drop examples from any previous preload in this process while keeping
        # the project's RSpec configuration (spec_helper may already have added
        # it), so a second adapter instance sees exactly one copy of each spec.
        ::RSpec.clear_examples if ::RSpec.respond_to?(:clear_examples)
        reset_relative_path_cache!

        options = ::RSpec::Core::ConfigurationOptions.new(@test_files)
        runner = ::RSpec::Core::Runner.new(options, ::RSpec.configuration, ::RSpec.world)
        # setup loads the files; a StringIO pair keeps filter announcements and
        # deprecations out of the campaign's terminal.
        runner.setup(StringIO.new, StringIO.new)

        @examples_by_id = collect_examples
        @test_ids = @examples_by_id.keys.sort
        @preloaded = true
        self
      end

      def test_ids
        ensure_preloaded!
        @test_ids.dup
      end

      def run(ids)
        ensure_preloaded!

        reporter = ::RSpec::Core::Reporter.new(::RSpec.configuration)
        ::RSpec.world.wants_to_quit = false

        Array(ids).each do |raw_id|
          id = raw_id.to_s
          example = @examples_by_id[id]
          unless example
            return Outcome.new(
              ok: false,
              failed_id: id,
              error: Mutation::Error.new("unknown rspec example id #{id.inspect}")
            )
          end

          reset_example_state(example)
          begin
            example.run(example.example_group.new, reporter)
          rescue Exception => e # rubocop:disable Lint/RescueException
            return Outcome.new(ok: false, failed_id: example.id, error: e)
          end

          result = example.execution_result
          if result.status == :failed
            return Outcome.new(ok: false, failed_id: example.id, error: result.exception)
          end
          if result.status.nil? && result.exception
            return Outcome.new(ok: false, failed_id: example.id, error: result.exception)
          end
          # :passed and :pending both leave the run green (a pending example is
          # not a failure to RSpec, so it does not kill a mutant either).
        end

        Outcome.new(ok: true, failed_id: nil, error: nil)
      end

      private

      def ensure_preloaded!
        return if @preloaded

        raise Mutation::Error, "rspec adapter used before #preload!"
      end

      # RSpec memoizes a regex built from the cwd where it first relativized a
      # spec path. In a long-lived process (our tests, or a library embedding
      # the adapter) that first cwd can be a different project, which leaves
      # example ids absolute. Rebuild it per preload so native ids stay in the
      # "./spec/x_spec.rb[1:2]" form.
      def reset_relative_path_cache!
        return unless defined?(::RSpec::Core::Metadata)

        metadata = ::RSpec::Core::Metadata
        if metadata.instance_variable_defined?(:@relative_path_regex)
          metadata.instance_variable_set(:@relative_path_regex, nil)
        end
      end

      # Every example RSpec would run after this preload. clear_examples at the
      # start of preload means the world only holds this project's examples;
      # specs pulled in by a spec_helper count too, exactly as they do under
      # the rspec binary.
      def collect_examples
        examples = {}
        ::RSpec.world.example_groups.each do |group|
          group.descendants.each do |descendant|
            descendant.examples.each do |example|
              # With clear_examples there should be no duplicates; keep the
              # latest object if a project loads a spec twice anyway.
              examples[example.id] = example
            end
          end
        end
        examples
      end

      # Example objects keep @exception from the last run; a fresh subset run
      # of the same example object after a failure must not inherit it. Pending
      # metadata is deliberately left alone.
      def reset_example_state(example)
        example.instance_variable_set(:@exception, nil)
        result = example.execution_result
        result.status = nil
        result.exception = nil
        result.finished_at = nil
        result.run_time = nil
        example
      rescue StandardError
        example
      end
    end
  end
end
