class Constraint
    attr_reader :name

    def initialize(name)
        @name = name
    end

    def to_s
        name.to_s
    end

    def self.from_type(type)
        Constraint.new type.name
    end

    def to_swift
        ".#{Swift::lower_camel(name)}"
    end
end

class VariableKind
    attr_accessor :name

    def initialize(name)
        @name = name
    end

    def to_s
        name.to_s
    end
end

class Variable
    attr_reader :name, :kind, :constraint
    def initialize(name, kind, constraint=nil)
        @name = name
        @kind = kind
        @constraint = constraint
    end

    def <(constraint)
        raise "Expected a Constraint, found: #{constraint.class} "unless constraint.class == Constraint
        Variable.new(@name, @kind, constraint)
    end

    def to_s
        constraint = " is #{@constraint.to_s}" if @constraint
        "#{@name.to_s}#{constraint}"
    end

    def is_abstract?
        @kind != nil
    end

    # A type or value variable is referenced by its local name; a variable without a kind is a
    # texture kind (Types::Texture::Kind::Texture1d -> .texture1d).
    def to_swift
        return ".variable(#{@name})" if @kind
        ".#{Swift::lower_camel(@name.to_s.split("::").last)}"
    end

    def concrete_swift
        raise "Unexpected variable in a concrete type: #{self}" if @kind
        to_swift
    end

    def swift_declaration(context)
        index = context[kind]
        context[kind] += 1
        if @kind == DSL::type_variable
            constraint = ", constraint: #{@constraint.to_swift}" if @constraint
            "let #{name} = TypeVariable(id: #{index}#{constraint})"
        else
            raise "Unexpected constraint on the value variable #{self}" if @constraint
            "let #{name} = ValueVariable(id: #{index})"
        end
    end
end

class AbstractValue
    attr_reader :value

    def initialize(value)
        @value = value
    end

    def is_abstract?
        false
    end

    def to_s
      value.to_s
    end

    # 4 -> .constant(4); AddressSpace::Storage -> .addressSpace(.storage)
    def to_swift
        return ".constant(#{value})" if value.is_a? Integer
        enum, member = value.to_s.split("::")
        raise "Unexpected abstract value: #{value}" unless ["AddressSpace", "AccessMode"].include?(enum) and member
        ".#{Swift::lower_camel(enum)}(.#{Swift::lower_camel(member)})"
    end

    def concrete_swift
        raise "Unexpected abstract value in a concrete type: #{value}" unless value.is_a? Integer
        value.to_s
    end
end

class AbstractType
    attr_reader :name

    def initialize(name)
        @name = name
    end

    def [](*arguments)
        arguments.map! do |argument|
            if argument.is_a? Integer
                AbstractValue.new(argument)
            else
                argument
            end
        end

        # This is a bit hacky, but the idea is that types such as Vector can
        # either become:
        # 1) An AbstractType, if it receives a variable. This AbstractType will
        #    later be promoted to a concrete type once an overload is chosen.
        # 2) A concrete type if it's given a concrete type. Since there are no
        #    variables involved, we can immediately construct a concrete type.
        if arguments.any? do |arg| arg.is_abstract? end
            ParameterizedAbstractType.new(self, arguments)
        else
            Constructor.new(@name.downcase, arguments)
        end
    end

    def is_abstract?
        true
    end

    def to_s
        @name.to_s
    end
end

class Constructor
    attr_reader :name, :arguments

    def initialize(name, arguments)
        @name = name
        @arguments = arguments
    end

    def to_s
        "#{name.to_s}[#{arguments.map(&:to_s).join(", ")}]"
    end

    def is_abstract?
        false
    end

    # vector[2, f32] -> .vector(2, .fixed(FixedTypeID.f32))
    def concrete_swift
        raise "Unexpected concrete type constructor: #{name}" unless Swift::CONCRETE_TYPE_CONSTRUCTORS.include?(name.to_s)
        ".#{name}(#{arguments.map(&:concrete_swift).join ", "})"
    end

    def to_swift
        ".concrete(#{concrete_swift})"
    end
end

class PrimitiveType
    attr_reader :name

    def initialize(name)
        @name = name
    end

    def to_s
        @name.to_s
    end

    def is_abstract?
        false
    end

    # f32 -> .fixed(FixedTypeID.f32): TypeStore allocates every primitive at a fixed ID.
    def concrete_swift
        ".fixed(FixedTypeID.#{Swift::lower_camel(name)})"
    end

    def to_swift
        ".concrete(#{concrete_swift})"
    end
end

class ParameterizedAbstractType
    attr_reader :base, :arguments

    def initialize(base, arguments)
        @base = base
        @arguments = arguments
    end

    def is_abstract?
        true
    end

    def to_s
        "#{base}<#{arguments.join(", ")}>"
    end

    # Vector<N, T> -> .vector(.variable(N), .variable(T))
    def to_swift
        ".#{Swift::lower_camel(base)}(#{arguments.map(&:to_swift).join ", "})"
    end
end

class FunctionType
    attr_accessor :variables,  :parameters, :return_type

    def initialize(variables, parameters, return_type=nil)
        @variables = variables
        @parameters = parameters
        @return_type = return_type
    end

    def to_s
        variables = "<#{@variables.join(', ')}>" unless @variables.empty?
        "#{variables}(#{@parameters.join(', ')}) -> #{@return_type.to_s}"
    end

    def to_swift(name)
        context = {
            DSL::type_variable => 0,
            DSL::numeric_variable => 0,
        }
        type_variables = variables.select { |v| v.kind == DSL::type_variable }.map(&:name)
        value_variables = variables.select { |v| v.kind == DSL::numeric_variable }.map(&:name)
        out = []
        out << "    do {"
        out << "        // #{name} :: #{to_s}"
        out += variables.map { |v| "        " + v.swift_declaration(context) }
        out << "        overloads.append("
        out << "            OverloadCandidate("
        out << "                typeVariables: [#{type_variables.join ", "}],"
        out << "                valueVariables: [#{value_variables.join ", "}],"
        out << "                parameters: [#{parameters.map(&:to_swift).join ", "}],"
        out << "                result: #{return_type.to_swift}))"
        out << "    }"
        out.join "\n"
    end
end

class Array
    def call(*arguments)
        FunctionType.new(self, arguments)
    end
end

class AggregateConstructor
    # allows constructing ParameterizedAbstractTypes in multiple invocations/steps
    # e.g. vec[2][T] to construct Vector[2, T]
    #
    # the second argument `steps` is used to validate how many arguments are accepted per step
    # e.g. [s0, s1, ..., sn] will accept x[A0..As0]...[A0..Asn]
    #
    # A concrete example is matrix below, which uses steps [2, 1]:
    # - the first step takes 2 arguments: number of columns and number of rows
    # - the second step takes 1 argument: the element type of the matrix
    def initialize(constructor, steps, values = [])
        @constructor = constructor
        @steps = steps
        @values = values
    end

    def [](*args)
        expected = @steps[0]

        if args.length != expected
            raise "Unexpected number of arguments for constructor: expected #{expected}, got #{args.length}"
        end

        values = @values + args

        if @steps.length > 1
            AggregateConstructor.new(@constructor, @steps[1..], values)
        else
            @constructor[*values]
        end
    end
end

module Swift
    # The type constructors the table may apply to concrete arguments: the composite cases of
    # ConcreteTypeDescriptor.
    CONCRETE_TYPE_CONSTRUCTORS = ["vector", "matrix", "texture", "atomic", "frexpResult", "modfResult", "atomicCompareExchangeResult"]

    # The field names of the primitive structs frexp_result, modf_result and
    # atomic_compare_exchange_result. They follow the builtin declaration names in SymbolTable.predeclared.
    PRIMITIVE_STRUCT_FIELD_NAMES = ["fract", "exp", "whole", "old_value", "exchanged"]

    # BuiltinSymbols case names for the operators: the stems of their constant functions.
    OPERATOR_NAMES = {
        "!" => "not",
        "||" => "or",
        "&&" => "and",
        "|" => "bitwiseOr",
        "&" => "bitwiseAnd",
        "-" => "minus",
        "+" => "add",
        "*" => "multiply",
        "/" => "divide",
        "%" => "modulo",
        "==" => "equal",
        "!=" => "notEqual",
        "<" => "lt",
        "<=" => "ltEq",
        ">" => "gt",
        ">=" => "gtEq",
        "~" => "bitwiseNot",
        "^" => "bitwiseXor",
        "<<" => "bitwiseShiftLeft",
        ">>" => "bitwiseShiftRight",
    }

    KEYWORDS = ["Any", "Self", "as", "associatedtype", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]

    def self.lower_camel(name)
        name = name.to_s
        name[0].downcase + name[1..]
    end

    def self.string_literal(name)
        "\"" + name.to_s.gsub("\\", "\\\\\\\\").gsub("\"", "\\\\\"") + "\""
    end

    # A case name; .some and .none would be ambiguous with Optional's cases, and .init and .self are not
    # members.
    def self.case_name(name)
        raise "Not a Swift identifier: #{name}" unless name =~ /\A[a-z][A-Za-z0-9]*\z/
        raise "Unusable case name: #{name}" if ["some", "none", "init", "self"].include?(name)
        KEYWORDS.include?(name) ? "`#{name}`" : name
    end

    # "!" -> not, "old_value" -> oldValue, "arrayLength" -> arrayLength
    def self.symbol_case_name(name)
        return OPERATOR_NAMES[name] if OPERATOR_NAMES[name]
        raise "Unknown operator: #{name}; add it to OPERATOR_NAMES" unless name =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
        name.gsub(/_([a-z0-9])/) { $1.upcase }
    end

    # constantNot -> not; validateSubgroupShuffle -> subgroupShuffle
    def self.function_case_name(function, prefix)
        raise "#{function} does not start with #{prefix}" unless function.start_with?(prefix) and function.length > prefix.length
        lower_camel(function[prefix.length..])
    end
end

module DSL
    @context = binding()
    @aliases = {}
    @entries = {}
    @TypeVariable = VariableKind.new(:TypeVariable)
    @ValueVariable = VariableKind.new(:ValueVariable)

    def self.type_variable
        @TypeVariable
    end

    def self.numeric_variable
        @ValueVariable
    end

    def self.add_entry(kind, name, map)
        overloads = []
        properties = {
            must_use: false,
            const: false,
            validate: false,
            stage: [:fragment, :compute, :vertex],
        }
        map.each do |key, value|
            if key.kind_of? FunctionType
                key.return_type = value
                overloads << key
            else
                properties[key] = value
            end
        end

        existing_entry = @entries[name]
        if !existing_entry
            @entries[name] = {
                **properties,
                kind: kind,
                overloads: overloads
            }
            return
        end


        properties.each do |key, value|
            if existing_entry[key] != value then
                raise "Incompatible overload: key: #{key}, existing value: #{existing_entry[key]}, new value: #{value}"
            end
        end
        existing_entry[:overloads] += overloads
    end

    def self.operator(name, map)
        add_entry(:operator, name, map)
    end

    def self.constructor(name, map)
        add_entry(:constructor, name, map)
    end

    def self.function(name, map)
        add_entry(:function, name, map)
    end

    def self.type_alias(name, type)
        @aliases[name] = type
    end

    def self.function_name(entry_name, value, prefix)
        case value
        when false
            nil
        when true
            "#{prefix}#{entry_name[0].upcase}#{entry_name[1..]}"
        else
            value
        end
    end

    # The constant or validation functions the table references, in first-use order.
    def self.functions_for_swift(key, prefix)
        functions = []
        @entries.each do |name, entry|
            function = function_name(name.to_s, entry[key], prefix)
            functions << function if function and !functions.include?(function)
        end
        functions
    end

    # SymbolTable.predeclared in intern order: the builtin declaration names first, so that builtin i
    # is predeclared symbol i, then the field names and the type-alias names not already present.
    def self.predeclared_symbol_names
        names = @entries.keys.map(&:to_s)
        raise "Duplicate builtin declaration names" if names.uniq.length != names.length
        (Swift::PRIMITIVE_STRUCT_FIELD_NAMES + @aliases.keys.map(&:to_s)).each do |name|
            names << name unless names.include?(name)
        end
        names
    end

    def self.symbol_case(name)
        "BuiltinSymbols.#{Swift::case_name(Swift::symbol_case_name(name.to_s))}"
    end

    def self.function_case(enum, function, prefix)
        "#{enum}.#{Swift::case_name(Swift::function_case_name(function, prefix))}"
    end

    def self.string_list_to_swift(out, name, strings)
        out << "let #{name}: [StaticString] = ["
        strings.each { |string| out << "    #{Swift::string_literal(string)}," }
        out << "]"
    end

    def self.function_enum_to_swift(out, enum, functions, prefix)
        out << "enum #{enum}: UInt8, Sendable {"
        functions.each { |function| out << "    case #{Swift::case_name(Swift::function_case_name(function, prefix))}" }
        out << "}"
    end

    def self.names_to_swift
        predeclared = predeclared_symbol_names
        case_names = predeclared.map { |name| Swift::case_name(Swift::symbol_case_name(name)) }
        raise "Duplicate BuiltinSymbols case names" if case_names.uniq.length != case_names.length
        constant_functions = functions_for_swift(:const, "constant")
        validation_functions = functions_for_swift(:validate, "validate")
        raise "Too many constant functions for UInt8" if constant_functions.length > 256
        raise "Too many validation functions for UInt8" if validation_functions.length > 256

        out = []
        out << "/// The builtin declaration names in TypeDeclarations.rb order: builtinDeclarationNames[i] names"
        out << "/// makeBuiltinDeclarations()[i] and is predeclared symbol i."
        string_list_to_swift(out, "builtinDeclarationNames", @entries.keys)
        out << ""
        out << "/// The type-alias names in TypeDeclarations.rb order."
        string_list_to_swift(out, "builtinTypeAliasNames", @aliases.keys)
        out << ""
        out << "/// SymbolTable.predeclared in intern order: the builtin declaration names, then the primitive-struct"
        out << "/// field names and the type-alias names that are not already present."
        string_list_to_swift(out, "predeclaredSymbolNames", predeclared)
        out << ""
        out << "/// A predeclared symbol."
        out << "///"
        out << "/// The raw value is its index in predeclaredSymbolNames, which is its Symbol index in every module's"
        out << "/// SymbolTable."
        out << "enum BuiltinSymbols: UInt32, Sendable {"
        predeclared.each_with_index do |name, index|
            spelling = case_names[index] == name ? "" : " // #{name}"
            out << "    case #{case_names[index]} = #{index}#{spelling}"
        end
        out << "}"
        out << ""
        out << "extension BuiltinSymbols {"
        out << "    /// Predeclared symbols 0..<builtinDeclarationCount name the builtin declarations, in table order."
        out << "    static let builtinDeclarationCount: UInt32 = #{@entries.length}"
        out << "}"
        out << ""
        out << "/// The constant functions the table names, in first-use order; case x calls constantX."
        function_enum_to_swift(out, "ConstantFunction", constant_functions, "constant")
        out << ""
        out << "/// The validation functions the table names, in first-use order; case x calls validateX."
        function_enum_to_swift(out, "ValidationFunction", validation_functions, "validate")
        out.join "\n"
    end

    def self.function_dispatch_to_swift
        out = []
        out << "extension ConstantFunction {"
        out << "    func callAsFunction("
        out << "        _ shaderModule: borrowing ShaderModule,"
        out << "        _ resultType: TypeID,"
        out << "        _ arguments: borrowing [ConstantValue]"
        out << "    ) -> ConstantResult {"
        out << "        switch self {"
        functions_for_swift(:const, "constant").each do |function|
            out << "        case .#{Swift::case_name(Swift::function_case_name(function, "constant"))}: return #{function}(shaderModule, resultType, arguments)"
        end
        out << "        }"
        out << "    }"
        out << "}"
        out << ""
        out << "extension ValidationFunction {"
        out << "    func callAsFunction("
        out << "        _ shaderModule: borrowing ShaderModule,"
        out << "        _ arguments: borrowing [ConstantValue?],"
        out << "        _ types: borrowing [TypeID]"
        out << "    ) -> MessageText? {"
        out << "        switch self {"
        functions_for_swift(:validate, "validate").each do |function|
            out << "        case .#{Swift::case_name(Swift::function_case_name(function, "validate"))}: return #{function}(shaderModule, arguments, types)"
        end
        out << "        }"
        out << "    }"
        out << "}"
        out.join "\n"
    end

    def self.declarations_to_swift
        out = []
        out << "let builtinTypeAliases: [BuiltinTypeAlias] = ["
        @aliases.each do |name, type|
            out << "    BuiltinTypeAlias(name: #{symbol_case(name)}, type: #{type.concrete_swift}),"
        end
        out << "]"
        out.join "\n"
    end

    # One small, explicitly typed function per declaration keeps type checking and -Onone code linear.
    def self.overloads_to_swift
        functions = []
        @entries.each_with_index do |(name, entry), index|
            constant_function = function_name(name.to_s, entry[:const], "constant")
            validation_function = function_name(name.to_s, entry[:validate], "validate")
            stages = entry[:stage].kind_of?(Array) ? entry[:stage] : [entry[:stage]]
            function = []
            function << "// #{name}"
            function << "private func builtinDeclaration#{index}() -> OverloadedDeclaration {"
            function << "    var overloads: [OverloadCandidate] = []"
            function << "    overloads.reserveCapacity(#{entry[:overloads].length})"
            entry[:overloads].each do |overload|
                function << overload.to_swift(name)
            end
            function << "    return OverloadedDeclaration("
            function << "        name: #{symbol_case(name)},"
            function << "        kind: .#{entry[:kind]},"
            function << "        mustUse: #{entry[:must_use]},"
            function << "        constantFunction: #{constant_function ? function_case("ConstantFunction", constant_function, "constant") : "nil"},"
            function << "        validationFunction: #{validation_function ? function_case("ValidationFunction", validation_function, "validate") : "nil"},"
            function << "        visibility: [#{stages.map { |s| ".#{s}" }.join ", "}],"
            function << "        overloads: overloads)"
            function << "}"
            functions << function.join("\n")
        end
        out = []
        out << "// In TypeDeclarations.rb order."
        out << "func makeBuiltinDeclarations() -> [OverloadedDeclaration] {"
        out << "    var declarations: [OverloadedDeclaration] = []"
        out << "    declarations.reserveCapacity(#{@entries.length})"
        @entries.each_with_index do |_, index|
            out << "    declarations.append(builtinDeclaration#{index}())"
        end
        out << "    return declarations"
        out << "}"
        out << ""
        out << functions.join("\n\n")
        out.join "\n"
    end

    def self.prologue
        @context.eval <<~EOS
        # abstract types
        Vector = AbstractType.new(:Vector)
        Matrix = AbstractType.new(:Matrix)
        Texture = AbstractType.new(:Texture)
        TextureStorage = AbstractType.new(:TextureStorage)
        ChannelFormat = AbstractType.new(:ChannelFormat)

        array = AbstractType.new(:Array)
        ptr = AbstractType.new(:Pointer)
        ref = AbstractType.new(:Reference)
        atomic = AbstractType.new(:Atomic)

        # texture kinds
        Texture1d = Variable.new(:"Types::Texture::Kind::Texture1d", nil)
        Texture2d = Variable.new(:"Types::Texture::Kind::Texture2d", nil)
        TextureMultisampled2d = Variable.new(:"Types::Texture::Kind::TextureMultisampled2d", nil)
        Texture2dArray = Variable.new(:"Types::Texture::Kind::Texture2dArray", nil)
        Texture3d = Variable.new(:"Types::Texture::Kind::Texture3d", nil)
        TextureCube = Variable.new(:"Types::Texture::Kind::TextureCube", nil)
        TextureCubeArray = Variable.new(:"Types::Texture::Kind::TextureCubeArray", nil)

        # texture storage kinds
        TextureStorage1d = Variable.new(:"Types::TextureStorage::Kind::TextureStorage1d", nil)
        TextureStorage2d = Variable.new(:"Types::TextureStorage::Kind::TextureStorage2d", nil)
        TextureStorage2dArray = Variable.new(:"Types::TextureStorage::Kind::TextureStorage2dArray", nil)
        TextureStorage3d = Variable.new(:"Types::TextureStorage::Kind::TextureStorage3d", nil)

        # Variables
        S = Variable.new(:S, @TypeVariable)
        T = Variable.new(:T, @TypeVariable)
        U = Variable.new(:U, @TypeVariable)
        V = Variable.new(:V, @TypeVariable)

        N = Variable.new(:N, @ValueVariable)
        C = Variable.new(:C, @ValueVariable)
        R = Variable.new(:R, @ValueVariable)
        K = Variable.new(:K, @ValueVariable)
        AS = Variable.new(:AS, @ValueVariable)
        F = Variable.new(:F, @ValueVariable)
        AM = Variable.new(:AM, @ValueVariable)

        # constraints
        Number = Constraint.new(:Number)
        Integer = Constraint.new(:Integer)
        Float = Constraint.new(:Float)
        Scalar = Constraint.new(:Scalar)
        ConcreteInteger = Constraint.new(:ConcreteInteger)
        ConcreteFloat = Constraint.new(:ConcreteFloat)
        ConcreteScalar = Constraint.new(:ConcreteScalar)
        Concrete32BitNumber = Constraint.new(:Concrete32BitNumber)
        SignedNumber = Constraint.new(:SignedNumber)
        ConcreteNumber = Constraint.new(:ConcreteNumber)

        # primitives
        void = PrimitiveType.new(:Void)
        bool = PrimitiveType.new(:Bool)
        i32 = PrimitiveType.new(:I32)
        u32 = PrimitiveType.new(:U32)
        f32 = PrimitiveType.new(:F32)
        f16 = PrimitiveType.new(:F16)
        sampler = PrimitiveType.new(:Sampler)
        sampler_comparison = PrimitiveType.new(:SamplerComparison)
        texture_external = PrimitiveType.new(:TextureExternal)
        abstract_int = PrimitiveType.new(:AbstractInt)
        abstract_float = PrimitiveType.new(:AbstractFloat)

        texture_depth_2d = PrimitiveType.new(:TextureDepth2d)
        texture_depth_2d_array = PrimitiveType.new(:TextureDepth2dArray)
        texture_depth_cube = PrimitiveType.new(:TextureDepthCube)
        texture_depth_cube_array = PrimitiveType.new(:TextureDepthCubeArray)
        texture_depth_multisampled_2d = PrimitiveType.new(:TextureDepthMultisampled2d)

        storage = AbstractValue.new(:"AddressSpace::Storage")
        workgroup = AbstractValue.new(:"AddressSpace::Workgroup")

        read = AbstractValue.new(:"AccessMode::Read")
        read_write = AbstractValue.new(:"AccessMode::ReadWrite")
        write = AbstractValue.new(:"AccessMode::Write")

        # helpers
        vec = AggregateConstructor.new(Vector, [1, 1])
        mat = AggregateConstructor.new(Matrix, [2, 1])
        texture = AggregateConstructor.new(Texture, [1, 1])
        texture_storage = AggregateConstructor.new(TextureStorage, [1, 2])

        vec2 = vec[2]
        vec3 = vec[3]
        vec4 = vec[4]

        mat2x2 = mat[2,2]
        mat2x3 = mat[2,3]
        mat2x4 = mat[2,4]
        mat3x2 = mat[3,2]
        mat3x3 = mat[3,3]
        mat3x4 = mat[3,4]
        mat4x2 = mat[4,2]
        mat4x3 = mat[4,3]
        mat4x4 = mat[4,4]

        texture_1d = texture[Texture1d]
        texture_2d = texture[Texture2d]
        texture_multisampled_2d = texture[TextureMultisampled2d]
        texture_2d_array = texture[Texture2dArray]
        texture_3d = texture[Texture3d]
        texture_cube = texture[TextureCube]
        texture_cube_array = texture[TextureCubeArray]

        texture_storage_1d = texture_storage[TextureStorage1d]
        texture_storage_2d = texture_storage[TextureStorage2d]
        texture_storage_2d_array = texture_storage[TextureStorage2dArray]
        texture_storage_3d = texture_storage[TextureStorage3d]

        # primitive structs

        __frexp_result_abstract = Constructor.new(:frexpResult, [abstract_float, abstract_int])
        __frexp_result_f16 = Constructor.new(:frexpResult, [f16, i32])
        __frexp_result_f32 = Constructor.new(:frexpResult, [f32, i32])

        __frexp_result_vec2_abstract = Constructor.new(:frexpResult, [vec2[abstract_float], vec2[abstract_int]])
        __frexp_result_vec2_f16 = Constructor.new(:frexpResult, [vec2[f16], vec2[i32]])
        __frexp_result_vec2_f32 = Constructor.new(:frexpResult, [vec2[f32], vec2[i32]])

        __frexp_result_vec3_abstract = Constructor.new(:frexpResult, [vec3[abstract_float], vec3[abstract_int]])
        __frexp_result_vec3_f16 = Constructor.new(:frexpResult, [vec3[f16], vec3[i32]])
        __frexp_result_vec3_f32 = Constructor.new(:frexpResult, [vec3[f32], vec3[i32]])

        __frexp_result_vec4_abstract = Constructor.new(:frexpResult, [vec4[abstract_float], vec4[abstract_int]])
        __frexp_result_vec4_f16 = Constructor.new(:frexpResult, [vec4[f16], vec4[i32]])
        __frexp_result_vec4_f32 = Constructor.new(:frexpResult, [vec4[f32], vec4[i32]])

        __modf_result_abstract = Constructor.new(:modfResult, [abstract_float, abstract_float])
        __modf_result_f16 = Constructor.new(:modfResult, [f16, f16])
        __modf_result_f32 = Constructor.new(:modfResult, [f32, f32])

        __modf_result_vec2_abstract = Constructor.new(:modfResult, [vec2[abstract_float], vec2[abstract_float]])
        __modf_result_vec2_f16 = Constructor.new(:modfResult, [vec2[f16], vec2[f16]])
        __modf_result_vec2_f32 = Constructor.new(:modfResult, [vec2[f32], vec2[f32]])

        __modf_result_vec3_abstract = Constructor.new(:modfResult, [vec3[abstract_float], vec3[abstract_float]])
        __modf_result_vec3_f16 = Constructor.new(:modfResult, [vec3[f16], vec3[f16]])
        __modf_result_vec3_f32 = Constructor.new(:modfResult, [vec3[f32], vec3[f32]])

        __modf_result_vec4_abstract = Constructor.new(:modfResult, [vec4[abstract_float], vec4[abstract_float]])
        __modf_result_vec4_f16 = Constructor.new(:modfResult, [vec4[f16], vec4[f16]])
        __modf_result_vec4_f32 = Constructor.new(:modfResult, [vec4[f32], vec4[f32]])

        __atomic_compare_exchange_result_i32 = Constructor.new(:atomicCompareExchangeResult, [i32])
        __atomic_compare_exchange_result_u32 = Constructor.new(:atomicCompareExchangeResult, [u32])
        EOS
    end

    def self.run(file)
        @context.eval(File.open(file).read, file)
    end

    def self.write_to(output)
        parts = [
            "// Generated from TypeDeclarations.rb by generator/main.rb --swift. Do not edit.",
            names_to_swift,
            function_dispatch_to_swift,
            declarations_to_swift,
            overloads_to_swift,
        ]
        File.open(output, 'w') { |file| file.write(parts.join("\n\n") + "\n") }
    end
end

raise "usage: #{__FILE__} --swift <declaration-file> <output-swift>" if ARGV.length != 3 or ARGV[0] != "--swift"
input = ARGV[1]
output = ARGV[2]

DSL::prologue()
DSL::run(input)
DSL::write_to(output)
