# frozen_string_literal: true

module Mutation
  # Turns a git revision into the line ranges that changed since it, which is
  # what `--since` feeds to the analyzer. No git library: one `git diff` call
  # and a parser over unified diff headers, so the only contract is the diff
  # format itself.
  module Diff
    HUNK = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/
    NEW_FILE = %r{\A\+\+\+ (?:b/)?(.+?)\r?\n?\z}

    module_function

    # { "lib/a.rb" => [Range, ...] }, paths relative to +root+. Empty when the
    # revision changed no tracked file under the current directory.
    def git_ranges(rev, root: Dir.pwd, paths: [])
      unless git_repository?(root)
        raise Mutation::Error, "--since needs a git repository, and #{root} is not one"
      end

      args = ["git", "-C", root, "diff", "-U0", "--no-color", "--no-ext-diff",
              "--relative", rev, "--", *Array(paths)]
      output = IO.popen(args, err: [:child, :out], &:read)
      unless $?.success?
        raise Mutation::Error, "git diff #{rev} failed: #{output.strip.lines.first&.strip}"
      end

      parse(output)
    end

    def git_repository?(root)
      system("git", "-C", root, "rev-parse", "--git-dir",
             out: File::NULL, err: File::NULL)
    end

    def parse(text)
      ranges = {}
      path = nil
      text.each_line do |line|
        if (match = NEW_FILE.match(line))
          path = unquote(match[1]).sub(%r{\Ab/}, "")
        elsif path && (match = HUNK.match(line))
          start = Integer(match[1])
          count = match[2].nil? ? 1 : Integer(match[2])
          next if count.zero?

          (ranges[path] ||= []) << (start..(start + count - 1))
        end
      end
      ranges
    end

    # Both filters must cover a line for it to be mutated.
    def intersect(left, right)
      return left if right.nil?
      return right if left.nil?

      (left.keys & right.keys).to_h do |path|
        [path, left[path].product(right[path]).filter_map { |a, b| overlap(a, b) }]
      end
    end

    def overlap(left, right)
      first = [left.begin, right.begin].max
      last = [left.end, right.end].min
      return nil if first > last

      first..last
    end

    def unquote(path)
      return path unless path.start_with?('"') && path.end_with?('"')

      path[1..-2].gsub(/\\(.)/) { Regexp.last_match(1) }
    end
  end
end
