# frozen_string_literal: true

module Mutation
  # What happened to one mutant. `duration` is wall time inside the child, in seconds.
  Result = Data.define(:mutant, :status, :duration, :failed_test, :message, :reason) do
    STATUSES = %i[killed survived timeout error uncovered skipped].freeze
    # Why a survivor survived. `not_detected` means a covering test saw the changed
    # value and still passed; `not_infected` means no covering test saw a change at all.
    REASONS = %i[not_detected not_infected].freeze

    def initialize(mutant:, status:, duration: 0.0, failed_test: nil, message: nil, reason: nil)
      raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

      reason = reason&.to_sym
      raise ArgumentError, "unknown reason #{reason.inspect}" unless reason.nil? || REASONS.include?(reason)

      super(
        mutant: mutant,
        status: status,
        duration: Float(duration),
        failed_test: failed_test,
        message: message,
        reason: reason
      )
    end

    def killed? = status == :killed
    def survived? = status == :survived
    def counted? = %i[killed survived timeout].include?(status)
    def uncovered? = status == :uncovered

    def skipped? = status == :skipped

    def to_h
      {
        mutant: mutant.to_h,
        status: status,
        duration: duration,
        failed_test: failed_test,
        message: message,
        reason: reason
      }
    end
  end
end
