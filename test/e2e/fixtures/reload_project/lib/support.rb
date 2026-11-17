# frozen_string_literal: true

module Chain
  module Support
    def self.allowed?(value)
      value < 100
    end
  end
end
