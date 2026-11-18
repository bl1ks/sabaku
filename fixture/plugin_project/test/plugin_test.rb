# frozen_string_literal: true

require "minitest/autorun"
require "plugin"

class PluginTest < Minitest::Test
  # The tolerant assertion first, so a mutant that changes ping's value is a win
  # on its own and the registry count only decides the mutants that keep it
  # positive. Loading plugin.rb a second time breaks the count, not the value.
  def test_the_plugin_is_loaded_once
    assert Plugin.ping.positive?
    assert_equal 1, Registry.entries.size
  end
end
