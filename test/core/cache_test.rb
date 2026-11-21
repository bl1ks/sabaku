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

  def test_killers_round_trip
    cache = Sabaku::Cache.new(@path)
    cache.store("key", status: :killed, failed_test: "A#t", killers: %w[A#t B#t])
    cache.save!

    assert_equal %w[A#t B#t], Sabaku::Cache.new(@path).fetch("key")[:killers]
  end

  def test_an_entry_without_killers_still_fetches
    write(Sabaku::Cache::FORMAT_VERSION, "key" => entry(:killed))

    hit = Sabaku::Cache.new(@path).fetch("key")

    assert_equal :killed, hit[:status]
    assert_nil hit[:killers]
  end

  def test_malformed_killers_drop_the_row_not_the_status
    [["B#t"], [1], "A#t", []].each do |killers|
      write(Sabaku::Cache::FORMAT_VERSION,
            "key" => entry(:killed).merge("failed_test" => "A#t", "killers" => killers))

      hit = Sabaku::Cache.new(@path).fetch("key")

      assert_equal :killed, hit[:status], killers.inspect
      assert_nil hit[:killers], killers.inspect
    end
  end

  def test_a_store_without_killers_keeps_the_row_for_the_same_kill
    cache = Sabaku::Cache.new(@path)
    cache.store("key", status: :killed, failed_test: "A#t", killers: %w[A#t B#t])
    cache.store("key", status: :killed, failed_test: "A#t")

    assert_equal %w[A#t B#t], cache.fetch("key")[:killers]

    cache.store("key", status: :killed, failed_test: "B#t")

    assert_nil cache.fetch("key")[:killers]
  end

  def test_a_file_with_another_format_version_is_ignored
    write(Sabaku::Cache::FORMAT_VERSION + 1, "key" => entry(:killed))

    cache = Sabaku::Cache.new(@path)

    assert_equal 0, cache.size
    assert_nil cache.fetch("key")
  end
end
