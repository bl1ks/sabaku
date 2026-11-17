# frozen_string_literal: true

module Mutation
  # What happened to one mutant. `duration` is wall time inside the child, in seconds.
  Result = Data.define(:mutant, :status, :duration, :failed_test, :message) do
    STATUSES = %i[killed survived timeout error uncovered].freeze

    def initialize(mutant:, status:, duration: 0.0, failed_test: nil, message: nil)
      raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

      super(
        mutant: mutant,
        status: status,
        duration: Float(duration),
        failed_test: failed_test,
        message: message
      )
    end

    def killed? = status == :killed
    def survived? = status == :survived
    def counted? = %i[killed survived timeout].include?(status)
    def uncovered? = status == :uncovered

    def to_h
      {
        mutant: mutant.to_h,
        status: status,
        duration: duration,
        failed_test: failed_test,
        message: message
      }
    end
  end
end
