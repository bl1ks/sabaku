# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support"

class AridityTest < Minitest::Test
  include CoreTestSupport

  def setup
    @aridity = Sabaku::Aridity.new
  end

  def arid?(source, type, name: nil)
    node, ancestors = find_node(source, type, name: name)
    @aridity.arid?(node, ancestors)
  end

  def top_level_calls(source)
    source.ast.statements.body.grep(Prism::CallNode)
  end

  def test_output_calls_are_arid
    text = <<~RUBY
      puts "log"
      print "log"
      p 1
      pp 2
      warn "warning"
      printf("%s", 1)
      $stdout.write("out")
      $stderr.puts("err")
      Kernel.puts("kernel")
    RUBY
    built = source(text)
    ancestors = [built.ast, built.ast.statements]

    assert_equal 9, top_level_calls(built).size
    top_level_calls(built).each do |call|
      assert @aridity.arid?(call, ancestors), "expected #{call.name.inspect} to be arid"
    end
  end

  def test_logger_receivers_are_arid
    text = <<~RUBY
      logger.info "hi"
      @logger.warn "hi"
      Rails.logger.info "hi"
      ActiveSupport::Logger.new($stdout).info "hi"
    RUBY
    built = source(text)

    top_level_calls(built).each do |call|
      assert @aridity.arid?(call, [built.ast, built.ast.statements]),
             "expected #{call.slice} to be arid"
    end
  end

  def test_non_logger_receiver_is_not_arid
    built = source("object.info \"hi\"\n")
    refute arid?(built, Prism::CallNode, name: :info)
  end

  def test_require_and_load_calls_are_arid
    built = source("require \"json\"\nrequire_relative \"x\"\nload \"x.rb\"\nautoload :Foo, \"foo\"\n")

    assert_equal 4, top_level_calls(built).size
    top_level_calls(built).each do |call|
      assert @aridity.arid?(call, [built.ast, built.ast.statements])
    end
  end

  def test_declaration_calls_are_arid
    text = <<~RUBY
      attr_accessor :a
      attr_reader :b
      attr_writer :c
      include Comparable
      extend Enumerable
      prepend Kernel
      private
      protected
      public
      module_function
      alias_method :new_name, :old_name
      using Refinement
    RUBY
    built = source(text)

    assert_equal 12, top_level_calls(built).size
    top_level_calls(built).each do |call|
      assert @aridity.arid?(call, [built.ast, built.ast.statements]),
             "expected #{call.name.inspect} to be arid"
    end
  end

  def test_uppercase_constant_assignment_is_arid
    built = source("MAX_RETRIES = 3\nDEFAULT_NAME = \"x\"\nLimits::MAX = 3\nlower = 3\n")

    assert arid?(built, Prism::ConstantWriteNode)
    assert_equal 2, built.flat_nodes.grep(Prism::ConstantWriteNode).size
    assert arid?(built, Prism::ConstantPathWriteNode)
    refute arid?(built, Prism::LocalVariableWriteNode)
  end

  def test_initialize_body_that_only_assigns_ivars_is_arid
    built = source("def initialize(value)\n  @value = value\n  @ready = true\nend\n")
    definition = built.flat_nodes.grep(Prism::DefNode).first
    body = definition.body

    assert @aridity.arid?(definition, [built.ast, built.ast.statements])
    assert @aridity.arid?(body, [built.ast, built.ast.statements, definition])
  end

  def test_initialize_with_other_work_is_not_arid
    built = source("def initialize(value)\n  @value = value\n  validate!\nend\n")

    refute arid?(built, Prism::DefNode, name: :initialize)
  end

  def test_suppressed_definition_names_are_arid
    names = %i[to_s inspect hash == eql? <=> method_missing respond_to_missing?]
    names.each do |name|
      built = source("def #{name}(other)\n  other\nend\n")
      assert arid?(built, Prism::DefNode, name: name), "expected def #{name} to be arid"
    end
  end

  def test_nodes_inside_suppressed_definitions_are_arid
    built = source(%q{def to_s
  "rendered"
end
})
    string = built.flat_nodes.grep(Prism::StringNode).first
    _, ancestors = find_node(built, Prism::StringNode)

    assert @aridity.arid?(string, ancestors)
  end

  def test_string_and_symbol_arguments_of_suppressed_calls_are_arid
    built = source("puts \"hello\"\nattr_reader :items\nlog(\"plain\")\nmark(:sym)\n")

    hello, hello_ancestors = find_node(built, Prism::StringNode)
    assert_equal "\"hello\"", hello.location.slice
    assert @aridity.arid?(hello, hello_ancestors)

    items = built.flat_nodes.grep(Prism::SymbolNode).find { |node| node.slice == ":items" }
    _, items_ancestors = find_node(built, Prism::SymbolNode)
    assert @aridity.arid?(items, items_ancestors)

    plain = built.flat_nodes.grep(Prism::StringNode).find { |node| node.slice == "\"plain\"" }
    _, plain_ancestors = find_node(built, Prism::StringNode, name: nil)
    at_plain = nil
    each_node_with_ancestors(built) { |node, ancestors| at_plain = [node, ancestors] if node.equal?(plain) }
    refute @aridity.arid?(plain, at_plain.last)

    symbol = built.flat_nodes.grep(Prism::SymbolNode).find { |node| node.slice == ":sym" }
    at_symbol = nil
    each_node_with_ancestors(built) { |node, ancestors| at_symbol = [node, ancestors] if node.equal?(symbol) }
    refute @aridity.arid?(symbol, at_symbol.last)
  end

  def test_comment_and_blank_only_sources_have_no_nodes
    built = source("\n# just a comment\n   \n# frozen_string_literal: true\n")

    assert(built.flat_nodes.all? { |node| node.is_a?(Prism::StatementsNode) })
    assert_empty analyze(built)
  end

  def test_magic_values_and_freeze_calls_are_arid
    built = source("__FILE__\n__dir__\n__method__\nvalue.freeze\nvalue.frozen?\n")

    assert arid?(built, Prism::SourceFileNode)
    %i[__dir__ __method__ freeze frozen?].each do |name|
      assert arid?(built, Prism::CallNode, name: name), "expected #{name} to be arid"
    end
  end

  def test_magic_comment_line_is_ignored_but_code_still_mutates
    built = source("# frozen_string_literal: true\n\nvalue = true\n")
    mutants = analyze(built, operators: [:bool])

    assert_equal [3], mutants.map(&:line).uniq
  end

  def test_condition_guarded_log_is_arid
    bodies = [
      'puts "debug"',
      'logger.info "debug"',
      '$stdout.puts "debug"',
      'warn "debug"'
    ]
    bodies.each do |body|
      built = source("if ENV[\"DEBUG\"]\n  #{body}\nend\n")
      definition = built.ast.statements.body.first
      assert @aridity.arid?(definition, [built.ast, built.ast.statements]),
             "expected guarded #{body.inspect} to be arid"
    end

    modifier = source("puts \"restocked\" if ENV[\"DEBUG\"]\n")
    node = modifier.ast.statements.body.first
    assert @aridity.arid?(node, [modifier.ast, modifier.ast.statements])

    constructs = [
      "unless ENV[\"DEBUG\"]\n  puts \"debug\"\nend\n",
      "while ENV[\"DEBUG\"]\n  warn \"debug\"\nend\n",
      "until ENV[\"DEBUG\"]\n  logger.info \"debug\"\nend\n"
    ]
    constructs.each do |text|
      guarded = source(text)
      assert @aridity.arid?(guarded.ast.statements.body.first, [guarded.ast, guarded.ast.statements])
    end
  end

  def test_condition_guarded_raise_is_not_arid
    built = source("raise ArgumentError, \"bad\" if broken?\n")
    node = built.ast.statements.body.first

    refute @aridity.arid?(node, [built.ast, built.ast.statements])
  end

  def test_condition_guard_with_mixed_body_is_not_arid
    built = source("if ENV[\"DEBUG\"]\n  puts \"debug\"\n  value = 1\nend\n")
    node = built.ast.statements.body.first

    refute @aridity.arid?(node, [built.ast, built.ast.statements])
  end

  def test_compound_node_is_arid_only_when_every_child_is_arid
    arid = source("foo(puts(1))\n")
    active = source("foo(bar)\n")

    assert arid?(arid, Prism::CallNode, name: :foo)
    refute arid?(active, Prism::CallNode, name: :foo)
    assert arid?(arid, Prism::StatementsNode)
  end

  def test_program_is_arid_when_all_statements_are_arid
    built = source("puts 1\nputs 2\n")

    assert @aridity.arid?(built.ast, [])
    refute @aridity.arid?(source("puts 1\ncompute\n").ast, [])
  end
end
