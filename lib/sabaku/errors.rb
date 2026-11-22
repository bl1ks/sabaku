# frozen_string_literal: true

module Sabaku
  # Raised when the tool cannot proceed: bad config, unreadable source, unusable adapter.
  class Error < StandardError; end

  # Raised when an operator claims a node but its replacement does not line up with the
  # source slice. Loud on purpose: a silent no-op mutant would report as survived.
  class OperatorError < Error; end

  # Raised when the suite is not green before any mutation is applied. Every
  # mutant a failing test covers would be reported as killed, so the campaign
  # cannot produce an honest score and stops here instead.
  class BaselineError < Error; end

  # Raised when a setup hook or a required boot file fails. The project asked
  # for that code to run, so the campaign stops instead of scoring without it.
  class BootError < Error; end

  # Raised when Coverage is already running without line counters (SimpleCov's oneshot
  # mode). Every file would read as uninstrumented, so sampling stops instead.
  class CoverageError < Error; end
end
