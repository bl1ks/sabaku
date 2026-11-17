# frozen_string_literal: true

require_relative "lib/mutation/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-mutation"
  spec.version = Mutation::VERSION
  spec.authors = ["kyusu"]
  spec.summary = "Mutation testing for minitest and rspec, diff-based and coverage-guided"
  spec.description = <<~DESC
    Mutates individual AST nodes of your Ruby source, then runs only the tests that cover the
    mutated line. Follows the diff-based, arid-node-suppressed approach described in
    "State of Mutation Testing at Google" (Petrovic & Ivankovic, ICSE-SEIP 2018).
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "bin/*", "docs/*.md", "README.md"]
  spec.bindir = "bin"
  spec.executables = ["mutation"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", ">= 5.16"
  spec.add_development_dependency "rspec", ">= 3.10"
end
