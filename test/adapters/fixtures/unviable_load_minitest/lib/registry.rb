# frozen_string_literal: true

class Registry
  class << self
    def add(name, value)
      entries[name] = value
    end

    def entries
      @entries ||= {}
    end

    def find(name)
      entries[name]
    end
  end

  # A registration at load time, like ActiveSupport::Editor's built-in editors.
  add "answer", 42
end
