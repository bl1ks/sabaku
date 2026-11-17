# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class LiteralTest < Minitest::Test
  include CoreTestSupport

  def replacements(text)
    built = source(text)
    mutants_for(built, :literal).map { |mutant| mutant.splice(text) }
  end

  def test_integers_step_by_one
    assert_equal ["x = 0\n", "x = 2\n"], replacements("x = 1\n").sort
  end

  def test_negative_integers_step_outward
    assert_equal ["x = -2\n", "x = 0\n"], replacements("x = -1\n").sort
  end

  def test_floats_step_by_one
    assert_equal ["x = 0.5\n", "x = 2.5\n"], replacements("x = 1.5\n").sort
  end

  def test_non_empty_array_and_hash_collapse
    assert_includes replacements("x = [1, 2]\n"), "x = []\n"
    assert_includes replacements("x = { a: 1 }\n"), "x = {}\n"
  end

  def test_empty_and_bare_literals_are_skipped
    assert_empty replacements("x = []\n")
    assert_empty replacements("x = {}\n")
    assert_empty replacements("a, b = 1, 2\n").select { |text| text.include?("= ,") }
  end

  def test_every_replacement_parses
    %w[1 1.5 [1] {a:\ 1} 0x10 1..2].each do |literal|
      built = source("x = #{literal}\n")
      assert_mutants_parse(built, mutants_for(built, :literal))
    end
  end
end
