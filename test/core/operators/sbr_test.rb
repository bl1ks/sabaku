# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support"

class SbrTest < Minitest::Test
  include CoreTestSupport

  DEF_TEXT = "def compute(a, b)\n  x = a + b\n  y = x * 2\n  y\nend\n"
  BLOCK_TEXT = "foo do\n  a\n  b\nend\n"

  def test_removes_each_statement_except_the_method_return_value
    built = source(DEF_TEXT)
    body = built.flat_nodes.grep(Prism::DefNode).first.body
    replacements = operator(:sbr).mutations(body, built)

    assert_equal 2, replacements.size
    assert_equal ["y = x * 2\n  y", "x = a + b\n  y"], replacements.map(&:replacement)
    assert(replacements.all? { |replacement| replacement.original == body.location.slice })
  end

  def test_splice_deletes_whole_lines_and_reparses
    built = source(DEF_TEXT)
    mutants = mutants_for(built, :sbr)

    assert_equal "def compute(a, b)\n  y = x * 2\n  y\nend\n", mutants[0].splice(DEF_TEXT)
    assert_equal "def compute(a, b)\n  x = a + b\n  y\nend\n", mutants[1].splice(DEF_TEXT)
    assert_mutants_parse(built, mutants)
  end

  def test_block_bodies_are_removable
    built = source(BLOCK_TEXT)
    mutants = mutants_for(built, :sbr)

    assert_equal 2, mutants.size
    assert_equal ["foo do\n  b\nend\n", "foo do\n  a\nend\n"],
                 mutants.map { |mutant| mutant.splice(BLOCK_TEXT) }
    assert_mutants_parse(built, mutants)
  end

  def test_file_body_is_not_a_removable_block
    # Deleting a top-level statement removes the library's entry point (a require, a class
    # definition), not a behaviour inside one. Those mutants either fail to load or survive
    # for a reason no reader can act on, so the file body is out of SBR's scope.
    text = "a = 1\nb = 2\n"
    built = source(text)

    assert_empty mutants_for(built, :sbr)
  end

  def test_inline_statement_lists_reparse
    text = "if x then a; b end\n"
    built = source(text)
    mutants = mutants_for(built, :sbr)

    assert_equal 2, mutants.size
    assert_equal ["if x then b end\n", "if x then a end\n"],
                 mutants.map { |mutant| mutant.splice(text) }
    assert_mutants_parse(built, mutants)
  end

  def test_declaration_bodies_are_not_removable
    # A mutation is applied by re-evaluating the file. Re-evaluation redefines a method but
    # never undefines one, so deleting a `def` from a class body cannot change behaviour: the
    # mutant would always survive and teach the reader nothing.
    text = "class Foo\n  def one\n    1\n  end\n\n  def two\n    2\n  end\nend\n"

    assert_empty mutants_for(source(text), :sbr)
  end

  def test_method_bodies_still_remove_statements
    text = "def total\n  a = 1\n  b = 2\n  a + b\nend\n"
    built = source(text)
    mutants = mutants_for(built, :sbr)

    assert_equal 2, mutants.size, "both non-final statements are removable"
    assert_equal [2, 3], mutants.map(&:line), "each mutant is reported on the line it removes"
    assert_mutants_parse(built, mutants)
  end

  def test_arid_statements_are_not_removed
    text = "class Foo\n  A = 1\n  B = 2\nend\n"
    assert_empty mutants_for(source(text), :sbr)
  end

  def test_single_statement_bodies_produce_nothing
    built = source("def one\n  work\nend\n")
    body = built.flat_nodes.grep(Prism::DefNode).first.body
    assert_empty operator(:sbr).mutations(body, built)
  end
end
