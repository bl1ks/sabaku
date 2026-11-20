# frozen_string_literal: true

# Counts its own loads, so a fork child, which evaluates the file a second time, fails
# test_b_loaded_once whatever the mutation is.
module LoadCounter
  @loads = (@loads || 0) + 1

  def self.loads
    @loads
  end

  def self.value
    42
  end
end
