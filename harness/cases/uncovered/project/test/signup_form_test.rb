# frozen_string_literal: true

require "test_helper"

class SignupFormTest < Minitest::Test
  def test_email_is_required
    refute SignupForm.accept?({ nickname: "a" })
  end

  def test_nickname_is_optional
    assert SignupForm.accept?({ email: "a@example.com" })
  end

  def test_names_the_missing_field
    assert_equal [:email], SignupForm.missing({})
  end
end
