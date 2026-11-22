# frozen_string_literal: true

raise "preloaded.rb cannot be loaded twice" if defined?(Preloaded)

class Preloaded
  def self.value
    4
  end
end
