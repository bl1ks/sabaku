# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "mutation"
require "minitest/autorun"

module FixtureHelper
  ROOT = File.expand_path("..", __dir__)

  def fixture_path(*parts)
    File.join(ROOT, "fixture", *parts)
  end

  def read_fixture(*parts)
    File.read(fixture_path(*parts))
  end
end
