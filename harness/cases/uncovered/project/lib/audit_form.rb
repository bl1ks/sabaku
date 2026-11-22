# frozen_string_literal: true

require "form"

# Loaded by the test helper, reached by no test.
class AuditForm < Form
  field :actor, required: true

  def self.accept?(input)
    missing(input).empty? && input[:actor].to_s.length > 2
  end
end
