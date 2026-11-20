# encoding: utf-8

module Hostile
  # Labels for the release report. The comments and strings here carry real UTF-8 —
  # 進捗, naïve, and an emoji — because a report printed in Japanese is not ASCII and a
  # mutator that assumes one byte per character will splice in the wrong place.
  module Labels
    EMOJI = "🎉"
    GREETING = "こんにちは"

    def self.title(name)
      "#{GREETING}, #{name} #{EMOJI}"
    end

    def self.fit(name, width)
      text = title(name)
      text.length > width ? "#{text[0, width - 1]}…" : text
    end

    def self.blank?(text)
      text.nil? || text.strip.empty?
    end
  end
end
