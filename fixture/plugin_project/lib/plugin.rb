# frozen_string_literal: true

require_relative "registry"

class Plugin
  Registry.add(:plugin)

  def self.ping
    1
  end
end
