# frozen_string_literal: true

class Eager
  def self.rules
    @rules ||= []
  end

  def self.rule(name)
    rules << name
  end

  rule :positive

  def self.check(value)
    value.positive?
  end

  def self.untested
    1
  end
end
