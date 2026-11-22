# frozen_string_literal: true

# Loads only once the boot is complete, as a Rails file that needs an initializer does.
raise "the setup's require_path did not run" unless $sabaku_required_path
raise "after_boot has not run" unless $sabaku_after_boot

class Booted
  def self.value
    1
  end
end
