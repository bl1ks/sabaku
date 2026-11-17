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

module Mutation
  module Operator
    # The operator catalog. Ids are stable API: configs, caches and reports all store them.
    module Registry
      OPERATORS = [Aor, Ror, Lcr, Sbr, Uoi, Bool, Str].freeze
      DEFAULTS = %i[aor ror lcr sbr uoi].freeze

      module_function

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
