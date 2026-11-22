# frozen_string_literal: true

require_relative "sabaku/version"
require_relative "sabaku/errors"
require_relative "sabaku/config"
require_relative "sabaku/setup"
require_relative "sabaku/boot"
require_relative "sabaku/diff"
require_relative "sabaku/kills"
require_relative "sabaku/result"
require_relative "sabaku/kill_matrix"
require_relative "sabaku/source"
require_relative "sabaku/mutant"
require_relative "sabaku/operators/registry"
require_relative "sabaku/aridity"
require_relative "sabaku/analyzer"
require_relative "sabaku/coverage_map"
require_relative "sabaku/test_selection"
require_relative "sabaku/adapters/minitest"
require_relative "sabaku/fingerprint"
require_relative "sabaku/cache"
require_relative "sabaku/runner"
require_relative "sabaku/report"
require_relative "sabaku/packs"
require_relative "sabaku/cli"

# Mutation testing for Ruby test suites.
#
# A mutant is one source-level rewrite of one AST node. Running the tests that cover the
# mutated line decides whether the suite noticed, which is the whole measurement.
module Sabaku
end
