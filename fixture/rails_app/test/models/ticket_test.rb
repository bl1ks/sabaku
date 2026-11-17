# frozen_string_literal: true

require "test_helper"

class TicketTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Acme")
  end

  test "a new account has no open tickets" do
    assert_equal 0, Ticket.open_count(@account)
  end

  test "open tickets are counted" do
    @account.tickets.create!(subject: "printer", status: "open")
    @account.tickets.create!(subject: "vpn", status: "closed")

    assert_equal 1, Ticket.open_count(@account)
  end

  test "closing a ticket updates its status" do
    ticket = @account.tickets.create!(subject: "printer", status: "open")

    ticket.close!

    assert_equal "closed", ticket.reload.status
  end
end
