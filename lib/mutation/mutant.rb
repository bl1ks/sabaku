# frozen_string_literal: true

require "digest"

module Mutation
  # A single source-level rewrite: replace [start_offset, end_offset) with #replacement.
  # Offsets travel with the mutant so it can round trip through JSON without the Source.
  Mutant = Data.define(
    :id,
    :path,
    :operator,
    :line,
    :column,
    :node_kind,
    :original,
    :replacement,
    :start_offset,
    :end_offset
  ) do
    def initialize(id: nil, path:, operator:, line:, column:, node_kind:, original:, replacement:,
                   start_offset:, end_offset:)
      computed = id || Digest::SHA1.hexdigest(
        "#{path}\0#{start_offset}\0#{end_offset}\0#{replacement}"
      )[0, 16]
      super(
        id: computed,
        path: path,
        operator: operator,
        line: line,
        column: column,
        node_kind: node_kind,
        original: original,
        replacement: replacement,
        start_offset: start_offset,
        end_offset: end_offset
      )
    end

    def splice(text)
      spliced = text.dup
      spliced.bytesplice(start_offset, end_offset - start_offset, replacement)
      spliced
    end

    def description
      "#{operator.to_s.upcase}: #{original} -> #{replacement}"
    end
  end
end
