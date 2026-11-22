# frozen_string_literal: true

# A class-body DSL, the shape of dry-validation's `params do ... end`: the call runs once,
# while the file loads, and no test executes its line again.
class Form
  def self.field(name, required: false)
    own_fields[name] = required
  end

  def self.own_fields
    @own_fields ||= {}
  end

  def self.missing(input)
    own_fields.select { |name, required| required && input[name].nil? }.keys
  end
end
