# frozen_string_literal: true

# A file whose second evaluation raises, like Active Support's configurable.rb,
# which warns at load time under a suite that raises deprecation warnings.
module Hostile
  @loads = (@loads || 0) + 1
  raise "hostile loaded #{@loads} times" if @loads > 1

  def self.value
    42
  end
end
