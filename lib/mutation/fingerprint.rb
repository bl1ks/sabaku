# frozen_string_literal: true

require "digest"

module Mutation
  # The campaign inputs that sit outside the mutated source but still decide what
  # running a mutant means. A cache key that leaves any of them out answers a
  # question the previous campaign never asked:
  #
  #   * a test whose body gained an assertion keeps its id, so the id alone says
  #     nothing about whether the test would notice the mutant now
  #   * a setup file decides which application boots and which hooks run
  #   * ENV and --require change what the child loads
  #   * fork and process isolation disagree about the same mutant
  #   * a deadline turns a hang into a timeout instead of a survivor
  #
  # The test digest covers every `.rb` under the test directories, not only the
  # `*_test.rb` files: a test helper is part of the suite and changes it just as
  # often. Files loaded from installed gems are out of reach here and out of
  # scope for a cache that has to stay cheap.
  Fingerprint = Data.define(:digest) do
    def self.for(config, adapter)
      parts = [
        "tests=#{test_digest(adapter)}",
        "setup=#{setup_digest(config)}",
        "env=#{stable(config.env)}",
        "requires=#{stable(config.requires)}",
        "isolation=#{config.isolation}",
        "weak=#{config.respond_to?(:weak) ? config.weak : false}",
        "timeout=#{format("%.6f", config.timeout)}"
      ]
      new(digest: Digest::SHA256.hexdigest(parts.join("\u0000")))
    end

    def self.test_digest(adapter)
      root = adapter.root.to_s
      prefix = root.end_with?("/") ? root : "#{root}/"
      files = adapter.test_files.flat_map { |file| Dir.glob(File.join(File.dirname(file), "**/*.rb")) }
      digest = Digest::SHA256.new
      files.uniq.sort.each do |file|
        digest << file.delete_prefix(prefix) << "\u0000" << Digest::SHA256.file(file).hexdigest
      end
      digest.hexdigest
    end

    def self.setup_digest(config)
      path = config.respond_to?(:setup_path) ? config.setup_path : nil
      return Digest::SHA256.file(path.to_s).hexdigest if path && File.file?(path.to_s)

      setup = config.respond_to?(:setup) ? config.setup : nil
      return "none" unless setup.is_a?(Setup)

      hooks = setup.hooks.flat_map do |event, list|
        list.map { |hook| "#{event}:#{Array(hook.source_location).join(":")}:#{hook.arity}" }
      end
      Digest::SHA256.hexdigest([setup.env_vars.sort, setup.require_paths, hooks.sort].inspect)
    end

    # Hash order in a config hash must not change the key.
    def self.stable(value)
      case value
      when Hash then value.sort.map { |key, item| "#{key}=#{item}" }.join(",")
      when Array then value.join(",")
      else value.to_s
      end
    end
  end
end
