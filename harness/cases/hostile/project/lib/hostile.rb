# frozen_string_literal: true

module Hostile
  # The entry point: the lookup table is optional, so it is loaded on first use instead of at
  # require time. The test that touches the constant is therefore the thing that executes the
  # table's load-time fetch, which is the honest place to attribute its coverage.
  autoload :Table, "hostile/table"
end
