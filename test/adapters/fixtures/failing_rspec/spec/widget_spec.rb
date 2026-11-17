# frozen_string_literal: true

require "widget"

RSpec.describe Widget do
  it "passes" do
    expect(described_class.new.value).to eq(1)
  end

  it "fails" do
    expect(described_class.new.value).to eq(2)
  end
end
