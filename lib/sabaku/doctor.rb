# frozen_string_literal: true

require_relative "boot"
require_relative "errors"

module Sabaku
  # `sabaku doctor --setup=PATH`: boot the project the way the coverage pass does, run no
  # test, and say what would make a campaign's numbers wrong. Collecting the facts is the
  # only impure step; each check is a pure function of them.
  module Doctor
    Finding = Data.define(:id, :severity, :message, :doc)

    # A boot fact is nil when the project was not booted, so no check guesses about it.
    #   boot_error        String | nil   the boot raised; the other boot facts are nil
    #   coverage_modes    Array[Symbol]  Coverage modes seen on a file without line counters
    #   parallel_executor String | nil   Minitest.parallel_executor's class
    #   unloaded_targets  Array[String]  target files not loaded once the suite has booted
    #   jobs              Integer
    #   child_start       Boolean | nil  the setup has a child_start hook; nil without a setup
    #   concerns          Array[String]  target files that extend ActiveSupport::Concern
    #   sorbet_runtime    Boolean | nil  T::Sig is loaded after the boot
    Facts = Data.define(:boot_error, :coverage_modes, :parallel_executor, :unloaded_targets,
                        :jobs, :child_start, :concerns, :sorbet_runtime)

    SHOWN = 3

    def self.files(count) = count == 1 ? "1 target file is" : "#{count} target files are"

    CHECKS = {
      boot: lambda do |facts|
        next unless facts.boot_error

        Finding.new(id: :boot, severity: :warn, doc: nil,
                    message: "the boot failed, so a campaign would stop: #{facts.boot_error}")
      end,
      coverage_mode: lambda do |facts|
        next if facts.coverage_modes.to_a.empty?

        Finding.new(id: :coverage_mode, severity: :warn, doc: "docs/rails.md#simplecov",
                    message: "Coverage runs without line counters (#{facts.coverage_modes.join(", ")}), " \
                             "so a campaign stops before the first test; keep SimpleCov out of it")
      end,
      eager_load: lambda do |facts|
        unloaded = facts.unloaded_targets.to_a
        next if unloaded.empty?

        more = unloaded.size > SHOWN ? " and #{unloaded.size - SHOWN} more" : ""
        Finding.new(id: :eager_load, severity: :warn, doc: "docs/rails.md#why-eager-load",
                    message: "#{files(unloaded.size)} not loaded after the boot " \
                             "(#{unloaded.first(SHOWN).join(", ")}#{more}); their lines are only " \
                             "attributed to the test that loads them. Eager load in after_boot")
      end,
      child_start: lambda do |facts|
        next unless facts.jobs > 1 && facts.child_start == false

        Finding.new(id: :child_start, severity: :warn, doc: "docs/rails.md#database-recipes",
                    message: "--jobs=#{facts.jobs} and the setup has no child_start hook, so the " \
                             "children share whatever the suite writes outside the process (a database, Redis) " \
                             "and can fail each other's tests")
      end,
      parallel_executor: lambda do |facts|
        name = facts.parallel_executor
        next if name.nil? || name.start_with?("Minitest::")

        Finding.new(id: :parallel_executor, severity: :info, doc: nil,
                    message: "#{name} is the minitest parallel executor. sabaku runs test ids itself " \
                             "and never calls it, so `parallelize` does nothing here; --jobs is the knob")
      end,
      concerns: lambda do |facts|
        next if facts.concerns.empty?

        Finding.new(id: :concerns, severity: :info, doc: "docs/rails.md#concerns",
                    message: "#{facts.concerns.size} of the targets extend ActiveSupport::Concern " \
                             "(#{facts.concerns.first(SHOWN).join(", ")}); a mutation that moves an " \
                             "`included` block does not load without the recipe")
      end,
      sorbet_runtime: lambda do |facts|
        next unless facts.sorbet_runtime

        Finding.new(id: :sorbet_runtime, severity: :info, doc: "docs/rails.md#sorbet",
                    message: "sorbet-runtime is loaded. Type annotations are not mutated, and a def " \
                             "with a sig is never deleted")
      end
    }.freeze

    def self.findings(facts)
      CHECKS.each_value.filter_map { |check| check.call(facts) }
    end

    # Only a setup file or a --require says how a campaign would load the project.
    def self.boots?(config) = !config.setup.nil? || config.requires.any?

    # after_campaign always fires, so a setup that creates a database also drops it.
    def self.facts(config, adapter, sources)
      static = { jobs: config.jobs, child_start: config.setup && !config.setup.hooks[:child_start].empty?,
                 concerns: sources.select { |source| source.text.match?(/^\s*extend\s+ActiveSupport::Concern\b/) }
                                  .map(&:rel_path) }
      return Facts.new(boot_error: nil, coverage_modes: nil, parallel_executor: nil, unloaded_targets: nil,
                       sorbet_runtime: nil, **static) unless boots?(config)

      Facts.new(**static, **boot(config, adapter, sources))
    ensure
      Boot.fire(config, :after_campaign) if config.setup
    end

    def self.boot(config, adapter, sources)
      require "coverage"
      Boot.env(config)
      modes = ::Coverage.running? ? foreign_modes : []
      started = !::Coverage.running?
      ::Coverage.start(lines: true) if started
      Boot.require_paths(config)
      adapter.preload!
      Boot.fire(config, :after_boot)
      loaded = $LOADED_FEATURES.to_h { |feature| [feature, true] }
      { boot_error: nil, coverage_modes: (modes | foreign_modes).sort,
        parallel_executor: defined?(::Minitest.parallel_executor) ? ::Minitest.parallel_executor.class.name : nil,
        unloaded_targets: sources.map(&:rel_path).reject { |path| loaded[File.expand_path(path)] },
        sorbet_runtime: defined?(::T::Sig) ? true : false }
    rescue StandardError, ScriptError => e
      { boot_error: "#{e.class}: #{e.message}", coverage_modes: nil, parallel_executor: nil,
        unloaded_targets: nil, sorbet_runtime: nil }
    ensure
      ::Coverage.result if started && ::Coverage.running?
    end

    # Coverage.peek_result values are Arrays in the legacy mode and Hashes otherwise; a Hash
    # without :lines is a mode the sampler cannot attribute.
    def self.foreign_modes
      ::Coverage.peek_result.values.grep(Hash).reject { |data| data.key?(:lines) }.flat_map(&:keys).uniq
    end
  end
end
