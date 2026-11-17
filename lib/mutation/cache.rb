# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "result"

module Mutation
  # On-disk result cache for a campaign.
  #
  # The key is deterministic in exactly the inputs that can change what running a
  # mutant means:
  #
  #   * the mutant id (which pins path/offset/operator/replacement)
  #   * sha256 of the full mutated source that would be loaded
  #   * adapter name
  #   * Ruby version
  #   * the selected test ids
  #
  # A hit skips the child entirely and the runner reports it with duration 0.
  # `ENV["RUBY_MUTATION_NO_CACHE"]` is the kill switch; it is read here rather
  # than added to the frozen Config.
  class Cache
    FORMAT_VERSION = 1
    KNOWN_STATUSES = %i[killed survived timeout error uncovered].freeze
    FALSE_VALUES = %w[0 false no off].freeze
    FILE_NAME = ".mutation-cache.json"

    def self.disabled?(env = ENV)
      raw = env["RUBY_MUTATION_NO_CACHE"]
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

    # -> {status:, failed_test:, message:} | nil
    def fetch(key)
      return nil unless @enabled

      entry = @entries[key]
      return nil unless entry.is_a?(Hash)

      status = entry["status"] || entry[:status]
      status = status.to_sym if status.respond_to?(:to_sym)
      return nil unless KNOWN_STATUSES.include?(status)
      return nil if status == :uncovered

      {
        status: status,
        failed_test: entry["failed_test"] || entry[:failed_test],
        message: entry["message"] || entry[:message]
      }
    end

    def store(key, status:, failed_test: nil, message: nil)
      return nil unless @enabled

      @entries[key.to_s] = {
        "status" => status.to_s,
        "failed_test" => failed_test,
        "message" => message
      }
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

    def load_entries
      return unless @enabled
      return unless File.file?(@path)

      parsed = JSON.parse(File.read(@path))
      entries = parsed.is_a?(Hash) ? (parsed["entries"] || parsed[:entries]) : nil
      @entries = entries.is_a?(Hash) ? entries : {}
    rescue SystemCallError, JSON::ParserError
      @entries = {}
    end
  end
end
