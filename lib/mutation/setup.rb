# frozen_string_literal: true

module Mutation
  # Project-level boot script. It is the only place a project can add code that
  # runs around a campaign, which is what a framework like Rails needs: load the
  # application under coverage, eager load constants, drop the parent's database
  # connection before forking, and give each child its own database.
  #
  # The script is plain Ruby evaluated against one Setup value:
  #
  #   Mutation.setup do
  #     env "RAILS_ENV" => "test"
  #     require_path "./config/environment"
  #     after_boot     { Rails.application.eager_load! }
  #     before_fork    { ActiveRecord::Base.connection_pool.disconnect! }
  #     child_start    { |index| Database.clone_for(index) }
  #   end
  #
  # Every hook is optional and every hook list runs in registration order. Using
  # `instance_exec` keeps the DSL to methods on this object, so a project cannot
  # reach the runner from its setup file.
  class Setup
    EVENTS = %i[after_boot before_fork child_start before_test_run].freeze

    # The coverage pass and the runner both preload the suite, so the two
    # "once per campaign" hooks would otherwise fire twice.
    ONCE = %i[after_boot before_fork].freeze

    attr_reader :env_vars, :require_paths, :hooks

    def initialize
      @env_vars = {}
      @require_paths = []
      @hooks = EVENTS.to_h { |event| [event, []] }
      @fired = {}
    end

    # ENV entries applied before the application loads. String keys and values,
    # because ENV only accepts those.
    # Accepts both `env "RAILS_ENV" => "test"` (a braceless hash, which Ruby
    # passes as keywords) and `env({ "RAILS_ENV" => "test" })`.
    def env(pairs = nil, **keywords)
      pairs.to_h.merge(keywords).each { |key, value| @env_vars[key.to_s] = value.to_s }
      self
    end

    # Paths required after Coverage starts and before the test files load, so
    # the application's own files are instrumented from the first parse.
    def require_path(path)
      @require_paths << path.to_s
      self
    end

    EVENTS.each do |event|
      define_method(event) do |&block|
        raise ArgumentError, "#{event} needs a block" if block.nil?

        @hooks[event] << block
        self
      end
    end

    # Runs every block registered for +event+. A hook that raises aborts the
    # campaign: the project asked for it, so the failure is the project's.
    def fire(event, *args)
      return self if ONCE.include?(event) && @fired[event]

      @fired[event] = true if ONCE.include?(event)
      Array(@hooks[event]).each { |hook| hook.call(*args) }
      self
    rescue BootError
      raise
    rescue StandardError => e
      raise BootError, "#{event} hook failed: #{e.class}: #{e.message}"
    end

    def empty?
      @env_vars.empty? && @require_paths.empty? && @hooks.values.all?(&:empty?)
    end
  end

  # Build a Setup from a block or from a file path. The file form is what the
  # CLI uses (`--setup=mutation.rb`); the block form is for library users and
  # tests.
  def self.setup(path = nil, &block)
    setup = Setup.new
    if path
      setup.instance_eval(File.read(path), path)
    elsif block
      setup.instance_exec(&block)
    end
    setup
  end
end
