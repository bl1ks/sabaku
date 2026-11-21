# frozen_string_literal: true

module Sabaku
  # One mutant's row of the kill graph: the tests that ran against it, and the ones that failed.
  # A row exists only when every test in `tested` ran to a verdict, so a mutant whose sweep did
  # not finish has no row rather than a partial one.
  Kills = Data.define(:tested, :killers) do
    def initialize(tested:, killers:)
      tested = Array(tested).map(&:to_s).uniq.sort.freeze
      killers = Array(killers).map(&:to_s).uniq.sort.freeze
      stray = killers - tested
      raise ArgumentError, "killers outside tested: #{stray.inspect}" unless stray.empty?

      super(tested: tested, killers: killers)
    end

    def killed? = !killers.empty?

    def to_h = { tested: tested, killers: killers }
  end
end
