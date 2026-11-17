# frozen_string_literal: true

# Every default and opt-in operator has a site here. `formal/replay/emit.rb` analyses this file
# and `formal/replay/check.rb` checks the resulting mutant list against the contract.
module KitchenSink
  LIMIT = 10

  def self.decide(a, b, flag)
    total = a + b
    total = total * 2 if flag
    total -= 1 unless a > b
    while total < LIMIT
      total += 1
    end
    name = "widget"
    label = a == b ? "same" : name
    enabled = true && !false
    [total, label, enabled]
  end

  def self.names(records)
    records.map { |record| record[:name] }.select { |name| name }.first
  end

  def self.shift(value)
    value << 1
  end

  def self.clamp(value)
    value > LIMIT || value < 0 ? LIMIT : value
  end
end
