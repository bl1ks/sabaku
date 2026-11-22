# frozen_string_literal: true

require "form"

class SignupForm < Form
  field :email, required: true
  field :nickname, required: false

  def self.accept?(input)
    missing(input).empty?
  end
end
