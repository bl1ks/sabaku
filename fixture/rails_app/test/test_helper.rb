# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  if ENV["SABAKU_DB"] == "mysql"
    # Transactional fixtures would hide the per-child clone: a shared database
    # also passes when every test rolls back. Each child gets its own copy, so
    # clear the tables between tests instead.
    self.use_transactional_tests = false

    setup do
      # Tickets reference accounts, so empty the referencing table first.
      [Ticket, Account].each do |model|
        ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{model.table_name}")
      end
    end
  else
    # Transactional fixtures keep every test's writes to itself; the mutation
    # children share one test database file, so this is what makes a forked
    # campaign safe without per-child database copies.
    self.use_transactional_tests = true
  end

  if ENV["SABAKU_DB_LOG"]
    # test/e2e/mysql_test.rb reads this to see which database each child used.
    setup do
      File.open(ENV.fetch("SABAKU_DB_LOG"), "a") do |file|
        file.puts(ActiveRecord::Base.connection_db_config.database)
      end
    end
  end
end
