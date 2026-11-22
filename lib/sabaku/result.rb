# frozen_string_literal: true

require_relative "kills"

module Sabaku
  # What happened to one mutant. `duration` is wall time inside the child, in seconds.
  # `kills` is the mutant's full row of the kill graph, present only under --kill-matrix and
  # only when every selected test ran to a verdict.
  Result = Data.define(:mutant, :status, :duration, :failed_test, :message, :reason, :kills)

  class Result
    STATUSES = %i[killed survived timeout error uncovered skipped].freeze
    # Why a mutant ended in its status, one closed set per status. The report groups by
    # these, never by the message, which is for people. nil stays legal on every status:
    # a cached or library-built result may predate the classification.
    #
    #   survived  not_detected: a covering test saw the changed value and still passed;
    #             not_infected: no covering test saw a change at all
    #   skipped   fail_fast: --fail-fast stopped before it was scheduled;
    #             mutation_unloadable: the unmutated file reloads, the mutated one does not;
    #             suite_unloadable: the first-load surface could not boot with it
    #   timeout   deadline: the parent killed the child at its deadline
    #   error     environment_crash: the child died of a signal before its deadline;
    #             unverified_kill: the killing test fails with no mutation applied;
    #             harness: the child or the runner failed outside the tests
    REASONS = {
      killed: [],
      survived: %i[not_detected not_infected],
      timeout: %i[deadline],
      error: %i[environment_crash unverified_kill harness],
      uncovered: [],
      skipped: %i[fail_fast mutation_unloadable suite_unloadable]
    }.transform_values(&:freeze).freeze

    def initialize(mutant:, status:, duration: 0.0, failed_test: nil, message: nil, reason: nil,
                   kills: nil)
      raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

      reason = reason&.to_sym
      unless reason.nil? || REASONS.fetch(status).include?(reason)
        raise ArgumentError, "unknown reason #{reason.inspect} for #{status}"
      end

      check_kills(status, failed_test, kills) unless kills.nil?

      super(
        mutant: mutant,
        status: status,
        duration: Float(duration),
        failed_test: failed_test,
        message: message,
        reason: reason,
        kills: kills
      )
    end

    def killed? = status == :killed
    def survived? = status == :survived
    def counted? = %i[killed survived timeout].include?(status)
    def uncovered? = status == :uncovered

    def skipped? = status == :skipped

    # Adding a row can never move a status.
    def with_kills(kills)
      self.class.new(mutant: mutant, status: status, duration: duration, failed_test: failed_test,
                     message: message, reason: reason, kills: kills)
    end

    def to_h
      hash = {
        mutant: mutant.to_h,
        status: status,
        duration: duration,
        failed_test: failed_test,
        message: message,
        reason: reason
      }
      hash[:kills] = kills.to_h if kills
      hash
    end

    private

    def check_kills(status, failed_test, kills)
      raise ArgumentError, "kills must be a Kills, got #{kills.class}" unless kills.is_a?(Kills)

      case status
      when :killed
        raise ArgumentError, "a killed row needs a killer" unless kills.killed?
        if failed_test && !kills.killers.include?(failed_test.to_s)
          raise ArgumentError, "failed_test #{failed_test.inspect} is not among the killers"
        end
      when :survived
        raise ArgumentError, "a survivor's row has no killers" if kills.killed?
      else
        raise ArgumentError, "a #{status} result has no kill row"
      end
    end
  end
end
