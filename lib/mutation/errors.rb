# frozen_string_literal: true

module Mutation
  # Raised when the tool cannot proceed: bad config, unreadable source, unusable adapter.
  class Error < StandardError; end

  # Raised when an operator claims a node but its replacement does not line up with the
  # source slice. Loud on purpose: a silent no-op mutant would report as survived.
  class OperatorError < Error; end
end
