# frozen_string_literal: true

require "prism"
require "set"

module Mutation
  # Weak mutation: decide whether applying a mutant would change any value a covering
  # test sees, without running the test under the mutant.
  #
  # The dry run loads probe-instrumented copies of the target files. A probe evaluates
  # the original expression once (so behaviour is unchanged), records that this test
  # reached it, then evaluates the mutated form in a block and records a difference.
  # A regression suite that never observes a different value cannot kill the mutant, so
  # the runner can report it as survived without spending a child on it.
  #
  # Only pure expressions are probed. A method call on a local (`a.size`) could have a
  # side effect, so it is left to a real run.
  module Weak
    OPERATORS = %i[aor ror lcr].freeze

    # What one dry run learned. `seen` holds ids of tests that evaluated the
    # expression, `infected` those that saw a different value.
    class Report
      EMPTY = Set.new.freeze

      attr_reader :seen, :infected

      def initialize(seen: {}, infected: {})
        @seen = seen.transform_values { |tests| Set.new(tests.keys).freeze }.freeze
        @infected = infected.transform_values { |tests| Set.new(tests.keys).freeze }.freeze
      end

      # :not_infected  every selected test evaluated the expression, none saw a change
      # :infected      some selected test saw a different value
      # :unknown       the probe is missing or did not run for every selected test
      def decision(mutant, selected)
        tests = @seen[mutant.id]
        return :unknown if tests.nil?

        ids = selected.map(&:to_s)
        return :unknown unless ids.all? { |id| tests.include?(id) }

        hits = @infected[mutant.id] || EMPTY
        ids.any? { |id| hits.include?(id) } ? :infected : :not_infected
      end
    end

    Probe = Data.define(:mutant, :start_offset, :end_offset, :text)

    class << self
      attr_accessor :test_id

      def evaluations
        @evaluations ||= {}
      end

      def infections
        @infections ||= {}
      end

      def reset!
        @test_id = nil
        @evaluations = {}
        @infections = {}
      end

      # Injected into the project: return the original value, record whether this test
      # saw a different one for any mutant of the expression. A form is a lambda so a
      # raise counts as a difference instead of breaking the dry run.
      def evaluate(original, forms)
        test = test_id
        return original if test.nil?

        forms.each do |key, form|
          (evaluations[key] ||= {})[test] = true
          begin
            mutated = form.call
          rescue StandardError
            (infections[key] ||= {})[test] = true
          else
            (infections[key] ||= {})[test] = true unless original.eql?(mutated)
          end
        end
        original
      end

      def report
        Report.new(seen: evaluations, infected: infections)
      end

      # -> Array[Probe], one per expression. Mutants that replace the same expression
      # share a probe: the original is evaluated once and every replacement is checked
      # against that value. Nested expressions are left to the outermost probe, because
      # two wraps of one expression would evaluate the inner one twice.
      def probes(source, mutants)
        groups = eligible(mutants).group_by { |mutant| [mutant.start_offset, mutant.end_offset] }
        ranges = groups.keys.sort_by { |first, last| [first, -last] }
        kept = []
        ranges.each do |range|
          next if kept.any? { |kept_first, kept_last| range[0] < kept_last && kept_first < range[1] }

          kept << range
        end
        kept.map do |first, last|
          list = groups[[first, last]].sort_by(&:id)
          original = source.text.byteslice(first, last - first)
          forms = list.map do |mutant|
            "[#{mutant.id.inspect}, -> { (#{mutant.replacement}) }]"
          end.join(", ")
          Probe.new(
            mutant: list.first,
            start_offset: first,
            end_offset: last,
            text: "::Mutation::Weak.evaluate((#{original}), [#{forms}])"
          )
        end
      end

      # The probe-instrumented text, or nil when no mutant can be probed.
      def instrument(source, mutants)
        list = probes(source, mutants)
        return nil if list.empty?

        [apply(source.text, list), list]
      end

      def apply(text, probes)
        out = text.dup
        probes.sort_by { |probe| -probe.start_offset }.each do |probe|
          out.bytesplice(probe.start_offset, probe.end_offset - probe.start_offset, probe.text)
        end
        out
      end

      def eligible(mutants)
        mutants.select do |mutant|
          mutant.weak && OPERATORS.include?(mutant.operator.to_sym)
        end
      end

      def eligible?(operator, node)
        case operator.to_sym
        when :aor, :ror then binary_pure?(node)
        when :lcr then logical_pure?(node) || binary_pure?(node)
        else false
        end
      end

      def binary_pure?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false if node.receiver.nil? || node.message_loc.nil? || node.arguments.nil?

        arguments = node.arguments.arguments
        return false unless arguments.length == 1

        pure?(node.receiver) && pure?(arguments.first)
      end

      def logical_pure?(node)
        (node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)) &&
          pure?(node.left) && pure?(node.right)
      end

      # Values that can be evaluated twice without an observable effect. Method calls stay
      # off the list even when they look pure, because nothing here can prove they are.
      def pure?(node)
        case node
        when Prism::ParenthesesNode
          body = node.body
          body.is_a?(Prism::StatementsNode) && body.body.length == 1 && pure?(body.body.first)
        when Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode,
             Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
             Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::SelfNode,
             Prism::ConstantReadNode, Prism::ConstantPathNode
          true
        when Prism::CallNode
          binary_pure?(node)
        when Prism::AndNode, Prism::OrNode
          pure?(node.left) && pure?(node.right)
        else
          false
        end
      end
    end
  end
end
