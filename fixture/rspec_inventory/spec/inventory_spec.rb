# frozen_string_literal: true

require "inventory"

RSpec.describe Warehouse::Inventory do
  subject(:inventory) { described_class.new(10) }

  it "reports what is available" do
    expect(inventory.available).to eq(10)
  end

  it "accepts a reservation that fits" do
    expect(inventory.reserve(4)).to be(true)
    expect(inventory.available).to eq(6)
  end

  it "rejects a reservation larger than the stock" do
    expect(inventory.reserve(11)).to be(false)
  end

  it "restocks" do
    expect(inventory.restock(5)).to eq(15)
  end

  it "releases at most what is reserved" do
    inventory.reserve(6)
    expect(inventory.release(9)).to eq(6)
  end
end
