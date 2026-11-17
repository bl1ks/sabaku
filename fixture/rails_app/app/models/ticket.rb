# frozen_string_literal: true

class Ticket < ApplicationRecord
  belongs_to :account

  scope :open, -> { where(status: "open") }

  def self.open_count(account)
    account.tickets.open.count
  end

  def close!
    update!(status: "closed")
  end
end
