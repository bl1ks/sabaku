# frozen_string_literal: true

require "minitest/autorun"
require "hostile/labels"

class HostileLabelsTest < Minitest::Test
  def test_title_is_the_utf8_greeting_plus_the_name_and_the_emoji
    assert_equal "こんにちは, Ada 🎉", Hostile::Labels.title("Ada")
  end

  def test_title_is_valid_utf8
    assert Hostile::Labels.title("Ada").valid_encoding?
  end

  def test_fit_keeps_a_title_that_fits
    text = Hostile::Labels.title("Ada")
    assert_equal text, Hostile::Labels.fit("Ada", text.length)
  end

  def test_fit_truncates_to_the_width_and_ends_with_the_ellipsis
    text = Hostile::Labels.title("Ada")
    shortened = Hostile::Labels.fit("Ada", text.length - 1)
    assert_equal text.length - 1, shortened.length
    assert shortened.end_with?("…")
    refute_equal text, shortened
  end

  def test_blank_detects_nil_and_whitespace
    assert Hostile::Labels.blank?(nil)
    assert Hostile::Labels.blank?(" \t")
    refute Hostile::Labels.blank?("x")
  end
end
