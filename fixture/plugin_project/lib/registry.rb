# frozen_string_literal: true

# A registry filled at load time. Loading plugin.rb twice adds a second entry,
# which is exactly what fork isolation does to every mutant.
module Registry
  def self.entries
    @entries ||= []
  end

  def self.add(entry)
    entries << entry
  end
end
