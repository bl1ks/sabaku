# frozen_string_literal: true

class Till
  def self.total(prices, tip = 0)
    prices.sum + tip
  end

  def self.discount(total, percent)
    total - (total * percent / 100)
  end

  def self.change(paid, due)
    return 0 if paid < due

    paid - due
  end
end
