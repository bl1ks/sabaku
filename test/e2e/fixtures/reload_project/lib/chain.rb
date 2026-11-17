# frozen_string_literal: true

require_relative "support"

module Chain
  # A multi-line boolean chain: Ruby's line coverage reports the first and last line of
  # such an expression and nothing in between, which is the case the runner's statement-span
  # fallback exists for.
  class Gate
    def initialize(value)
      @value = value
    end

    def open?
      @value.positive? &&
        @value.even? &&
        Support.allowed?(@value)
    end
  end
end
