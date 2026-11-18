# frozen_string_literal: true

require "tmpdir"

module Mutation
  module Runtime
    # Applies a mutation at the target file's first load instead of
    # re-evaluating the file over a copy the child already loaded.
    #
    # Evaluating the mutated file before anything else is not enough: a file
    # that uses the project at load time (Active Support's configurable.rb calls
    # `ActiveSupport.deprecator`) fails when nothing else has loaded yet. So the
    # child's suite loads in its normal order, and this loader substitutes the
    # mutated source at the moment the project would load the target, whether
    # that is a `require` or an `autoload` registered for it.
    #
    # An `autoload` cannot simply be suppressed: Ruby fires a pending autoload
    # when the mutated file opens its own module, the require it performs finds
    # the feature already applied, and the constant stays missing. So the
    # registration is redirected to a generated shim that evaluates the mutated
    # source with the original path. The constant is then defined at exactly the
    # point the project would have loaded the file.
    #
    # Not intercepted: `require_relative` and a file something loaded before
    # this loader was installed. `loaded_without_apply?` detects the second case
    # so the child can name it instead of evaluating over a copy.
    class FirstLoad
      class << self
        attr_accessor :current
      end

      def initialize(target:, source:, root:, shim_dir: nil)
        @target = File.expand_path(target.to_s, root)
        @source = source
        @shim_dir = shim_dir || Dir.tmpdir
        @basename = File.basename(@target)
        @real_target = begin
          File.realpath(@target)
        rescue SystemCallError
          nil
        end
        @applied = false
        @redirected_autoloads = []
      end

      def target
        @target
      end

      def applied?
        @applied
      end

      # Constants whose autoload this loader redirected, in registration order.
      attr_reader :redirected_autoloads

      def install
        self.class.current = self
        Kernel.prepend(KernelHook) unless Kernel.ancestors.include?(KernelHook)
        Module.prepend(AutoloadHook) unless Module.ancestors.include?(AutoloadHook)
        self
      end

      # Whether `feature` names the target file. Accepts the forms `require`
      # and `autoload` take: a bare feature name, a name with `.rb`, or an
      # absolute path.
      def mutates?(feature)
        return false if feature.nil?

        resolved = resolve(feature.to_s)
        return false if resolved.nil?
        return true if resolved == @target

        !@real_target.nil? && realpath(resolved) == @real_target
      end

      # A one-line file the project's autoload machinery requires instead of the
      # target. The eval keeps the original path, so __FILE__ and require_relative
      # inside the mutated file behave as they do normally.
      def autoload_shim
        @autoload_shim ||= begin
          path = File.join(@shim_dir, "first-load-#{Process.pid}-#{@basename}.rb")
          File.write(path, <<~RUBY)
            require "mutation/runtime/first_load"
            Mutation::Runtime::FirstLoad.current.apply
          RUBY
          path
        end
      end

      def apply
        return false if @applied

        @applied = true
        clear_pending_autoloads
        quietly { TOPLEVEL_BINDING.eval(@source, @target, 1) }
        features.each { |feature| $LOADED_FEATURES << feature unless $LOADED_FEATURES.include?(feature) }
        true
      end

      # True when the project loaded the target before this loader could
      # substitute it, so re-evaluating would be a second load.
      def loaded_without_apply?
        return false if @applied

        features.any? { |feature| $LOADED_FEATURES.include?(feature) }
      end

      private

      def resolve(feature)
        if feature.start_with?("/")
          return File.basename(feature) == @basename ? feature : nil
        end

        names = feature.end_with?(".rb") ? [feature] : [feature, "#{feature}.rb"]
        $LOAD_PATH.each do |directory|
          next if directory.to_s.empty?

          names.each do |name|
            candidate = File.expand_path(File.join(directory, name))
            next unless File.basename(candidate) == @basename
            return candidate if File.file?(candidate)
          end
        end
        nil
      end

      def realpath(path)
        File.realpath(path)
      rescue SystemCallError
        nil
      end

      def features
        [@target, @real_target].compact.uniq
      end

      # A redirected autoload stays pending until its constant is touched. The
      # mutated file opens `module Name` (or `class Name`) itself, and that
      # lookup would fire the pending autoload again, re-enter apply, and leave
      # the constant undefined. Removing the pending registration first lets the
      # file define its own constant; remove_const does not trigger the load.
      def clear_pending_autoloads
        @redirected_autoloads.each do |owner, name|
          next unless owner.autoload?(name)

          owner.send(:remove_const, name)
        end
      end

      def quietly
        previous = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = previous
      end

      module KernelHook
        def require(feature)
          loader = FirstLoad.current
          return loader.apply if loader&.mutates?(feature)

          super
        end

        def load(path, wrap = false)
          loader = FirstLoad.current
          return loader.apply if loader&.mutates?(path)

          super
        end
      end

      module AutoloadHook
        def autoload(name, path = nil)
          loader = FirstLoad.current
          if loader&.mutates?(path)
            loader.redirected_autoloads << [self, name]
            return super(name, loader.autoload_shim)
          end

          super
        end
      end
    end
  end
end
