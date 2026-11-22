# frozen_string_literal: true

require "test_helper"

class LazyReportTest < Minitest::Test
  def test_summary
    require "lazy_report"
    assert_equal 2, LazyReport.summary([1, 2, 3])
  end
end
