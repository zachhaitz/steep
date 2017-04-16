module Steep
  class TypeConstruction
    attr_reader :assignability
    attr_reader :source
    attr_reader :env
    attr_reader :typing

    def initialize(assignability:, source:, env:, typing:)
      @assignability = assignability
      @source = source
      @env = env
      @typing = typing
    end

    def run(node)
      case node.type
      when :begin
        type = each_child_node(node).map do |child|
          run(child)
        end.last

        typing.add_typing(node, type)
      when :lvasgn
        name = node.children[0]
        lhs_type = env.lookup(name)
        rhs_type = run(node.children[1])

        if lhs_type
          unless assignability.test(src: rhs_type, dest: lhs_type)
            typing.add_error(Errors::IncompatibleAssignment.new(node: node, lhs_type: lhs_type, rhs_type: rhs_type))
          end
          typing.add_typing(node, lhs_type)
          env.add(name, lhs_type)
        else
          typing.add_typing(node, rhs_type)
          env.add(name, rhs_type)
        end

      when :lvar
        type = env.lookup(node.children[0]) || Types::Any.new
        typing.add_typing(node, type)

      when :str
        typing.add_typing(node, Types::Any.new)

      when :send
        recv_type = run(node.children[0])
        method_name = node.children[1]

        ret_type = assignability.method_type recv_type, method_name do |method_type|
          if method_type
            check_argument_types node, params: method_type.params, arguments: node.children.drop(2)
            method_type.return_type
          else
            # no method error
            typing.add_error Errors::NoMethod.new(node: node, method: method_name, type: recv_type)
          end
        end

        typing.add_typing(node, ret_type)

      when :int
        typing.add_typing(node, Types::Any.new)

      when :nil
        typing.add_typing(node, Types::Any.new)

      when :hash
        each_child_node(node) do |child|
          run child
        end

        typing.add_typing(node, Types::Any.new)

      when :pair
        run node.children[1]

        typing.add_typing(node, Types::Any.new)

      else
        p node

        typing.add_typing(node, Types::Any.new)
      end
    end

    def each_child_node(node)
      if block_given?
        node.children.each do |child|
          if child.is_a?(AST::Node)
            yield child
          end
        end
      else
        enum_for :each_child_node, node
      end
    end

    def check_argument_types(node, params:, arguments:)
      params.each_missing_argument arguments do |index|
        typing.add_error Errors::ExpectedArgumentMissing.new(node: node, index: index)
      end

      params.each_extra_argument arguments do |index|
        typing.add_error Errors::ExtraArgumentGiven.new(node: node, index: index)
      end

      params.each_missing_keyword arguments do |keyword|
        typing.add_error Errors::ExpectedKeywordMissing.new(node: node, keyword: keyword)
      end

      params.each_extra_keyword arguments do |keyword|
        typing.add_error Errors::ExtraKeywordGiven.new(node: node, keyword: keyword)
      end

      arguments.each do |arg|
        run(arg)
      end

      self.class.argument_typing_pairs(params: params, arguments: arguments).each do |(param_type, argument)|
        arg_type = typing.type_of(node: argument)
        unless assignability.test(src: arg_type, dest: param_type)
          error = Errors::InvalidArgument.new(node: argument, expected: param_type, actual: arg_type)
          typing.add_error(error)
        end
      end
    end

    def self.argument_typing_pairs(params:, arguments:)
      keywords = {}
      unless params.required_keywords.empty? && params.optional_keywords.empty? && !params.rest_keywords
        # has keyword args
        last_arg = arguments.last
        if last_arg&.type == :hash
          arguments.pop

          last_arg.children.each do |elem|
            case elem.type
            when :pair
              key, value = elem.children
              if key.type == :sym
                name = key.children[0]

                keywords[name] = value
              end
            end
          end
        end
      end

      pairs = []

      params.flat_unnamed_params.each do |param_type|
        arg = arguments.shift
        pairs << [param_type.last, arg] if arg
      end

      if params.rest
        arguments.each do |arg|
          pairs << [params.rest, arg]
        end
      end

      params.flat_keywords.each do |name, type|
        arg = keywords.delete(name)
        if arg
          pairs << [type, arg]
        end
      end

      if params.rest_keywords
        keywords.each_value do |arg|
          pairs << [params.rest_keywords, arg]
        end
      end

      pairs
    end
  end
end
