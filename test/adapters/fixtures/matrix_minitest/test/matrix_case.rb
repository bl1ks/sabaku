# frozen_string_literal: true

require "minitest/autorun"
require "matrix_calc"

# One test per kill-matrix verdict. Under `a + b -> a * b` the first failure is test_add_strong,
# and test_add_wait, which sorts after it, hangs: the sweep times out while the kill stands.
class MatrixTest < Minitest::Test
  def test_add_strong
    assert_equal 5, MatrixCalc.add(2, 3)
  end

  def test_add_twin
    assert_equal 5, MatrixCalc.add(2, 3)
  end

  def test_add_wait
    sleep 60 if MatrixCalc.add(2, 3) == 6
    assert true
  end

  def test_add_weak
    assert_equal 4, MatrixCalc.add(2, 2)
  end

  def test_label_smoke
    MatrixCalc.label(1)
  end

  def test_sub_only
    assert_equal 1, MatrixCalc.sub(3, 2)
  end

  def test_untouched
    assert true
  end
end
