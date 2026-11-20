# frozen_string_literal: true

module Hostile
  # The lookup table is computed when the file loads, from a fetch that has to find its key.
  # A mutant that drops the argument, or the receiver, turns a working constant into an
  # exception at require time: the mutant never runs, so it has to be reported as
  # unmeasured rather than as a kill.
  module Table
    Lookup = { a: 1 }.fetch(:a)

    def self.value
      Lookup
    end

    def self.describe
      value + 1
    end
  end
end
