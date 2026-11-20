# frozen_string_literal: true

module Sabaku
  # Applies the Setup to the current process at the four points the campaign
  # controls. Kept apart from Setup so the ordering is one readable list
  # instead of scattered `respond_to?` checks in the runner:
  #
  #   env            before anything loads (RAILS_ENV)
  #   require_paths  after Coverage.start, before the adapter preloads tests
  #   after_boot     after the test framework and application are loaded
  #   before_fork    in the parent, once, before any child exists
  #   child_start    in each child, before the mutated file is evaluated
  #   before_test_run in each child, after the mutation is applied
  module Boot
    module_function

    # Config env first, then the setup file's, so the file wins when both name
    # the same key.
    def env(config)
      config.env.each { |key, value| ENV[key] = value } if config.respond_to?(:env)
      setup_for(config)&.env_vars&.each { |key, value| ENV[key] = value }
      config
    end

    def require_paths(config)
      setup = setup_for(config)
      return config unless setup

      setup.require_paths.each { |path| require_one(path) }
      config
    end

    def fire(config, event, *args)
      setup_for(config)&.fire(event, *args)
      config
    end

    # Relative paths are taken from the project root, which is where the CLI
    # runs, but a library caller can hand in an absolute one.
    def require_one(path)
      expanded = File.expand_path(path)
      require(File.exist?(expanded) ? expanded : path)
    rescue BootError
      raise
    rescue StandardError, ScriptError => e
      raise BootError, "require_path #{path.inspect} failed: #{e.class}: #{e.message}"
    end

    def setup_for(config)
      return nil unless config.respond_to?(:setup)

      setup = config.setup
      setup.is_a?(Setup) ? setup : nil
    end
  end
end
