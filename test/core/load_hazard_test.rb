# frozen_string_literal: true

require_relative "../test_helper"

class LoadHazardTest < Minitest::Test
  def sensitive?(text)
    Mutation::LoadHazard.sensitive?(Prism.parse(text).value)
  end

  def test_a_class_of_definitions_runs_nothing_at_load_time
    refute sensitive?("class Foo\n  def bar\n    1\n  end\nend\n")
  end

  def test_idempotent_decorators_are_not_hazards
    refute sensitive?(<<~RUBY)
      class Foo
        include Comparable
        attr_reader :value
        private

        def initialize(value)
          @value = value
        end
      end
    RUBY
  end

  def test_a_plain_frozen_constant_is_not_a_hazard
    refute sensitive?("SCOPES = %w[a b].freeze\n")
    refute sensitive?("ALIAS = Other\n")
  end

  def test_a_registration_at_class_body_is_a_hazard
    assert sensitive?("class Plugin\n  Registry.add(:plugin)\nend\n")
  end

  def test_a_top_level_call_is_a_hazard
    assert sensitive?("require_relative \"boot\"\nRegistry.add(:plugin)\n")
  end

  def test_building_a_class_in_a_constant_is_a_hazard
    assert sensitive?("Point = Struct.new(:x, :y)\n")
    assert sensitive?("Entry = Data.define(:name)\n")
    assert sensitive?("class Point < Struct.new(:x)\nend\n")
  end

  def test_a_framework_decorator_that_is_a_call_is_a_hazard
    assert sensitive?("class Account < ApplicationRecord\n  belongs_to :user\nend\n")
  end

  def test_a_missing_tree_is_not_a_hazard
    refute Mutation::LoadHazard.sensitive?(nil)
  end
end
