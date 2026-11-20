# frozen_string_literal: true

require "minitest/autorun"
require "hostile/manual"

class HostileManualTest < Minitest::Test
  def test_notes_come_from_the_section_after_end
    assert_equal ["# install", "gem install hostile", "# usage", "hostile run lib"],
                 Hostile::Manual.notes
  end

  def test_headings_drop_the_comment_marker
    assert_equal %w[install usage], Hostile::Manual.headings
  end

  def test_command_lines_are_the_ones_with_a_space
    assert Hostile::Manual.command?("gem install hostile")
    refute Hostile::Manual.command?("# install")
    refute Hostile::Manual.command?("usage")
  end
end
