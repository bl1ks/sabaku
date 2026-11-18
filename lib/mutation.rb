# frozen_string_literal: true

require_relative "mutation/version"
require_relative "mutation/errors"
require_relative "mutation/config"
require_relative "mutation/setup"
require_relative "mutation/boot"
require_relative "mutation/diff"
require_relative "mutation/result"
require_relative "mutation/source"
require_relative "mutation/mutant"
require_relative "mutation/operators/registry"
require_relative "mutation/aridity"
require_relative "mutation/analyzer"
require_relative "mutation/coverage_map"
require_relative "mutation/adapters/base"
require_relative "mutation/adapters/minitest"
require_relative "mutation/adapters/rspec"
require_relative "mutation/fingerprint"
require_relative "mutation/cache"
require_relative "mutation/runner"
require_relative "mutation/report"
require_relative "mutation/cli"

# Mutation testing for Ruby test suites.
#
# A mutant is one source-level rewrite of one AST node. Running the tests that cover the
# mutated line decides whether the suite noticed, which is the whole measurement.
module Mutation
end
