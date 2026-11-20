# frozen_string_literal: true

module Hostile
  # Release notes live inside this file, after __END__, the way a small CLI keeps its usage
  # text beside the code that prints it. Run the file directly and the notes arrive in DATA;
  # require it, as the suite does, and the same section is read back through __FILE__, so both
  # entry points print identical text.
  module Manual
    def self.notes
      lines = body.split("\n").map(&:strip).reject(&:empty?)
      lines
    end

    def self.body
      return DATA.read if defined?(DATA)

      File.read(__FILE__, encoding: "UTF-8").split(/^__END__\s*$/, 2).last.to_s
    end

    def self.headings
      notes.filter_map { |line| line.delete_prefix("# ") if line.start_with?("# ") }
    end

    def self.command?(line)
      return false if line.start_with?("#")

      line.include?(" ")
    end
  end
end
__END__
# install
gem install hostile

# usage
hostile run lib
