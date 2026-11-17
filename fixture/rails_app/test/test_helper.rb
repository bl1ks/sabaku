# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  # Transactional fixtures keep every test's writes to itself; the mutation
  # children share one test database file, so this is what makes a forked
  # campaign safe without per-child database copies.
  self.use_transactional_tests = true
end
