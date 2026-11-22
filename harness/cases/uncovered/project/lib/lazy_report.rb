# frozen_string_literal: true

# Required inside one test method, not by the helper.
module LazyReport
  def self.summary(values)
    values.sum / values.size
  end

  def self.peak(values)
    values.max - values.min
  end
end
