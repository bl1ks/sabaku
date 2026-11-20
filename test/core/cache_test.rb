# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class CacheTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("sabaku-cache")
    @path = File.join(@dir, ".sabaku-cache.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(version, entries)
    File.write(@path, JSON.generate("version" => version, "entries" => entries))
  end

  def entry(status)
    { "status" => status.to_s, "failed_test" => nil, "message" => nil }
  end

  def test_a_current_file_is_loaded
    write(Sabaku::Cache::FORMAT_VERSION, "key" => entry(:killed))

    cache = Sabaku::Cache.new(@path)

    assert_equal 1, cache.size
    assert_equal :killed, cache.fetch("key")[:status]
  end

  def test_a_survivor_reason_round_trips
    cache = Sabaku::Cache.new(@path)
    cache.store("key", status: :survived, reason: :not_infected)
    cache.save!

    reloaded = Sabaku::Cache.new(@path)

    assert_equal :survived, reloaded.fetch("key")[:status]
    assert_equal :not_infected, reloaded.fetch("key")[:reason]
  end

  def test_a_file_with_another_format_version_is_ignored
    write(Sabaku::Cache::FORMAT_VERSION + 1, "key" => entry(:killed))

    cache = Sabaku::Cache.new(@path)

    assert_equal 0, cache.size
    assert_nil cache.fetch("key")
  end
end
