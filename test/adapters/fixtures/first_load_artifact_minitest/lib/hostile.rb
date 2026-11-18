# frozen_string_literal: true

# A file that loads once but not twice, like Active Support's configurable.rb.
# The mutation is visible to the test; the second load is not.
module Hostile
  @loads = (@loads || 0) + 1
  raise "hostile loaded #{@loads} times" if @loads > 1

  def self.loads
    @loads
  end

  def self.value
    42
  end
end
