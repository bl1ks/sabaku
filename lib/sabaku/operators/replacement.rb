# frozen_string_literal: true

module Sabaku
  module Operator
    # One candidate rewrite of a node. `original` must equal the node's source slice; the
    # Analyzer refuses to build a Mutant when it does not.
    #
    # `line` is the line the mutant is reported and counted against, and it defaults to the
    # node's first line. SBR overrides it with the line of the statement it removes, because
    # the paper's one-mutant-per-line rule is about mutation sites, not about block headers.
    Replacement = Data.define(:original, :replacement, :line) do
      def initialize(original:, replacement:, line: nil)
        super(original: original, replacement: replacement, line: line)
      end
    end
  end
end
