# frozen_string_literal: true

class Account < ApplicationRecord
  has_many :tickets, dependent: :destroy

  def open_tickets
    tickets.open.to_a
  end
end
