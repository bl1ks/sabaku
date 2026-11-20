# frozen_string_literal: true

require_relative "replacement"
require_relative "support"

module Sabaku
  module Operator
    # Message replacement: swap a method name for one a reader would confuse it
    # with. The table mirrors the one mutant ships, minus pairs that are exact
    # aliases (`send` and `__send__`), because those mutants can never be
    # killed and would only dilute the score.
    #
    # Every entry keeps the receiver and the arguments, so the only changed
    # bytes are the message token.
    module Selector
      REPLACEMENTS = {
        :!= => %i[==],
        :** => %i[*],
        :% => %i[/],
        :& => %i[| ^],
        :* => %i[/],
        :+ => %i[-],
        :- => %i[+],
        :/ => %i[*],
        :< => %i[== eql? equal?],
        :<< => %i[>>],
        :<= => %i[< == eql? equal?],
        :== => %i[!= eql? equal?],
        :=== => %i[is_a?],
        :=~ => %i[match?],
        :> => %i[== eql? equal?],
        :>= => %i[> == eql? equal?],
        :>> => %i[<<],
        :^ => %i[& |],
        :| => %i[& ^],
        __send__: %i[public_send],
        all?: %i[any? none?],
        any?: %i[all? empty? none?],
        append: %i[prepend],
        assoc: %i[rassoc],
        at: %i[fetch key?],
        bytes: %i[chars],
        capitalize!: %i[capitalize],
        chars: %i[bytes],
        chomp!: %i[chomp],
        chop!: %i[chop],
        chunk: %i[each],
        chunk_while: %i[each],
        collect: %i[each],
        collect!: %i[collect],
        collect_concat: %i[collect],
        compact!: %i[compact],
        ceil: %i[floor],
        count: %i[size length],
        delete!: %i[delete],
        delete_if: %i[reject],
        detect: %i[first last],
        downcase: %i[upcase],
        downcase!: %i[downcase],
        drop: %i[take],
        each_cons: %i[each],
        each_key: %i[each_value],
        each_slice: %i[each],
        each_value: %i[each_key],
        each_with_index: %i[each],
        each_with_object: %i[each],
        empty?: %i[any?],
        encode!: %i[encode],
        end_with?: %i[start_with?],
        even?: %i[odd?],
        fetch: %i[key?],
        filter: %i[reject],
        filter!: %i[filter],
        filter_map: %i[map],
        find: %i[first last],
        first: %i[last],
        flat_map: %i[map],
        flatten!: %i[flatten],
        floor: %i[ceil],
        grep: %i[grep_v],
        grep_v: %i[grep],
        gsub: %i[sub],
        gsub!: %i[gsub],
        is_a?: %i[instance_of?],
        keep_if: %i[select],
        keys: %i[values],
        kind_of?: %i[instance_of?],
        last: %i[first],
        lstrip!: %i[lstrip],
        map: %i[each],
        map!: %i[map],
        match: %i[match?],
        max: %i[first last min],
        max_by: %i[first last min_by],
        merge!: %i[merge],
        method: %i[public_method],
        min: %i[first last max],
        min_by: %i[first last max_by],
        negative?: %i[positive?],
        none?: %i[any? all?],
        odd?: %i[even?],
        pop: %i[shift],
        positive?: %i[negative?],
        pred: %i[succ],
        prepend: %i[append],
        push: %i[unshift],
        reject: %i[select],
        reject!: %i[reject],
        reverse!: %i[reverse],
        reverse_each: %i[each],
        reverse_merge: %i[merge],
        rassoc: %i[assoc],
        rotate!: %i[rotate],
        rstrip!: %i[rstrip],
        sample: %i[first last],
        scrub!: %i[scrub],
        select: %i[reject],
        select!: %i[select],
        send: %i[public_send],
        shift: %i[pop],
        shuffle!: %i[shuffle],
        slice_after: %i[each],
        slice_before: %i[each],
        slice_when: %i[each],
        sort!: %i[sort],
        sort_by: %i[sort],
        sort_by!: %i[sort_by],
        squeeze!: %i[squeeze],
        start_with?: %i[end_with?],
        strip: %i[lstrip rstrip],
        strip!: %i[strip],
        sub!: %i[sub],
        succ: %i[pred],
        swapcase!: %i[swapcase],
        take: %i[drop],
        to_a: %i[to_ary],
        to_f: %i[to_i],
        to_h: %i[to_hash],
        to_i: %i[to_int],
        to_s: %i[to_str],
        tr!: %i[tr],
        tr_s!: %i[tr_s],
        transform_keys: %i[transform_values],
        transform_keys!: %i[transform_keys],
        transform_values: %i[transform_keys],
        transform_values!: %i[transform_values],
        unicode_normalize!: %i[unicode_normalize],
        uniq!: %i[uniq],
        unshift: %i[push],
        upcase: %i[downcase],
        upcase!: %i[upcase],
        values: %i[keys],
        values_at: %i[fetch_values],
        zero?: %i[nonzero?]
      }.transform_values(&:freeze).freeze

      def self.id
        :selector
      end

      def self.node_types
        [Prism::CallNode]
      end

      # Tokens Ruby accepts in the infix position. Every other replacement is a
      # method name that has to be re-emitted in call form, because
      # `available >= 0` becomes `(available).eql?(0)` and never
      # `available eql? 0`.
      INFIX = %i[== != =~ !~ < <= > >= + - * / % ** << >> & | ^ ===].freeze

      def self.mutations(node, source)
        target = node.message_loc
        return [] if target.nil?
        # `a&.foo` cannot host an infix operator, and the call-form rewrite
        # would drop the safe navigation.
        return [] unless node.call_operator_loc.nil? || node.call_operator_loc.slice == "."

        others = REPLACEMENTS[node.name]
        return [] if others.nil?

        original = source.slice(node)
        others.map do |name|
          Replacement.new(
            original: original,
            replacement: rewrite(original, node, source, target, name)
          )
        end
      end

      def self.rewrite(original, node, source, target, name)
        current = target.slice.to_sym
        return Support.replace_token(original, node, target, name.to_s) unless
          INFIX.include?(current) && !INFIX.include?(name)

        arguments = node.arguments ? node.arguments.arguments : []
        args = arguments.map { |argument| source.slice(argument) }.join(", ")
        "#{parenthesize(source.slice(node.receiver))}.#{name}(#{args})"
      end

      def self.parenthesize(text)
        return text if text.start_with?("(") && text.end_with?(")")

        "(#{text})"
      end

      private_class_method :rewrite, :parenthesize
    end
  end
end
