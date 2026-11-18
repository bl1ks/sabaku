# frozen_string_literal: true

# Process-isolation bootstrap.
#
# The parent runner writes `mutant.splice(source)` to a temp file and spawns
#
#   ruby -I <mutation-lib> lib/mutation/runtime/bootstrap.rb
#
# with these environment variables:
#
#   RUBY_MUTATION_ROOT         project root (child cwd is also set to this)
#   RUBY_MUTATION_ADAPTER      "minitest" | "rspec"
#   RUBY_MUTATION_TEST_IDS     JSON array of test ids to run
#   RUBY_MUTATION_MUTANT_PATH  repo-relative path of the mutated file
#   RUBY_MUTATION_MUTATED_FILE absolute path of the mutated temporary file
#   RUBY_MUTATION_PAYLOAD_FD   fd number of the completion pipe (3)
#   RUBY_MUTATION_NEUTRAL      "1" boots the project with no mutation applied
#                              (the baseline check in process isolation)
#
# The mutated source is loaded first, then the original target path is put in
# $LOADED_FEATURES so the project's `require "target"` (in the test files) is a
# no-op and the mutated definitions stay in place. Then the adapter preloads the
# test suite and runs exactly the requested ids.
#
# Exit contract (shared with fork isolation):
#   0 = selected tests passed   -> survived
#   1 = a selected test failed  -> killed
#   2 = could not boot/run      -> error
#
# A JSON line written to the payload fd is the completion signal; it carries
# `ok`, `failed_id`, `error`, or `boot_error`.

require "json"

module Mutation
  module Runtime
    module Bootstrap
      module_function

      def call
        payload = payload_io
        begin
          root = File.expand_path(ENV.fetch("RUBY_MUTATION_ROOT", Dir.pwd))
          Dir.chdir(root)
          index = Integer(ENV.fetch("RUBY_MUTATION_CHILD_INDEX", "0"))
          adapter_name = ENV.fetch("RUBY_MUTATION_ADAPTER", "minitest")
          target_path = ENV.fetch("RUBY_MUTATION_MUTANT_PATH")
          mutated_file = ENV.fetch("RUBY_MUTATION_MUTATED_FILE")
          test_ids = JSON.parse(ENV.fetch("RUBY_MUTATION_TEST_IDS", "[]"))

          @adapter = build_adapter(adapter_name)
          prepare_load_path(root)
          @setup = load_setup
          apply_env
          apply_requires
          fire(:child_start, index)
          load_mutated_target(target_path, mutated_file, root) unless neutral?
          @adapter.preload!
          fire(:after_boot)
          fire(:before_test_run)
          outcome = @adapter.run(test_ids)

          emit(payload,
               "ok" => outcome.ok,
               "failed_id" => outcome.failed_id&.to_s,
               "error" => outcome.error && describe(outcome.error))
          exit!(outcome.ok ? 0 : 1)
        rescue Exception => e # rubocop:disable Lint/RescueException
          emit(payload, "boot_error" => true, "error" => describe(e))
          exit!(2)
        end
      end

      # A neutral child runs the suite with no mutation applied at all, which is
      # the only way to learn that a red suite is red before anything is mutated.
      def neutral?
        ENV["RUBY_MUTATION_NEUTRAL"] == "1"
      end

      def build_adapter(name)
        require "mutation/adapters/base"
        Mutation::Adapter.for(name, nil)
      end

      # The mutated file is loaded before the adapter preloads the tests, so the
      # project's own lib/test/spec roots must already be on the load path for
      # its top-level `require`s to resolve exactly as they do normally.
      def prepare_load_path(root)
        %w[lib test spec].each do |directory|
          path = File.join(root, directory)
          next unless File.directory?(path)
          next if $LOAD_PATH.include?(path)

          $LOAD_PATH.unshift(path)
        end
      end

      # The one load-bearing trick: re-execute the spliced file, then hide the
      # original from `require` so the test files cannot undo the mutation.
      #
      # eval with the original absolute path, not load of the temp file: a file that
      # uses require_relative or __FILE__ must see the path it is used to, or a
      # mutation of the library's own source breaks on `require_relative "sibling"`.
      def load_mutated_target(target_path, mutated_file, root)
        absolute = File.expand_path(target_path.to_s, root)
        # Constant redefinitions are expected when a file is re-executed.
        quietly { TOPLEVEL_BINDING.eval(File.read(mutated_file), absolute, 1) }

        features = [absolute]
        begin
          features << File.realpath(absolute)
        rescue SystemCallError
          nil
        end
        features.each do |feature|
          $LOADED_FEATURES << feature unless $LOADED_FEATURES.include?(feature)
        end
      end

      # A process-isolated child starts from a bare Ruby: every hook the fork
      # path got from the parent has to be replayed here, in the same order.
      def load_setup
        path = ENV.fetch("RUBY_MUTATION_SETUP", "")
        return nil if path.empty?

        require "mutation/setup"
        Mutation.setup(path)
      end

      # Project ENV first, then the setup file's entries, so a setup file wins.
      def apply_env
        JSON.parse(ENV.fetch("RUBY_MUTATION_ENV", "{}")).each { |key, value| ENV[key] = value }
        @setup&.env_vars&.each { |key, value| ENV[key] = value }
      rescue JSON::ParserError
        raise Mutation::Error, "RUBY_MUTATION_ENV is not valid JSON"
      end

      def apply_requires
        JSON.parse(ENV.fetch("RUBY_MUTATION_REQUIRES", "[]")).each do |path|
          expanded = File.expand_path(path)
          require(File.exist?(expanded) ? expanded : path)
        end
      rescue JSON::ParserError
        raise Mutation::Error, "RUBY_MUTATION_REQUIRES is not valid JSON"
      end

      def fire(event, *args)
        @setup&.fire(event, *args)
      end

      def quietly
        previous = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = previous
      end

      def payload_io
        descriptor = Integer(ENV.fetch("RUBY_MUTATION_PAYLOAD_FD", "3"))
        IO.new(descriptor, "w")
      rescue StandardError
        $stdout
      end

      def emit(io, payload)
        io.write(JSON.generate(payload) + "\n")
        io.flush
      rescue StandardError
        nil
      end

      def describe(exception)
        message = "#{exception.class}: #{exception.message}"
        message.length > 500 ? message[0, 500] : message
      rescue StandardError
        "unknown exception"
      end
    end
  end
end

Mutation::Runtime::Bootstrap.call if $PROGRAM_NAME == __FILE__
