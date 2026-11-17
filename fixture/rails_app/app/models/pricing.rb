# frozen_string_literal: true

class Pricing
  def tier(volume)
    if volume >= 5
      :bulk
    else
      :single
    end
  end

  def label(volume)
    volume > 10 ? "bulk" : "single"
  end
end
