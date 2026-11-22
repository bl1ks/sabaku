# frozen_string_literal: true

require_path "./config/boot_marker"
after_boot { $sabaku_after_boot = true }
