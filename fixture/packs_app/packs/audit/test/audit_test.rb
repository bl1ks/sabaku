# frozen_string_literal: true

require "minitest/autorun"

# packs/audit does not depend on packs/ledger, so a ledger campaign never loads this.
class AuditTest < Minitest::Test
  def test_unrelated
    assert_equal 2, 1 + 1
  end
end
