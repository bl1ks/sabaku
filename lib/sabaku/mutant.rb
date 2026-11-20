# frozen_string_literal: true

require "digest"

module Sabaku
  # A single source-level rewrite: replace [start_offset, end_offset) with #replacement.
  #
  # Identity is position independent: the id hashes the file, the enclosing scope, the
  # node's path inside that scope, the operator and the replacement. Moving a method down
  # a file keeps its mutants' ids, so a cache entry survives the move. Offsets still
  # travel with the mutant because it must round trip through JSON without the Source.
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
    :end_offset,
    :scope,
    :ast_path,
    :weak
  ) do
    def initialize(id: nil, path:, operator:, line:, column:, node_kind:, original:, replacement:,
                   start_offset:, end_offset:, scope: "top", ast_path: "", weak: false)
      computed = id || Digest::SHA1.hexdigest(
        "#{path}\0#{scope}\0#{ast_path}\0#{operator}\0#{replacement}"
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
        end_offset: end_offset,
        scope: scope,
        ast_path: ast_path,
        weak: weak ? true : false
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

    # The stable coordinates the cache groups by. Two mutants with the same key describe
    # the same edit in the same function, however far the function has moved.
    def key
      [path, scope, ast_path, operator.to_s, replacement]
    end
  end
end
