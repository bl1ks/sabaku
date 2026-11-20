# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "result"

module Sabaku
  # On-disk result cache for a campaign.
  #
  # The key is deterministic in exactly the inputs that can change what running a
  # mutant means:
  #
  #   * the mutant id (which pins path/scope/ast path/operator/replacement)
  #   * sha256 of the full mutated source that would be loaded
  #   * Ruby version
  #   * the selected test ids
  #   * a campaign fingerprint over the test tree, the setup file, ENV,
  #     --require, isolation and the timeout (see Fingerprint)
  #
  # A hit skips the child entirely and the runner reports it with duration 0.
  #
  # A killed entry may carry `killers`, the --kill-matrix row. The key is optional
  # rather than a format bump: an older reader ignores it, and an entry without it
  # still answers the status, so the row is the only thing a sweep has to add.
  # `ENV["SABAKU_NO_CACHE"]` is the kill switch; it is read here rather
  # than added to the frozen Config.
  class Cache
    FORMAT_VERSION = 3
    KNOWN_STATUSES = %i[killed survived timeout error uncovered].freeze
    FALSE_VALUES = %w[0 false no off].freeze
    FILE_NAME = ".sabaku-cache.json"

    def self.disabled?(env = ENV)
      raw = env["SABAKU_NO_CACHE"]
      return false if raw.nil?

      value = raw.to_s.strip.downcase
      return false if value.empty? || FALSE_VALUES.include?(value)

      true
    end

    # `config.output`'s directory when a report path is configured, otherwise
    # the working directory.
    def self.default_path(config = nil)
      output = config.respond_to?(:output) ? config.output : nil
      if output && !output.to_s.empty?
        File.join(File.dirname(File.expand_path(output.to_s)), FILE_NAME)
      else
        File.join(Dir.pwd, FILE_NAME)
      end
    end

    attr_reader :path

    def initialize(path, enabled: true)
      @path = path.to_s
      @enabled = enabled ? true : false
      @entries = {}
      @dirty = false
      load_entries
    end

    def enabled?
      @enabled
    end

    def size
      @entries.size
    end

    # -> {status:, failed_test:, message:, reason:, killers:} | nil
    def fetch(key)
      return nil unless @enabled

      entry = @entries[key]
      return nil unless entry.is_a?(Hash)

      status = entry["status"] || entry[:status]
      status = status.to_sym if status.respond_to?(:to_sym)
      return nil unless KNOWN_STATUSES.include?(status)
      return nil if status == :uncovered

      reason = entry["reason"] || entry[:reason]
      failed_test = entry["failed_test"] || entry[:failed_test]
      {
        status: status,
        failed_test: failed_test,
        message: entry["message"] || entry[:message],
        reason: reason.nil? ? nil : reason.to_sym,
        killers: killers_of(entry, status, failed_test)
      }
    end

    # A store without `killers` keeps the row already there for the same kill, so a
    # run without --kill-matrix does not erase what a run with it paid for.
    def store(key, status:, failed_test: nil, message: nil, reason: nil, killers: nil)
      return nil unless @enabled

      key = key.to_s
      killers ||= kept_killers(@entries[key], status, failed_test)
      entry = {
        "status" => status.to_s,
        "failed_test" => failed_test,
        "message" => message,
        "reason" => reason&.to_s
      }
      entry["killers"] = killers if killers
      @entries[key] = entry
      @dirty = true
      self
    end

    # Atomic-ish: write a sibling temp file, then rename over the cache.
    def save!
      return false unless @enabled && @dirty

      directory = File.dirname(@path)
      FileUtils.mkdir_p(directory) unless File.directory?(directory)
      temporary = "#{@path}.#{Process.pid}.tmp"
      File.write(temporary, JSON.generate("version" => FORMAT_VERSION, "entries" => @entries))
      File.rename(temporary, @path)
      @dirty = false
      true
    rescue SystemCallError, JSON::GeneratorError, TypeError
      false
    ensure
      begin
        File.unlink(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
      rescue SystemCallError
        nil
      end
    end

    private

    # A malformed row loses the row, never the status.
    def killers_of(entry, status, failed_test)
      killers = entry["killers"] || entry[:killers]
      return nil unless status == :killed && killers.is_a?(Array) && !killers.empty?
      return nil unless killers.all?(String)
      return nil if failed_test && !killers.include?(failed_test)

      killers
    end

    def kept_killers(previous, status, failed_test)
      return nil unless previous.is_a?(Hash) && status.to_s == previous["status"]
      return nil unless failed_test == previous["failed_test"]

      killers_of(previous, status.to_sym, failed_test)
    end

    def load_entries
      return unless @enabled
      return unless File.file?(@path)

      parsed = JSON.parse(File.read(@path))
      return unless parsed.is_a?(Hash)
      return unless (parsed["version"] || parsed[:version]).to_i == FORMAT_VERSION

      entries = parsed["entries"] || parsed[:entries]
      @entries = entries.is_a?(Hash) ? entries : {}
    rescue SystemCallError, JSON::ParserError
      @entries = {}
    end
  end
end
