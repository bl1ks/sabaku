# frozen_string_literal: true

# Process-isolation bootstrap.
#
# The parent runner writes `mutant.splice(source)` to a temp file and spawns
#
#   ruby -I <mutation-lib> lib/sabaku/runtime/bootstrap.rb
#
# with these environment variables:
#
#   SABAKU_ROOT         project root (child cwd is also set to this)
#   SABAKU_TEST_IDS     JSON array of test ids to run
#   SABAKU_MUTANT_PATH  repo-relative path of the mutated file
#   SABAKU_MUTATED_FILE absolute path of the mutated temporary file
#   SABAKU_PAYLOAD_FD   fd number of the completion pipe (3)
#   SABAKU_NEUTRAL      "1" boots the project with no mutation applied
#                              (the baseline check in process isolation)
#
# The mutated source is applied at the target file's first load. The adapter
# preloads the project in its normal order and a loader substitutes the mutated
# source when the project requires the target, so a file that uses the project
# at load time sees the project already loaded. A file the project never loads
# is applied after the preload. Then the child runs exactly the requested ids.
#
# A neutral child skips the loader and boots the project untouched.
#
# Exit contract (shared with fork isolation):
#   0 = selected tests passed   -> survived
#   1 = a selected test failed  -> killed
#   2 = could not boot/run      -> error
#
# A JSON line written to the payload fd is the completion signal; it carries
# `ok`, `failed_id`, `error`, or `boot_error`.

require "json"

module Sabaku
  module Runtime
    module Bootstrap
      module_function

      def call
        payload = payload_io
        begin
          root = File.expand_path(ENV.fetch("SABAKU_ROOT", Dir.pwd))
          Dir.chdir(root)
          index = Integer(ENV.fetch("SABAKU_CHILD_INDEX", "0"))
          target_path = ENV.fetch("SABAKU_MUTANT_PATH")
          mutated_file = ENV.fetch("SABAKU_MUTATED_FILE")
          test_ids = JSON.parse(ENV.fetch("SABAKU_TEST_IDS", "[]"))

          require "sabaku/adapters/minitest"
          @adapter = Sabaku::Adapters::MinitestAdapter.new
          prepare_load_path(root)
          install_loader(target_path, mutated_file, root) unless neutral?
          @setup = load_setup
          apply_env
          fire(:child_start, index)
          apply_requires
          @adapter.preload!
          apply_loader
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
        ENV["SABAKU_NEUTRAL"] == "1"
      end

      # The loader intercepts the project's own `require`s, so its lib/test
      # roots must already be on the load path for them to resolve exactly as
      # they do normally.
      def prepare_load_path(root)
        %w[lib test].each do |directory|
          path = File.join(root, directory)
          next unless File.directory?(path)
          next if $LOAD_PATH.include?(path)

          $LOAD_PATH.unshift(path)
        end
      end

      # The one load-bearing trick: the child's suite loads in its normal order,
      # and FirstLoad substitutes the mutated source at the moment the project
      # requires the target. eval keeps the original absolute path, not the temp
      # file's: a file that uses require_relative or __FILE__ must see the path
      # it is used to.
      def install_loader(target_path, mutated_file, root)
        require "sabaku/runtime/first_load"
        @loader = FirstLoad.new(target: target_path, source: File.read(mutated_file), root: root,
                                shim_dir: File.dirname(mutated_file))
        @loader.install
      end

      # The suite has loaded by now. If the project never required the target,
      # apply it here. If something loaded it without going through the loader
      # (require_relative, or a file the -r flags loaded first), re-evaluating
      # would be a second load, so name the cause instead.
      def apply_loader
        return if @loader.nil? || @loader.applied?

        if @loader.loaded_without_apply?
          raise Sabaku::Error,
                "#{@loader.target} was loaded before the mutation could be applied " \
                "(require_relative or a preloaded file); this mutant cannot be measured " \
                "on a first-load surface"
        end

        @loader.apply
      end

      # A process-isolated child starts from a bare Ruby: every hook the fork
      # path got from the parent has to be replayed here, in the same order.
      def load_setup
        path = ENV.fetch("SABAKU_SETUP", "")
        return nil if path.empty?

        require "sabaku/setup"
        Sabaku.setup(path)
      end

      # Project ENV first, then the setup file's entries, so a setup file wins.
      def apply_env
        JSON.parse(ENV.fetch("SABAKU_ENV", "{}")).each { |key, value| ENV[key] = value }
        @setup&.env_vars&.each { |key, value| ENV[key] = value }
      rescue JSON::ParserError
        raise Sabaku::Error, "SABAKU_ENV is not valid JSON"
      end

      def apply_requires
        JSON.parse(ENV.fetch("SABAKU_REQUIRES", "[]")).each do |path|
          expanded = File.expand_path(path)
          require(File.exist?(expanded) ? expanded : path)
        end
      rescue JSON::ParserError
        raise Sabaku::Error, "SABAKU_REQUIRES is not valid JSON"
      end

      def fire(event, *args)
        @setup&.fire(event, *args)
      end

      def payload_io
        descriptor = Integer(ENV.fetch("SABAKU_PAYLOAD_FD", "3"))
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

Sabaku::Runtime::Bootstrap.call if $PROGRAM_NAME == __FILE__
