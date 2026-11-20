# frozen_string_literal: true

require "prism"
require_relative "replacement"
require_relative "support"
require_relative "aor"
require_relative "ror"
require_relative "lcr"
require_relative "sbr"
require_relative "uoi"
require_relative "bool"
require_relative "str"
require_relative "literal"
require_relative "selector"
require_relative "call"
require_relative "cond"
require_relative "assign"
require_relative "return"
require_relative "control"

module Sabaku
  module Operator
    # The operator catalog. Ids are stable API: configs, caches and reports all store them.
    module Registry
      OPERATORS = [Aor, Ror, Lcr, Sbr, Uoi, Bool, Str, Literal, Selector, Call, Cond, Assign, Return, Control].freeze

      # Every operator is on by default. Depth, not breadth, is what
      # --per-line controls, so the candidate pool should be the whole table.
      DEFAULTS = OPERATORS.map(&:id).freeze

      # The order a line spends its per-line budget in. Relational and conditional
      # replacements survive most often, literals and structural rewrites least, and a
      # fixed order means two runs on the same code keep the same mutant.
      PRODUCTIVITY = %i[ror lcr aor cond uoi bool literal str sbr selector call assign return control].freeze

      module_function

      def rank(id)
        PRODUCTIVITY.index(id.to_sym) || PRODUCTIVITY.length
      end

      def all
        OPERATORS
      end

      def ids
        OPERATORS.map(&:id)
      end

      def defaults
        DEFAULTS
      end

      def fetch(id)
        OPERATORS.find { |operator| operator.id == id.to_sym } ||
          raise(KeyError, "unknown mutation operator #{id.inspect}")
      end
    end
  end
end
