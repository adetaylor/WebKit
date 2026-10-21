// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

enum DiscardResult {
    case no
    case yes
}

struct Binding {
    enum Kind: UInt8 {
        case value
        case type
        case function
    }

    var kind: Kind
    var type: TypeID
    var evaluation: Evaluation
    var constantValue: ConstantValue?
    // Set for a declaration in a loop body that follows a continue statement targeting that loop.
    // A shadowing declaration is a separate binding, so it is left unmarked and stays usable.
    var declaredAfterContinue = false
}

enum BreakTarget {
    case switchStatement(StatementID)
    case loopStatement(StatementID)
    case forStatement(StatementID)
    case whileStatement(StatementID)
    /// C++ `AST::Continuing*`: the LoopStatement whose `continuing` it is.
    case continuing(StatementID)
}

func bindingKindToString(_ kind: Binding.Kind) -> StaticString {
    switch kind {
    case .value:
        return "value"
    case .type:
        return "type"
    case .function:
        return "function"
    }
}

func evaluationToString(_ evaluation: Evaluation) -> StaticString {
    switch evaluation {
    case .constant:
        return "constant"
    case .override:
        return "override"
    case .runtime:
        return "runtime"
    }
}

func variableFlavorToString(_ flavor: VariableFlavor) -> StaticString {
    switch flavor {
    case .var:
        return "var"
    case .let:
        return "let"
    case .const:
        return "const"
    case .override:
        return "override"
    }
}

/// C++ `class TypeChecker : public ContextProvider<Binding>`; its own throwing visit family, not an `ASTVisitor`.
struct TypeChecker: ~Copyable {
    var shaderModule: ShaderModule
    var inferredType: TypeID?
    var returnType: TypeID?
    var currentEvaluation: Evaluation?
    var maxEvaluation = Evaluation.runtime
    var discardResult = DiscardResult.no
    var suppressConstantErrors = false

    // https://www.w3.org/TR/WGSL/#continue-statement
    // Source offset of the earliest continue statement targeting the innermost enclosing loop, used
    // to mark the declarations that a continue would jump over on its way to the continuing clause.
    var earliestContinueOffset = UInt32.max
    var declaringAfterContinue = false
    var inContinuingClause = false

    var breakTargetStack: [BreakTarget] = []
    var arrayCountOverrides = LookupMap<Symbol, ExpressionID>()

    // The names declared at module scope, collected before any of them is visited. Module scope has
    // no declaration order, so a rule about what those names hide cannot be answered by the scope
    // built up as the declarations are visited one after another.
    var moduleScopeNames = SymbolMap<Void>()

    /// The C++ base class `ContextProvider<Binding>`.
    var context = ContextProvider<Binding>()

    // DEV-04: the `&&`/`||` left operand binaryExpression has just inferred. The next expression dispatch, chooseOverload's
    // inference of that operand, reuses the inference instead of repeating it.
    var inferredLeftOperand: ExpressionID?

    var overloadBuffers = OverloadResolutionBuffers()
    var overloadMemo = OverloadResolutionMemo()
    var concretizedTypes = SideTable<TypeID, TypeID?>()
    // The structure types checked so far that have a creation-fixed footprint.
    var creationFixedStructures = IDSet<TypeID>()
    var argumentTypeStack: [TypeID] = []
    var argumentTypeStackTop = 0
    var constantArgumentsBuffer: [ConstantValue] = []
    var validationArgumentsBuffer: [ConstantValue?] = []

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }
}

extension TypeChecker {
    mutating func declareBuiltins() throws(CompilationMessage) {
        try introduceType(shaderModule.makeIdentifier("bool"), shaderModule.types.boolType)
        try introduceType(shaderModule.makeIdentifier("i32"), shaderModule.types.i32Type)
        try introduceType(shaderModule.makeIdentifier("u32"), shaderModule.types.u32Type)
        try introduceType(shaderModule.makeIdentifier("f32"), shaderModule.types.f32Type)
        try introduceType(shaderModule.makeIdentifier("f16"), shaderModule.types.f16Type)
        try introduceType(shaderModule.makeIdentifier("sampler"), shaderModule.types.samplerType)
        try introduceType(shaderModule.makeIdentifier("sampler_comparison"), shaderModule.types.samplerComparisonType)
        try introduceType(shaderModule.makeIdentifier("texture_external"), shaderModule.types.textureExternalType)

        try introduceType(shaderModule.makeIdentifier("texture_depth_2d"), shaderModule.types.textureDepth2dType)
        try introduceType(shaderModule.makeIdentifier("texture_depth_2d_array"), shaderModule.types.textureDepth2dArrayType)
        try introduceType(shaderModule.makeIdentifier("texture_depth_cube"), shaderModule.types.textureDepthCubeType)
        try introduceType(shaderModule.makeIdentifier("texture_depth_cube_array"), shaderModule.types.textureDepthCubeArrayType)
        try introduceType(shaderModule.makeIdentifier("texture_depth_multisampled_2d"), shaderModule.types.textureDepthMultisampled2dType)

        try introduceType(shaderModule.makeIdentifier("ptr"), shaderModule.types.typeConstructorType(.pointer))

        try introduceType(shaderModule.makeIdentifier("atomic"), shaderModule.types.typeConstructorType(.atomic))

        try allocateSimpleConstructor("vec2", .vector(2))
        try allocateSimpleConstructor("vec3", .vector(3))
        try allocateSimpleConstructor("vec4", .vector(4))

        try allocateSimpleConstructor("mat2x2", .matrix(columns: 2, rows: 2))
        try allocateSimpleConstructor("mat2x3", .matrix(columns: 2, rows: 3))
        try allocateSimpleConstructor("mat2x4", .matrix(columns: 2, rows: 4))
        try allocateSimpleConstructor("mat3x2", .matrix(columns: 3, rows: 2))
        try allocateSimpleConstructor("mat3x3", .matrix(columns: 3, rows: 3))
        try allocateSimpleConstructor("mat3x4", .matrix(columns: 3, rows: 4))
        try allocateSimpleConstructor("mat4x2", .matrix(columns: 4, rows: 2))
        try allocateSimpleConstructor("mat4x3", .matrix(columns: 4, rows: 3))
        try allocateSimpleConstructor("mat4x4", .matrix(columns: 4, rows: 4))

        try allocateSimpleConstructor("texture_1d", .texture(.texture1d))
        try allocateSimpleConstructor("texture_2d", .texture(.texture2d))
        try allocateSimpleConstructor("texture_2d_array", .texture(.texture2dArray))
        try allocateSimpleConstructor("texture_3d", .texture(.texture3d))
        try allocateSimpleConstructor("texture_cube", .texture(.textureCube))
        try allocateSimpleConstructor("texture_cube_array", .texture(.textureCubeArray))
        try allocateSimpleConstructor("texture_multisampled_2d", .texture(.textureMultisampled2d))

        try allocateTextureStorageConstructor("texture_storage_1d", .textureStorage1d)
        try allocateTextureStorageConstructor("texture_storage_2d", .textureStorage2d)
        try allocateTextureStorageConstructor("texture_storage_2d_array", .textureStorage2dArray)
        try allocateTextureStorageConstructor("texture_storage_3d", .textureStorage3d)

        try introducePredeclaredValue("read", shaderModule.types.accessModeType)
        try introducePredeclaredValue("write", shaderModule.types.accessModeType)
        try introducePredeclaredValue("read_write", shaderModule.types.accessModeType)

        try introducePredeclaredValue("bgra8unorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r32float", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r32sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r32uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg32float", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg32sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg32uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba16float", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba16sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba16uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba32float", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba32sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba32uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba8sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba8snorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba8uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba8unorm", shaderModule.types.texelFormatType)

        try introducePredeclaredValue("r16float", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r16sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r16uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r8sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r8snorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r8uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r8unorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg16float", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg8sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg8snorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg8uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg8unorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgb10a2uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgb10a2unorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg16sint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg16uint", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg11b10ufloat", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r16unorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("r16snorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg16snorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rg16unorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba16snorm", shaderModule.types.texelFormatType)
        try introducePredeclaredValue("rgba16unorm", shaderModule.types.texelFormatType)

        try introducePredeclaredValue("function", shaderModule.types.addressSpaceType)
        try introducePredeclaredValue("private", shaderModule.types.addressSpaceType)
        try introducePredeclaredValue("workgroup", shaderModule.types.addressSpaceType)
        try introducePredeclaredValue("uniform", shaderModule.types.addressSpaceType)
        try introducePredeclaredValue("storage", shaderModule.types.addressSpaceType)

        // This file contains the declarations generated from `TypeDeclarations.rb`
        var index = 0
        while index < builtinTypeAliases.count {
            let alias = builtinTypeAliases[index]
            let aliasType = shaderModule.types.materialize(alias.type)
            try introduceType(shaderModule.makeIdentifier(Symbol(alias.name)), aliasType)
            index &+= 1
        }
    }

    /// The type constructor declareBuiltins introduces as "ptr".
    mutating func constructPointer(_ type: ElaboratedTypeExpression, _ id: ExpressionID) throws(CompilationMessage) -> TypeID {
        let argumentCount = shaderModule.count(type.arguments)
        guard argumentCount >= 2 else {
            throw CompilationMessage(text: "'ptr' requires at least 2 template arguments", span: shaderModule.span(of: id))
        }

        guard argumentCount <= 3 else {
            throw CompilationMessage(text: "'ptr' requires at most 3 template arguments", span: shaderModule.span(of: id))
        }

        let addressSpace = try self.addressSpace(shaderModule[type.arguments, 0])
        let elementType = try resolve(shaderModule[type.arguments, 1])

        guard shaderModule.isStorable(elementType) else {
            throw CompilationMessage(
                text: "'\(ShaderModule.typeString(elementType, in: &shaderModule))' cannot be used as the store type of a pointer",
                span: shaderModule.span(of: id)
            )
        }

        // https://www.w3.org/TR/WGSL/#ref-ptr-types
        // A pointer's address space has to permit its store type. Textures and samplers only ever
        // live in the handle address space, and that address space cannot be spelled, so no
        // pointer that can be written down may point at one.
        if shaderModule.isTexture(elementType) || shaderModule.isSampler(elementType) {
            throw CompilationMessage(
                text:
                    "'\(ShaderModule.typeString(elementType, in: &shaderModule))' cannot be used as the store type of a pointer in the <\(toString(addressSpace))> address space",
                span: shaderModule.span(of: id)
            )
        }

        if case .atomic = shaderModule.types[elementType], addressSpace != .storage && addressSpace != .workgroup {
            throw CompilationMessage(
                text:
                    "'\(ShaderModule.typeString(elementType, in: &shaderModule))' atomic variables must have <storage> or <workgroup> address space",
                span: shaderModule.span(of: id)
            )
        }

        if shaderModule.containsRuntimeArray(elementType) && addressSpace != .storage {
            throw CompilationMessage(
                text: "runtime-sized arrays can only be used in the <storage> address space",
                span: shaderModule.span(of: id)
            )
        }

        // https://www.w3.org/TR/WGSL/#array-types
        // An override element count survives only where the array itself could live, and a
        // 'var<workgroup>' store type is the one such place, so its pointers are the only
        // pointers that may point at one.
        if shaderModule.containsOverrideArray(elementType) && addressSpace != .workgroup {
            throw CompilationMessage(
                text: "array with an 'override' element count can only be pointed to in the <workgroup> address space",
                span: shaderModule.span(of: id)
            )
        }

        let accessMode: AccessMode
        if argumentCount > 2 {
            let accessModeArgument = shaderModule[type.arguments, 2]
            guard addressSpace == .storage else {
                throw CompilationMessage(
                    text: "only pointers in <storage> address space may specify an access mode",
                    span: shaderModule.span(of: accessModeArgument)
                )
            }

            accessMode = try self.accessMode(accessModeArgument)

            guard accessMode != .write else {
                throw CompilationMessage(
                    text: "access mode 'write' is not valid for the <storage> address space",
                    span: shaderModule.span(of: accessModeArgument)
                )
            }
        } else {
            switch addressSpace {
            case .function, .private, .workgroup:
                accessMode = .readWrite
            case .uniform, .storage, .handle:
                accessMode = .read
            }
        }

        return shaderModule.types.pointerType(addressSpace, elementType, accessMode)
    }

    /// The type constructor declareBuiltins introduces as "atomic".
    mutating func constructAtomic(_ type: ElaboratedTypeExpression, _ id: ExpressionID) throws(CompilationMessage) -> TypeID {
        guard shaderModule.count(type.arguments) == 1 else {
            throw CompilationMessage(text: "'atomic' requires 1 template argument", span: shaderModule.span(of: id))
        }

        let element = shaderModule[type.arguments, 0]
        let elementType = try resolve(element)

        guard elementType == shaderModule.types.i32Type || elementType == shaderModule.types.u32Type else {
            throw CompilationMessage(text: "atomic only supports i32 or u32 types", span: shaderModule.span(of: element))
        }

        return shaderModule.types.atomicType(elementType)
    }

    /// C++ the `validateVector`, `validateMatrix` and `validateTexture` lambdas of declareBuiltins.
    static func validate(_ validator: SimpleConstructorValidator, _ element: TypeID, _ types: borrowing TypeStore) -> MessageText? {
        switch validator {
        case .vector:
            if !satisfies(element, .scalar, types) {
                return "vector element type must be a scalar type"
            }
            return nil
        case .matrix:
            if !satisfies(element, .float, types) {
                return "matrix element type must be a floating point type"
            }
            return nil
        case .texture:
            if !satisfies(element, .concrete32BitNumber, types) {
                return "texture sampled type must be one 'i32', 'u32' or 'f32'"
            }
            return nil
        }
    }

    mutating func check() -> FailedCheck? {
        shaderModule.reserveConstantSlots()
        do throws(CompilationMessage) {
            try declareBuiltins()

            let moduleScope = openContextScope()
            defer { closeContextScope(moduleScope) }

            try visitShaderModule()
        } catch {
            let warnings: [CompilationMessage] = []
            return FailedCheck(errors: [error], warnings: warnings)
        }
        return nil
    }

    /// C++ `visit(ShaderModule&)`.
    mutating func visitShaderModule() throws(CompilationMessage) {
        moduleScopeNames.reserveInitialCapacity(shaderModule.count(shaderModule.declarations))
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if declaration.nodeKind != .constAssert {
                moduleScopeNames.add(shaderModule.symbol(of: shaderModule.name(of: declaration)), ())
            }
        }

        declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            try visit(declaration)
        }
    }
}

extension TypeChecker {
    mutating func check(
        _ expression: ExpressionID,
        _ constraint: Constraint,
        _ evaluation: Evaluation
    ) throws(CompilationMessage) -> TypeID? {
        let inferredType = try infer(expression, evaluation)
        guard let type = satisfyOrPromote(inferredType, constraint, shaderModule.types) else {
            return nil
        }
        try convertValue(shaderModule.span(of: expression), type, of: expression)
        return type
    }

    mutating func resolve(_ type: ExpressionID) throws(CompilationMessage) -> TypeID {
        assert(inferredType == nil)
        assert(currentEvaluation == nil)
        if let identifierExpression = shaderModule.dynamicDowncast(IdentifierExpression.self, type) {
            let identifierType = try lookupType(shaderModule[identifierExpression.identifier])
            inferred(identifierType)
            evaluated(.constant)
        } else {
            try visit(type)
        }
        assert(inferredType != nil)
        assert(currentEvaluation != nil)

        guard let inferredType else {
            wgslFatal("resolve: the visit inferred no type", cppSite: "TypeCheck.cpp:2594")
        }

        if case .typeConstructor = shaderModule.types[inferredType] {
            throw CompilationMessage(
                text: "type '\(ShaderModule.typeString(inferredType, in: &shaderModule))' requires template arguments",
                span: shaderModule.span(of: type)
            )
        }

        shaderModule.setEvaluation(.constant, for: type)
        shaderModule.setInferredType(inferredType, for: type)
        self.inferredType = nil
        currentEvaluation = nil

        return inferredType
    }

    mutating func evaluated(_ evaluation: Evaluation) {
        assert(currentEvaluation == nil)
        currentEvaluation = evaluation
    }

    mutating func inferred(_ type: TypeID) {
        assert(inferredType == nil)
        inferredType = type
    }

    mutating func unify(_ lhs: TypeID, _ rhs: TypeID) -> Bool {
        if lhs == rhs {
            return true
        }

        return shaderModule.types.conversionRank(rhs, lhs) != nil
    }

    mutating func introduceType(_ name: Identifier, _ type: TypeID) throws(CompilationMessage) {
        guard introduceVariable(name, Binding(kind: .type, type: type, evaluation: .runtime, constantValue: nil)) != nil else {
            throw CompilationMessage(text: "redeclaration of '\(shaderModule.symbols.text(of: name.symbol))'", span: name.span)
        }
    }

    mutating func convertValue(_ span: SourceSpan, _ type: TypeID, _ value: inout ConstantValue?) throws(CompilationMessage) {
        guard var convertedValue = value else {
            return
        }

        // Leaves convertedValue uniquely referenced, so the conversion happens in place.
        value = nil
        let converted = convertValueImpl(span, type, &convertedValue, shaderModule.types)
        value = convertedValue
        if !converted {
            if suppressConstantErrors {
                value = nil
                return
            }
            throw conversionError(span, type, convertedValue)
        }
    }

    mutating func conversionError(_ span: SourceSpan, _ type: TypeID, _ convertedValue: ConstantValue) -> CompilationMessage {
        CompilationMessage(
            text:
                "value \(shaderModule.dump(convertedValue)) cannot be represented as '\(ShaderModule.typeString(type, in: &shaderModule))'",
            span: span
        )
    }

    mutating func introduceValue(
        _ name: Identifier,
        _ type: TypeID,
        _ evaluation: Evaluation = .runtime,
        _ value: ConstantValue? = nil
    ) throws(CompilationMessage) {
        let binding = Binding(
            kind: .value,
            type: type,
            evaluation: evaluation,
            constantValue: value,
            declaredAfterContinue: declaringAfterContinue
        )
        guard introduceVariable(name, binding) != nil else {
            throw CompilationMessage(text: "redeclaration of '\(shaderModule.symbols.text(of: name.symbol))'", span: name.span)
        }
    }

    mutating func introduceFunction(_ name: Identifier, _ type: TypeID) throws(CompilationMessage) {
        guard introduceVariable(name, Binding(kind: .function, type: type, evaluation: .runtime, constantValue: nil)) != nil else {
            throw CompilationMessage(text: "redeclaration of '\(shaderModule.symbols.text(of: name.symbol))'", span: name.span)
        }
    }
}

@_spi(Testing)
public func typeCheck(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    var typeChecker = TypeChecker(shaderModule: shaderModule)
    let result = typeChecker.check()
    shaderModule = typeChecker.shaderModule
    return result
}

extension TypeChecker {
    /// C++ `allocateSimpleConstructor(name, constructor, validate, arguments...)`: `kind` names the TypeStore factory, its
    /// arguments and the validator.
    mutating func allocateSimpleConstructor(_ name: StaticString, _ kind: Types.TypeConstructor.Kind) throws(CompilationMessage) {
        try introduceType(shaderModule.makeIdentifier(name), shaderModule.types.typeConstructorType(kind))
    }

    /// The type constructor allocateSimpleConstructor introduces: one template argument, the element type.
    mutating func simpleConstructorElementType(
        _ type: ElaboratedTypeExpression,
        _ id: ExpressionID,
        _ validator: SimpleConstructorValidator
    ) throws(CompilationMessage) -> TypeID {
        guard shaderModule.count(type.arguments) == 1 else {
            throw CompilationMessage(
                text: "'\(shaderModule.symbols.text(of: shaderModule.symbol(of: type.base)))' requires 1 template argument",
                span: shaderModule.span(of: id)
            )
        }

        let elementType = try resolve(shaderModule[type.arguments, 0])

        if let error = Self.validate(validator, elementType, shaderModule.types) {
            throw CompilationMessage(text: error, span: shaderModule.span(of: id))
        }

        return elementType
    }

    mutating func allocateTextureStorageConstructor(_ name: StaticString, _ kind: Types.TextureStorage.Kind) throws(CompilationMessage) {
        try introduceType(shaderModule.makeIdentifier(name), shaderModule.types.typeConstructorType(.textureStorage(kind)))
    }

    /// The type constructor allocateTextureStorageConstructor introduces.
    mutating func constructTextureStorage(
        _ kind: Types.TextureStorage.Kind,
        _ type: ElaboratedTypeExpression,
        _ id: ExpressionID
    ) throws(CompilationMessage) -> TypeID {
        guard shaderModule.count(type.arguments) == 2 else {
            throw CompilationMessage(
                text: "'\(shaderModule.symbols.text(of: shaderModule.symbol(of: type.base)))' requires 2 template argument",
                span: shaderModule.span(of: id)
            )
        }

        let format = try texelFormat(shaderModule[type.arguments, 0])
        let access = try accessMode(shaderModule[type.arguments, 1])

        return shaderModule.types.textureStorageType(kind, format, access)
    }

    mutating func texelFormat(_ expression: ExpressionID) throws(CompilationMessage) -> TexelFormat {
        let formatType = try infer(expression, .runtime)

        guard unify(formatType, shaderModule.types.texelFormatType) else {
            throw CompilationMessage(
                text: "cannot use '\(ShaderModule.typeString(formatType, in: &shaderModule))' as texel format",
                span: shaderModule.span(of: expression)
            )
        }

        let formatName = shaderModule.downcast(IdentifierExpression.self, expression).identifier
        let format = parseTexelFormat(shaderModule.symbols.codeUnitsView(of: shaderModule.symbol(of: formatName)))
        assert(format != nil)
        guard let format else {
            wgslFatal("not a texel format", cppSite: "TypeCheck.cpp:2742")
        }

        return format
    }

    mutating func accessMode(_ expression: ExpressionID) throws(CompilationMessage) -> AccessMode {
        let accessType = try infer(expression, .runtime)

        guard unify(accessType, shaderModule.types.accessModeType) else {
            throw CompilationMessage(
                text: "cannot use '\(ShaderModule.typeString(accessType, in: &shaderModule))' as access mode",
                span: shaderModule.span(of: expression)
            )
        }

        let accessName = shaderModule.downcast(IdentifierExpression.self, expression).identifier
        let accessMode = parseAccessMode(shaderModule.symbols.codeUnitsView(of: shaderModule.symbol(of: accessName)))
        assert(accessMode != nil)
        guard let accessMode else {
            wgslFatal("not an access mode", cppSite: "TypeCheck.cpp:2756")
        }

        return accessMode
    }

    mutating func addressSpace(_ expression: ExpressionID) throws(CompilationMessage) -> AddressSpace {
        let addressSpaceType = try infer(expression, .runtime)

        guard unify(addressSpaceType, shaderModule.types.addressSpaceType) else {
            throw CompilationMessage(
                text: "cannot use '\(ShaderModule.typeString(addressSpaceType, in: &shaderModule))' as address space",
                span: shaderModule.span(of: expression)
            )
        }

        let addressSpaceName = shaderModule.downcast(IdentifierExpression.self, expression).identifier
        let addressSpace = parseAddressSpace(shaderModule.symbols.codeUnitsView(of: shaderModule.symbol(of: addressSpaceName)))
        assert(addressSpace != nil)
        guard let addressSpace else {
            wgslFatal("not an address space", cppSite: "TypeCheck.cpp:2770")
        }

        return addressSpace
    }

    mutating func setConstantValue(
        _ expression: ExpressionID,
        _ type: TypeID,
        _ value: consuming ConstantValue
    ) throws(CompilationMessage) {
        var constantValue: ConstantValue? = consume value
        defer { shaderModule.setConstantValue(constantValue, for: expression) }
        try convertValue(shaderModule.span(of: expression), type, &constantValue)
    }

    mutating func isModuleScope() -> Bool {
        returnType == nil
    }
}

/// C++ the `validate` lambda an `allocateSimpleConstructor` call captures: an enum, so a type constructor captures nothing
/// (the C++ closures captured the lambdas by reference).
enum SimpleConstructorValidator {
    case vector
    case matrix
    case texture
}

/// The C++ `CallArguments` of `chooseOverload`, a call's argument list or an operator's operands.
enum CallArguments {
    case list(ListID<ExpressionID>)
    case unary(ExpressionID)
    case binary(ExpressionID, ExpressionID)

    func count(_ shaderModule: borrowing ShaderModule) -> Int {
        switch self {
        case .list(let list):
            return shaderModule.count(list)
        case .unary:
            return 1
        case .binary:
            return 2
        }
    }

    /// C++ `callArguments[index]`.
    func argument(_ index: Int, _ shaderModule: borrowing ShaderModule) -> ExpressionID {
        switch self {
        case .list(let list):
            return shaderModule[list, index]
        case .unary(let expression):
            guard index == 0 else {
                wgslFatal("operand index out of range", cppSite: "TypeCheck.cpp:1966")
            }
            return expression
        case .binary(let leftExpression, let rightExpression):
            guard index == 0 || index == 1 else {
                wgslFatal("operand index out of range", cppSite: "TypeCheck.cpp:1458")
            }
            return index == 0 ? leftExpression : rightExpression
        }
    }
}

extension TypeChecker {
    /// C++ `TypeConstructor::construct(type)`: runs the constructor declareBuiltins introduced under `constructor.kind`.
    mutating func construct(
        _ constructor: Types.TypeConstructor,
        _ type: ElaboratedTypeExpression,
        _ id: ExpressionID
    ) throws(CompilationMessage) -> TypeID {
        switch constructor.kind {
        case .pointer:
            return try constructPointer(type, id)
        case .atomic:
            return try constructAtomic(type, id)
        case .vector(let size):
            let elementType = try simpleConstructorElementType(type, id, .vector)
            return shaderModule.types.vectorType(size, elementType)
        case .matrix(let columns, let rows):
            let elementType = try simpleConstructorElementType(type, id, .matrix)
            return shaderModule.types.matrixType(columns, rows, elementType)
        case .texture(let kind):
            let elementType = try simpleConstructorElementType(type, id, .texture)
            return shaderModule.types.textureType(kind, elementType)
        case .textureStorage(let kind):
            return try constructTextureStorage(kind, type, id)
        }
    }

    /// C++ `convertValue(expression.span(), type, expression.m_constantValue)`: converts the expression's own value in place.
    mutating func convertValue(_ span: SourceSpan, _ type: TypeID, of expression: ExpressionID) throws(CompilationMessage) {
        var converted = true
        let suppressed = suppressConstantErrors
        _ = shaderModule.modifyConstantValue(of: expression) { value, types in
            converted = convertValueImpl(span, type, &value, types)
            return converted || !suppressed
        }
        if !converted && !suppressed {
            throw conversionError(span, type, of: expression)
        }
    }

    /// The error of a failed, unsuppressed conversion of the expression's own value, which keeps the value.
    @inline(never)
    mutating func conversionError(_ span: SourceSpan, _ type: TypeID, of expression: ExpressionID) -> CompilationMessage {
        guard let convertedValue = shaderModule.constantValue(of: expression) else {
            wgslFatal("a failed conversion dropped the value", cppSite: "TypeCheck.cpp:2663")
        }
        return conversionError(span, type, convertedValue)
    }

    /// C++ `introduceValue(AST::Identifier::make("…"_s), type)` for the predeclared access modes, texel formats and address
    /// spaces, whose name is `.builtin` (`SymbolTable.intern(predeclaredValue:)`).
    mutating func introducePredeclaredValue(_ name: StaticString, _ type: TypeID) throws(CompilationMessage) {
        let symbol = shaderModule.symbols.intern(predeclaredValue: name)
        try introduceValue(shaderModule.makeIdentifier(symbol), type)
    }

    // The ContextProvider<Binding> members, reachable unqualified as in C++.

    mutating func introduceVariable(_ name: Identifier, _ value: Binding) -> Binding? {
        context.introduceVariable(name.symbol, value)
    }

    mutating func readVariable(_ name: Identifier) -> Binding? {
        context.readVariable(name.symbol)
    }

    mutating func readVariable(_ name: Symbol) -> Binding? {
        context.readVariable(name)
    }

    /// C++ `ContextScope scope(this);`; close it with `closeContextScope` in a `defer`.
    mutating func openContextScope() -> ContextProvider<Binding>.Scope {
        context.openScope()
    }

    mutating func closeContextScope(_ scope: ContextProvider<Binding>.Scope) {
        context.closeScope(scope)
    }
}
