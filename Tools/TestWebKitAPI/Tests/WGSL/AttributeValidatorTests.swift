// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (C) 2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

import Testing
@_spi(Testing) import WGSL

// Each expected message, span and layout is what the C++ compiler reported for the same source when it stopped after
// validateAttributes (a Debug build, unless a test says release). The C++ sources end with a newline, which only the spans
// of declarations and directives include. The C++ type checker accepts every source except those of
// `attributeWithoutAConstantValue`; `typeForAttributeValidator` sets what AttributeValidator reads as the C++ type checker
// does on these sources.

/// Sets the constant value of every integer literal and of the negation of one, as C++ TypeCheck does for attribute values.
private struct ConstantTyper: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func visit(_ literal: AbstractIntegerLiteral, _ id: ExpressionID) {
        shaderModule.setConstantValue(.int64(literal.value), for: id)
    }

    mutating func visit(_ literal: Signed32Literal, _ id: ExpressionID) {
        shaderModule.setConstantValue(.int32(literal.value), for: id)
    }

    mutating func visit(_ literal: Unsigned32Literal, _ id: ExpressionID) {
        shaderModule.setConstantValue(.uint32(literal.value), for: id)
    }

    mutating func visit(_ unary: UnaryExpression, _ id: ExpressionID) {
        visitChildren(unary, id)
        guard unary.operation == .negate, case .int64(let value) = shaderModule.constantValue(of: unary.expression) else {
            return
        }
        shaderModule.setConstantValue(.int64(0 &- value), for: id)
    }
}

private func text(_ module: borrowing ShaderModule, _ symbol: Symbol) -> String {
    String(decoding: module.symbols.codeUnits(of: symbol), as: UTF16.self)
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    text(module, module.symbol(of: identifier))
}

/// The type a type expression names: scalars, `vecN<T>` and the `vecNf`/`vecNi`/`vecNu` aliases, `array<T, N>`,
/// `array<T>`, and the structures and aliases in `names`.
private func resolveType(_ module: inout ShaderModule, _ names: [Symbol: TypeID], _ expression: ExpressionID) -> TypeID? {
    var type: TypeID?
    switch module[expression].kind {
    case .identifierExpression(let identifier):
        let symbol = module.symbol(of: identifier.identifier)
        switch text(module, symbol) {
        case "f32": type = module.types.f32Type
        case "i32": type = module.types.i32Type
        case "u32": type = module.types.u32Type
        case "bool": type = module.types.boolType
        case "vec2f": type = module.types.vectorType(2, module.types.f32Type)
        case "vec3f": type = module.types.vectorType(3, module.types.f32Type)
        case "vec4f": type = module.types.vectorType(4, module.types.f32Type)
        case "vec4i": type = module.types.vectorType(4, module.types.i32Type)
        case "vec4u": type = module.types.vectorType(4, module.types.u32Type)
        default: type = names[symbol]
        }
    case .elaboratedTypeExpression(let elaborated):
        let arguments = module.elements(elaborated.arguments)
        guard arguments.count == 1, let element = resolveType(&module, names, arguments[0]) else {
            break
        }
        switch text(module, elaborated.base) {
        case "vec2": type = module.types.vectorType(2, element)
        case "vec3": type = module.types.vectorType(3, element)
        case "vec4": type = module.types.vectorType(4, element)
        default: break
        }
    case .arrayTypeExpression(let array):
        guard let elementType = array.maybeElementType, let element = resolveType(&module, names, elementType) else {
            break
        }
        var size = Types.Array.Size.runtime
        if let count = array.maybeElementCount, case .abstractIntegerLiteral(let literal) = module[count].kind {
            size = .creationFixed(UInt32(literal.value))
        }
        type = module.types.arrayType(element, size)
    default:
        break
    }
    if let type {
        module.setInferredType(type, for: expression)
    }
    return type
}

/// Types the type expressions of structure members, aliases, module-scope variables, parameters and return types, sets the
/// store type and address space of module-scope variables, and the constant values of attribute arguments.
private func typeForAttributeValidator(_ module: inout ShaderModule) {
    var names: [Symbol: TypeID] = [:]
    for declaration in module.elements(module.declarations) {
        switch declaration {
        case .structure(let structure):
            for member in module.elements(module[structure].members) {
                _ = resolveType(&module, names, module[member].type)
            }
            let type = module.types.structType(structure)
            module.modify(structure) { $0.inferredType = type }
            names[module.symbol(of: module[structure].name)] = type
        case .typeAlias(let alias):
            names[module.symbol(of: module[alias].name)] = resolveType(&module, names, module[alias].type)
        case .variable(let variable):
            var storeType: TypeID?
            if let typeName = module[variable].maybeTypeName {
                storeType = resolveType(&module, names, typeName)
            }
            let addressSpace = module[variable].maybeQualifier?.addressSpace
            module.modify(variable) {
                $0.storeType = storeType
                $0.addressSpace = addressSpace
            }
        case .function(let function):
            for parameter in module.elements(module[function].parameters) {
                _ = resolveType(&module, names, module[parameter].typeName)
            }
            if let returnType = module[function].maybeReturnType {
                _ = resolveType(&module, names, returnType)
            }
        case .constAssert:
            break
        }
    }
    var typer = ConstantTyper(shaderModule: module)
    typer.visitShaderModule()
    module = typer.shaderModule
}

private struct Validated: ~Copyable {
    var module: ShaderModule
    let failure: FailedCheck?
}

private func validated(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) -> Validated {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        logCompilationError(failure, sourceLocation: sourceLocation)
    }
    if let failure = reorderGlobals(&module) {
        logCompilationError(failure, sourceLocation: sourceLocation)
    }
    typeForAttributeValidator(&module)
    let failure = validateAttributes(&module)
    return Validated(module: module, failure: failure)
}

private func span(_ line: UInt32, _ lineOffset: UInt32, _ offset: UInt32, _ length: UInt32) -> SourceSpan {
    SourceSpan(line: line, lineOffset: lineOffset, offset: offset, length: length)
}

private func expectError(_ failure: FailedCheck?, _ message: String, _ span: SourceSpan, sourceLocation: SourceLocation = #_sourceLocation)
{
    guard let failure else {
        Issue.record("expected the error \"\(message)\"", sourceLocation: sourceLocation)
        return
    }
    #expect(failure.errors.map(\.message) == [message], sourceLocation: sourceLocation)
    #expect(failure.errors.first?.span == span, sourceLocation: sourceLocation)
    #expect(failure.warnings.isEmpty, sourceLocation: sourceLocation)
}

private func expectNoFailure(_ failure: FailedCheck?, sourceLocation: SourceLocation = #_sourceLocation) {
    if let failure {
        logCompilationError(failure, sourceLocation: sourceLocation)
    }
}

private func function(_ module: borrowing ShaderModule, _ name: String) -> FunctionID? {
    for declaration in module.elements(module.declarations) {
        if case .function(let function) = declaration, text(module, module[function].name) == name {
            return function
        }
    }
    return nil
}

private func variable(_ module: borrowing ShaderModule, _ name: String) -> VariableID? {
    for declaration in module.elements(module.declarations) {
        if case .variable(let variable) = declaration, text(module, module[variable].name) == name {
            return variable
        }
    }
    return nil
}

private func structure(_ module: borrowing ShaderModule, _ name: String) -> StructureID? {
    for declaration in module.elements(module.declarations) {
        if case .structure(let structure) = declaration, text(module, module[structure].name) == name {
            return structure
        }
    }
    return nil
}

private func parameters(_ module: borrowing ShaderModule, _ function: FunctionID?) -> [Parameter] {
    guard let function else {
        return []
    }
    return module.elements(module[function].parameters).map { module[$0] }
}

/// The C++ layout of a structure: its size and alignment, then size, align, offset and padding per member.
private struct Layout: Equatable, CustomStringConvertible {
    var size: UInt32?
    var alignment: UInt32?
    var hasSizeOrAlignmentAttributes: Bool
    var members: [[UInt32?]]

    var description: String {
        "size=\(String(describing: size)) align=\(String(describing: alignment)) attrs=\(hasSizeOrAlignmentAttributes) members=\(members)"
    }
}

private func layout(_ module: borrowing ShaderModule, _ structure: StructureID?) -> Layout? {
    guard let structure else {
        return nil
    }
    let node = module[structure]
    let members = module.elements(node.members)
        .map { member -> [UInt32?] in
            let member = module[member]
            return [member.size, member.alignment, member.offset, member.padding]
        }
    return Layout(
        size: node.size,
        alignment: node.alignment,
        hasSizeOrAlignmentAttributes: node.hasSizeOrAlignmentAttributes,
        members: members
    )
}

struct AttributeErrorCase: Sendable, CustomTestStringConvertible {
    let source: String
    let message: String
    let span: SourceSpan

    init(_ source: String, _ message: String, _ span: SourceSpan) {
        self.source = source
        self.message = message
        self.span = span
    }

    var testDescription: String { source }
}

private let assertionsAreEnabled = _isDebugAssertConfiguration()

@Suite
struct WGSLAttributeValidatorTests {
    // MARK: - Hook-fires tests: one input per overridden hook on which it provably runs.

    @Test
    func diagnosticDirectiveSetsTheModuleSeverity() {
        let result = validated("diagnostic(off, derivative_uniformity);\ndiagnostic(off, derivative_uniformity);")
        expectNoFailure(result.failure)
        #expect(result.module.severityFor(.derivativeUniformity) == .off)
        #expect(result.module.severityFor(.subgroupUniformity) == nil)
    }

    @Test
    func diagnosticDirectiveConflict() {
        let result = validated("diagnostic(off, derivative_uniformity);\ndiagnostic(error, derivative_uniformity);\n")
        expectError(result.failure, "conflicting diagnostic directive", span(1, 0, 0, 82))
    }

    @Test
    func functionAndParameterAttributes() {
        let result = validated(
            """
            @compute @workgroup_size(8, 4, 1) fn main() { }
            @vertex fn vs() -> @builtin(position) @invariant vec4f { return vec4f(); }
            @must_use fn f() -> i32 { return 1; }
            @fragment fn fs(@location(0) @interpolate(flat, either) a: u32, @builtin(position) p: vec4f) -> @location(1) vec4f { return vec4f(); }
            """
        )
        expectNoFailure(result.failure)
        let module = result.module

        let main = function(module, "main").map { module[$0] }
        #expect(main?.stage == .compute)
        #expect(main?.workgroupSize != nil)
        #expect(main?.workgroupSize?.y != nil && main?.workgroupSize?.z != nil)
        #expect(main?.mustUse == false)

        let vs = function(module, "vs").map { module[$0] }
        #expect(vs?.stage == .vertex)
        #expect(vs?.workgroupSize == nil)
        #expect(vs?.returnTypeBuiltin == .position)
        #expect(vs?.returnTypeInvariant == true)
        #expect(vs?.returnTypeLocation == nil)

        let f = function(module, "f").map { module[$0] }
        #expect(f?.stage == nil)
        #expect(f?.mustUse == true)

        let fs = function(module, "fs")
        #expect(fs.map { module[$0].stage } == .fragment)
        #expect(fs.map { module[$0].returnTypeLocation } == 1)
        let parameters = parameters(module, fs)
        #expect(parameters.count == 2)
        #expect(parameters.first?.location == 0)
        #expect(parameters.first?.interpolation == Interpolation(type: .flat, sampling: .either))
        #expect(parameters.first?.builtin == nil)
        #expect(parameters.last?.builtin == .position)
        #expect(parameters.last?.location == nil)
        #expect(parameters.last?.invariant == false)
    }

    @Test
    func workgroupSizeWithoutAConstantValue() {
        let result = validated("override w: i32 = 0;\n@compute @workgroup_size(w) fn main() { }")
        expectNoFailure(result.failure)
        let main = function(result.module, "main").map { result.module[$0] }
        #expect(main?.stage == .compute)
        #expect(main?.workgroupSize != nil)
        #expect(main?.workgroupSize?.y == nil)
    }

    @Test(arguments: [
        AttributeErrorCase("@must_use fn f() { }", "@must_use can only be applied to functions that return a value", span(1, 0, 0, 10)),
        AttributeErrorCase(
            "@compute @workgroup_size(8, 0) fn main() { }",
            "@workgroup_size argument must be at least 1",
            span(1, 28, 28, 1)
        ),
        AttributeErrorCase(
            "@vertex @workgroup_size(8) fn main() -> @builtin(position) vec4f { return vec4f(); }\n",
            "@workgroup_size must only be applied to compute shader entry point function",
            span(1, 27, 27, 58)
        ),
        AttributeErrorCase("@group(0) fn main() { }", "invalid attribute for function declaration", span(1, 0, 0, 10)),
        AttributeErrorCase(
            "@diagnostic(off, derivative_uniformity) @diagnostic(off, derivative_uniformity) fn f() { }",
            "duplicate @diagnostic attribute",
            span(1, 40, 40, 40)
        ),
        AttributeErrorCase(
            "@vertex fn main() -> @align(4) vec4f { return vec4f(); }",
            "invalid attribute for function return type",
            span(1, 21, 21, 10)
        ),
        AttributeErrorCase(
            "@compute @workgroup_size(1) fn main() -> @location(0) vec4f { return vec4f(); }",
            "@location may not be used in the compute shader stage",
            span(1, 41, 41, 13)
        ),
        AttributeErrorCase(
            "fn f() -> @location(0) vec4f { return vec4f(); }",
            "@location is not valid for non-entry point function types",
            span(1, 10, 10, 13)
        ),
        AttributeErrorCase(
            "@vertex @vertex fn main() -> @builtin(position) vec4f { return vec4f(); }",
            "duplicate attribute",
            span(1, 8, 8, 8)
        ),
    ])
    func functionErrors(_ errorCase: AttributeErrorCase) {
        expectError(validated(errorCase.source).failure, errorCase.message, errorCase.span)
    }

    @Test(arguments: [
        AttributeErrorCase(
            "fn f(@builtin(position) p: vec4f) { }",
            "@builtin is not valid for non-entry point function types",
            span(1, 5, 5, 19)
        ),
        AttributeErrorCase(
            "struct S { x: f32 }\n@fragment fn main(@location(0) s: S) { }",
            "@location must only be applied to declarations of numeric scalar or numeric vector type",
            span(2, 18, 38, 13)
        ),
        AttributeErrorCase("@fragment fn main(@size(4) a: f32) { }", "invalid attribute for function parameter", span(1, 18, 18, 9)),
        AttributeErrorCase(
            "@fragment fn main(@interpolate(perspective, center) @builtin(position) p: vec4f) { }",
            "@interpolate is only allowed on declarations that have a @location attribute",
            span(1, 18, 18, 61)
        ),
        AttributeErrorCase(
            "@fragment fn main(@invariant @location(0) a: f32) { }",
            "@invariant is only allowed on declarations that have a @builtin(position) attribute",
            span(1, 18, 18, 30)
        ),
    ])
    func parameterErrors(_ errorCase: AttributeErrorCase) {
        expectError(validated(errorCase.source).failure, errorCase.message, errorCase.span)
    }

    @Test
    func variableAttributes() {
        let result = validated(
            """
            struct S { a: f32, b: vec3f }
            @group(1) @binding(2) var<storage> s: S;
            @id(7) override o: i32;
            @group(0) @binding(0) var<uniform> u: vec4f;
            """
        )
        expectNoFailure(result.failure)
        let module = result.module

        let s = variable(module, "s").map { module[$0] }
        #expect(s?.group == 1)
        #expect(s?.binding == 2)
        #expect(s?.id == nil)

        let o = variable(module, "o").map { module[$0] }
        #expect(o?.id == 7)
        #expect(o?.group == nil)
        let containsOverrideID = module.containsOverrideID(7)
        #expect(containsOverrideID)

        let u = variable(module, "u").map { module[$0] }
        #expect(u?.group == 0)
        #expect(u?.binding == 0)

        #expect(
            layout(module, structure(module, "S"))
                == Layout(size: 32, alignment: 16, hasSizeOrAlignmentAttributes: false, members: [[4, 4, 0, 12], [12, 16, 16, 4]])
        )
    }

    @Test(arguments: [
        AttributeErrorCase(
            "@binding(0) var<private> x: f32;",
            "@binding attribute must only be applied to resource variables",
            span(1, 0, 0, 12)
        ),
        AttributeErrorCase(
            "@group(0) var<private> x: f32;",
            "@group attribute must only be applied to resource variables",
            span(1, 0, 0, 10)
        ),
        AttributeErrorCase(
            "@group(0) @binding(-1) var<storage> s: array<f32>;",
            "@binding value must be non-negative",
            span(1, 10, 10, 13)
        ),
        AttributeErrorCase("@group(-1) @binding(0) var<storage> s: array<f32>;", "@group value must be non-negative", span(1, 0, 0, 11)),
        AttributeErrorCase(
            "@binding(0) var<storage> s: array<f32>;",
            "resource variables require @group and @binding attributes",
            span(1, 12, 12, 26)
        ),
        AttributeErrorCase("@id(0) var<private> x: f32;", "@id attribute must only be applied to override variables", span(1, 0, 0, 7)),
        AttributeErrorCase("@id(-1) override o: i32;", "@id value must be non-negative", span(1, 0, 0, 8)),
        AttributeErrorCase("@id(65536) override o: i32;", "@id value must be between 0 and 65535", span(1, 0, 0, 11)),
        AttributeErrorCase("@id(1) override o: i32;\n@id(1) override p: i32;", "@id value must be unique", span(2, 0, 24, 7)),
        AttributeErrorCase("@location(0) var<private> x: f32;", "invalid attribute for variable declaration", span(1, 0, 0, 13)),
        AttributeErrorCase("@group(0) @binding(0) @binding(1) var<storage> s: array<f32>;", "duplicate attribute", span(1, 22, 22, 12)),
    ])
    func variableErrors(_ errorCase: AttributeErrorCase) {
        expectError(validated(errorCase.source).failure, errorCase.message, errorCase.span)
    }

    @Test
    func structureLayout() {
        let result = validated("struct S { a: f32, @align(16) b: f32, @size(12) c: vec2f, d: vec3f }")
        expectNoFailure(result.failure)
        #expect(
            layout(result.module, structure(result.module, "S"))
                == Layout(
                    size: 64,
                    alignment: 16,
                    hasSizeOrAlignmentAttributes: true,
                    members: [[4, 4, 0, 12], [4, 16, 16, 4], [12, 8, 24, 16], [12, 16, 48, 4]]
                )
        )
    }

    @Test
    func structureMemberIOAttributes() {
        let result = validated(
            "struct S { @builtin(position) @invariant a: vec4f, @location(0) @interpolate(linear, sample) b: f32 }"
        )
        expectNoFailure(result.failure)
        let module = result.module
        let members = structure(module, "S").map { module.elements(module[$0].members).map { module[$0] } } ?? []
        #expect(members.count == 2)
        #expect(members.first?.builtin == .position)
        #expect(members.first?.invariant == true)
        #expect(members.last?.location == 0)
        #expect(members.last?.interpolation == Interpolation(type: .linear, sampling: .sample))
        #expect(
            layout(module, structure(module, "S"))
                == Layout(size: 32, alignment: 16, hasSizeOrAlignmentAttributes: false, members: [[16, 16, 0, 0], [4, 4, 16, 12]])
        )
    }

    @Test(arguments: [
        AttributeErrorCase(
            "struct S { @size(2) a: f32 }",
            "@size value must be at least the byte-size of the type of the member",
            span(1, 11, 11, 9)
        ),
        AttributeErrorCase("struct S { @size(-4) a: f32 }", "@size value must be non-negative", span(1, 11, 11, 10)),
        AttributeErrorCase(
            "struct S { @size(16) a: array<f32> }",
            "@size can only be applied to members that have a type with a size that is fully determined at shader creation time.",
            span(1, 11, 11, 10)
        ),
        AttributeErrorCase("struct S { @align(0) a: f32 }", "@align value must be positive", span(1, 11, 11, 10)),
        AttributeErrorCase("struct S { @align(3) a: f32 }", "@align value must be a power of two", span(1, 11, 11, 10)),
        AttributeErrorCase(
            "struct S { @align(2) a: f32 }",
            "@align attribute 2 of struct member is not a multiple of the type's alignment 4",
            span(1, 11, 11, 10)
        ),
        AttributeErrorCase("struct S { @group(0) a: f32 }", "invalid attribute for structure member", span(1, 11, 11, 10)),
        AttributeErrorCase(
            "struct S { @location(0) a: array<f32, 2> }",
            "@location must only be applied to declarations of numeric scalar or numeric vector type",
            span(1, 11, 11, 13)
        ),
        AttributeErrorCase("struct S { @size(8) @size(16) a: f32 }", "duplicate attribute", span(1, 20, 20, 10)),
    ])
    func structureMemberErrors(_ errorCase: AttributeErrorCase) {
        expectError(validated(errorCase.source).failure, errorCase.message, errorCase.span)
    }

    @Test(arguments: [
        AttributeErrorCase(
            "@fragment fn main() { @diagnostic(off, derivative_uniformity) @diagnostic(error, derivative_uniformity) { } }",
            "duplicate @diagnostic attribute",
            span(1, 62, 62, 42)
        ),
        AttributeErrorCase("@fragment fn main() { @align(4) { } }", "invalid attribute for compound statement", span(1, 22, 22, 10)),
        AttributeErrorCase(
            "fn f() @diagnostic(off, derivative_uniformity) @diagnostic(off, derivative_uniformity) { }",
            "duplicate @diagnostic attribute",
            span(1, 47, 47, 40)
        ),
        AttributeErrorCase(
            "@fragment fn main() { @align(4) for (;;) { break; } }",
            "invalid attribute for `for` statement",
            span(1, 22, 22, 10)
        ),
        AttributeErrorCase(
            "@fragment fn main() { @align(4) while true { break; } }",
            "invalid attribute for compound statement",
            span(1, 22, 22, 10)
        ),
        AttributeErrorCase(
            "@fragment fn main() { @align(4) loop { break; } }",
            "invalid attribute for `loop` statement",
            span(1, 22, 22, 10)
        ),
        AttributeErrorCase("@fragment fn main() { loop @align(4) { break; } }", "invalid attribute for `loop` body", span(1, 27, 27, 10)),
        AttributeErrorCase(
            "@fragment fn main() { loop { continuing @align(4) { break if true; } } }",
            "invalid attribute for `continuing` body",
            span(1, 40, 40, 10)
        ),
        AttributeErrorCase(
            "@fragment fn main() { loop { continuing @diagnostic(off, derivative_uniformity) @diagnostic(off, derivative_uniformity) { break if true; } } }",
            "duplicate @diagnostic attribute",
            span(1, 80, 80, 40)
        ),
        AttributeErrorCase(
            "@fragment fn main() { @align(4) switch 1 { default { } } }",
            "invalid attribute for `switch` statement",
            span(1, 22, 22, 10)
        ),
        AttributeErrorCase(
            "@fragment fn main() { switch 1 @align(4) { default { } } }",
            "invalid attribute for `switch` body",
            span(1, 31, 31, 10)
        ),
        AttributeErrorCase(
            "@fragment fn main() { switch 1 @diagnostic(off, derivative_uniformity) @diagnostic(off, derivative_uniformity) { default { } } }",
            "duplicate @diagnostic attribute",
            span(1, 71, 71, 40)
        ),
        AttributeErrorCase("@fragment fn main() { @align(4) if true { } }", "invalid attribute for `if` statement", span(1, 22, 22, 10)),
    ])
    func statementErrors(_ errorCase: AttributeErrorCase) {
        expectError(validated(errorCase.source).failure, errorCase.message, errorCase.span)
    }

    @Test
    func statementDiagnosticsAreRecorded() {
        let result = validated(
            """
            @fragment fn main() { @diagnostic(off, derivative_uniformity) { } \
            loop @diagnostic(info, derivative_uniformity) { continuing @diagnostic(warning, subgroup_uniformity) { break if true; } } \
            switch 1 @diagnostic(off, subgroup_uniformity) { default { } } }
            """
        )
        expectNoFailure(result.failure)
        let module = result.module
        guard let main = function(module, "main"), case .compoundStatement(let body) = module[module[main].body].kind else {
            Issue.record("no function body")
            return
        }
        let statements = module.elements(body.statements)
        #expect(statements.count == 3)
        guard statements.count == 3 else {
            return
        }
        #expect(module[statements[0]].diagnostics.severityFor(.derivativeUniformity) == .off)
        #expect(module[statements[0]].diagnostics.severityFor(.subgroupUniformity) == nil)
        guard case .loopStatement(let loop) = module[statements[1]].kind,
            case .switchStatement(let switchStatement) = module[statements[2]].kind
        else {
            Issue.record("expected a loop and a switch")
            return
        }
        #expect(loop.bodyDiagnostics.severityFor(.derivativeUniformity) == .info)
        #expect(module[statements[1]].diagnostics.severityFor(.derivativeUniformity) == nil)
        #expect(loop.continuing?.diagnostics.severityFor(.subgroupUniformity) == .warning)
        #expect(loop.continuing?.diagnostics.severityFor(.derivativeUniformity) == nil)
        #expect(switchStatement.bodyDiagnostics.severityFor(.subgroupUniformity) == .off)
    }

    @Test
    func functionDiagnosticsAreRecorded() {
        let result = validated("@diagnostic(off, derivative_uniformity) @diagnostic(info, subgroup_uniformity) fn f() { }")
        expectNoFailure(result.failure)
        let f = function(result.module, "f").map { result.module[$0] }
        #expect(f?.diagnostics.severityFor(.derivativeUniformity) == .off)
        #expect(f?.diagnostics.severityFor(.subgroupUniformity) == .info)
    }

    // MARK: - Missing constant values (white-box: the C++ type checker rejects an override value first)

    @Test(arguments: [
        AttributeErrorCase(
            "override b: i32 = 0;\n@group(0) @binding(b) var<storage> s: array<f32>;",
            "@binding attribute must only be applied to resource variables",
            span(2, 10, 31, 12)
        ),
        AttributeErrorCase(
            "override g: i32 = 0;\n@group(g) @binding(0) var<storage> s: array<f32>;",
            "@group attribute must only be applied to resource variables",
            span(2, 0, 21, 10)
        ),
        AttributeErrorCase(
            "override l: i32 = 0;\n@fragment fn main(@location(l) a: f32) { }",
            "@location constant value is missing",
            span(2, 18, 39, 13)
        ),
        AttributeErrorCase("override o: i32 = 8;\nstruct S { @size(o) a: f32 }", "@size constant value is not found", span(2, 11, 32, 9)),
        AttributeErrorCase(
            "override o: i32 = 8;\nstruct S { @align(o) a: f32 }",
            "@align constant value does not exist",
            span(2, 11, 32, 10)
        ),
    ])
    func attributeWithoutAConstantValue(_ errorCase: AttributeErrorCase) {
        expectError(validated(errorCase.source).failure, errorCase.message, errorCase.span)
    }

    // MARK: - validateAlignment

    @Test(arguments: [
        AttributeErrorCase(
            "struct S { a: array<f32, 4> }\n@group(0) @binding(0) var<uniform> u: S;",
            "arrays in the uniform address space must have a stride multiple of 16 bytes, but has a stride of 4 bytes",
            span(1, 11, 11, 17)
        ),
        AttributeErrorCase(
            "@group(0) @binding(0) var<uniform> u: array<vec2f, 4>;",
            "arrays in the uniform address space must have a stride multiple of 16 bytes, but has a stride of 8 bytes",
            span(1, 22, 22, 31)
        ),
        AttributeErrorCase(
            "struct T { x: f32 }\nstruct S { a: f32, b: T }\n@group(0) @binding(0) var<uniform> u: S;",
            "offset of struct member S::b must be a multiple of 16 bytes, but its offset is 4 bytes",
            span(2, 19, 39, 5)
        ),
        AttributeErrorCase(
            "struct T { x: f32 }\nstruct S { @align(16) a: T, b: f32 }\n@group(0) @binding(0) var<uniform> u: S;",
            "uniform address space requires that the number of bytes between S::a and S::b must be at least 16 bytes, but it is 4 bytes",
            span(2, 11, 31, 15)
        ),
    ])
    func alignmentErrors(_ errorCase: AttributeErrorCase) {
        expectError(validated(errorCase.source).failure, errorCase.message, errorCase.span)
    }

    @Test
    func nestedAlignment() {
        let result = validated(
            """
            struct T { x: vec4f }
            struct S { a: array<T, 2>, @align(16) b: T, c: array<vec4f, 3> }
            @group(0) @binding(0) var<uniform> u: S;
            @group(0) @binding(1) var<storage> s: array<S>;
            """
        )
        expectNoFailure(result.failure)
        #expect(
            layout(result.module, structure(result.module, "S"))
                == Layout(
                    size: 96,
                    alignment: 16,
                    hasSizeOrAlignmentAttributes: true,
                    members: [[32, 16, 0, 0], [16, 16, 32, 0], [48, 16, 48, 0]]
                )
        )
    }

    // MARK: - Saturating layout arithmetic

    @Test
    func saturatingStructure() {
        // @size(0xFFFFFFF0) then @size(32): the offsets and the size saturate at UINT_MAX, as CheckedUint32 does in the C++.
        let result = validated("struct S { @size(0xFFFFFFF0u) a: f32, @size(32) b: f32, c: f32 }")
        expectNoFailure(result.failure)
        #expect(
            layout(result.module, structure(result.module, "S"))
                == Layout(
                    size: UInt32.max,
                    alignment: 4,
                    hasSizeOrAlignmentAttributes: true,
                    members: [[0xFFFF_FFF0, 4, 0, 0xFFFF_FFEC], [32, 4, 0xFFFF_FFF0, 11], [4, 4, UInt32.max, 0]]
                )
        )
    }

    @Test
    func saturatingStructureInAResource() {
        let result = validated(
            "struct S { @size(0xFFFFFFF0u) a: f32, @size(32) b: f32, c: f32 }\n@group(0) @binding(0) var<storage> s: S;"
        )
        expectError(
            result.failure,
            "offset of struct member S::c must be a multiple of 4 bytes, but its offset is 4294967295 bytes",
            span(1, 56, 56, 7)
        )
    }

    // MARK: - Deviations

    @Test
    func duplicateStageAttribute() {
        // dupattr2.wgsl: one duplicate, so Debug C++ reports it too.
        let result = validated("@vertex @vertex fn main() -> @builtin(position) vec4f { return vec4f(); }")
        expectError(result.failure, "duplicate attribute", span(1, 8, 8, 8))
        #expect(function(result.module, "main").map { result.module[$0].stage } == .vertex)
    }

    // The tests below set a second error, which asserts in Debug C++ and in a Swift build with assertions. The expected
    // message is the last one, which a release build of the C++ compiler reports.

    @Test(.enabled(if: !assertionsAreEnabled))
    func DEV_08_DuplicateStageAttributeLastWins() {
        // dupattr.wgsl
        let result = validated("@vertex @vertex @vertex fn main() -> @builtin(position) vec4f { return vec4f(); }")
        expectError(result.failure, "duplicate attribute", span(1, 16, 16, 8))
        #expect(function(result.module, "main").map { result.module[$0].stage } == .vertex)
    }

    @Test(.enabled(if: !assertionsAreEnabled))
    func DEV_08_DuplicateBindingAttributeLastWins() {
        let result = validated("@group(0) @binding(0) @binding(1) @binding(2) var<storage> s: array<f32>;")
        expectError(result.failure, "duplicate attribute", span(1, 34, 34, 12))
        let s = variable(result.module, "s").map { result.module[$0] }
        #expect(s?.group == 0)
        #expect(s?.binding == 0)
    }

    @Test(.enabled(if: !assertionsAreEnabled))
    func DEV_08_InterpolationErrorLastWins() {
        let result = validated("@fragment fn main(@interpolate(flat, center) @builtin(position) p: vec4f) { }")
        expectError(
            result.failure,
            "flat interpolation attribute must have a sampling parameter of `first` or `either`",
            span(1, 18, 18, 54)
        )
    }

    @Test(.enabled(if: !assertionsAreEnabled))
    func DEV_08_AlignmentErrorAfterADuplicateAttribute() {
        let result = validated("@group(0) @binding(0) @binding(1) var<uniform> u: array<vec2f, 4>;")
        expectError(
            result.failure,
            "arrays in the uniform address space must have a stride multiple of 16 bytes, but has a stride of 8 bytes",
            span(1, 34, 34, 31)
        )
    }

    @Test
    func DEV_03_DeepStructureNesting() {
        // A chain of 10,000 structures, each the only member of the next: the C++ recurses once per structure.
        var source = "struct S0 { x: f32 }\n"
        for i in 1..<10_000 {
            source += "struct S\(i) { m: S\(i - 1) }\n"
        }
        source += "@group(0) @binding(0) var<uniform> v: S9999;\n"
        let result = validated(source)
        expectNoFailure(result.failure)
        #expect(
            layout(result.module, structure(result.module, "S9999"))
                == Layout(size: 4, alignment: 4, hasSizeOrAlignmentAttributes: false, members: [[4, 4, 0, 0]])
        )
        #expect(variable(result.module, "v").map { result.module[$0].binding } == 0)
    }

    @Test
    func DEV_03_DeepArrayNesting() {
        // A chain of 2,000 aliases, each an array of the previous one (the C++ times out on it).
        var source = "alias A0 = array<f32, 1>;\n"
        for i in 1..<2000 {
            source += "alias A\(i) = array<A\(i - 1), 1>;\n"
        }
        source += "@group(0) @binding(0) var<storage> v: A1999;\n"
        expectNoFailure(validated(source).failure)
    }

    @Test
    func DEV_04_SharedStructuresAreValidatedOnce() {
        // T12 reaches T0 along 4^12 paths. The C++ validates T0 once per path; validating each structure once reports the same
        // first error, the offset of U::c (16 * 4^12 + 4).
        var source = "struct T0 { x: vec4f }\n"
        for i in 1...12 {
            source += "struct T\(i) { m0: T\(i - 1), m1: T\(i - 1), m2: T\(i - 1), m3: T\(i - 1) }\n"
        }
        source += "struct S { x: f32 }\nstruct U { a: T12, b: f32, c: S }\n@group(0) @binding(0) var<uniform> u: U;\n"
        let result = validated(source)
        let cOffset: UInt32 = 16 * (1 << 24) + 4
        let memberOffsetInSource = UInt32(source.utf16.count - "c: S }\n@group(0) @binding(0) var<uniform> u: U;\n".utf16.count)
        expectError(
            result.failure,
            "offset of struct member U::c must be a multiple of 16 bytes, but its offset is \(cOffset) bytes",
            span(15, 27, memberOffsetInSource, 5)
        )
    }
}
