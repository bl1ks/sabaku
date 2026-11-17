# frozen_string_literal: true

module Mutation
  module Operator
    # One candidate rewrite of a node. `original` must equal the node's source slice; the
    # Analyzer refuses to build a Mutant when it does not.
    Replacement = Data.define(:original, :replacement)
  end
end
