// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (c) 2022-2026 Apple Inc. All rights reserved.
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

private func expectIs<P: ExpressionPayload>(
    _ shader: borrowing ShaderModule,
    _ type: P.Type,
    _ expression: ExpressionID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = shader.is(type, expression)
    #expect(result, "is<\(type)>", sourceLocation: sourceLocation)
}

private func expectIs<P: StatementPayload>(
    _ shader: borrowing ShaderModule,
    _ type: P.Type,
    _ statement: StatementID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = shader.is(type, statement)
    #expect(result, "is<\(type)>", sourceLocation: sourceLocation)
}

private func expectIs<P: AttributePayload>(
    _ shader: borrowing ShaderModule,
    _ type: P.Type,
    _ attribute: AttributeID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = shader.is(type, attribute)
    #expect(result, "is<\(type)>", sourceLocation: sourceLocation)
}

private func downcast<P: ExpressionPayload>(
    _ shader: borrowing ShaderModule,
    _ type: P.Type,
    _ expression: ExpressionID,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> P {
    let result = shader.dynamicDowncast(type, expression)
    return try #require(result, "downcast<\(type)>", sourceLocation: sourceLocation)
}

private func downcast<P: StatementPayload>(
    _ shader: borrowing ShaderModule,
    _ type: P.Type,
    _ statement: StatementID,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> P {
    let result = shader.dynamicDowncast(type, statement)
    return try #require(result, "downcast<\(type)>", sourceLocation: sourceLocation)
}

private func downcast<P: AttributePayload>(
    _ shader: borrowing ShaderModule,
    _ type: P.Type,
    _ attribute: AttributeID,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> P {
    let result = shader.dynamicDowncast(type, attribute)
    return try #require(result, "downcast<\(type)>", sourceLocation: sourceLocation)
}

private func name(_ shader: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    String(decoding: shader.symbols.text(of: shader.symbol(of: identifier)).codeUnits, as: UTF16.self)
}

private func at<T: ListElement>(
    _ shader: borrowing ShaderModule,
    _ list: ListID<T>,
    _ index: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    try #require(index < shader.count(list), sourceLocation: sourceLocation)
    return shader[list, index]
}

private func asFunction(_ declaration: Declaration) -> FunctionID? {
    guard case .function(let function) = declaration else {
        return nil
    }
    return function
}

private func asVariable(_ declaration: Declaration) -> VariableID? {
    guard case .variable(let variable) = declaration else {
        return nil
    }
    return variable
}

private func asStructure(_ declaration: Declaration) -> StructureID? {
    guard case .structure(let structure) = declaration else {
        return nil
    }
    return structure
}

private func statements(
    _ shader: borrowing ShaderModule,
    _ function: Function,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> ListID<StatementID> {
    try downcast(shader, CompoundStatement.self, function.body, sourceLocation: sourceLocation).statements
}

private func checkBuiltin(
    _ shader: borrowing ShaderModule,
    _ attr: AttributeID,
    _ builtin: Builtin,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectIs(shader, BuiltinAttribute.self, attr, sourceLocation: sourceLocation)
    #expect(shader.dynamicDowncast(BuiltinAttribute.self, attr)?.builtin == builtin, sourceLocation: sourceLocation)
}

private func checkIntLiteral(
    _ shader: borrowing ShaderModule,
    _ node: ExpressionID,
    _ value: Int32,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    expectIs(shader, AbstractIntegerLiteral.self, node, sourceLocation: sourceLocation)
    let intLiteral = try downcast(shader, AbstractIntegerLiteral.self, node, sourceLocation: sourceLocation)
    #expect(intLiteral.value == Int64(value), sourceLocation: sourceLocation)
}

private func checkVecType(
    _ shader: borrowing ShaderModule,
    _ type: ExpressionID,
    _ vecType: String,
    _ paramTypeName: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    expectIs(shader, ElaboratedTypeExpression.self, type, sourceLocation: sourceLocation)
    let parameterizedType = try downcast(shader, ElaboratedTypeExpression.self, type, sourceLocation: sourceLocation)
    #expect(name(shader, parameterizedType.base) == vecType, sourceLocation: sourceLocation)
    #expect(shader.count(parameterizedType.arguments) == 1, sourceLocation: sourceLocation)
    let argument = try at(shader, parameterizedType.arguments, 0, sourceLocation: sourceLocation)
    expectIs(shader, IdentifierExpression.self, argument, sourceLocation: sourceLocation)
    let identifier = try downcast(shader, IdentifierExpression.self, argument, sourceLocation: sourceLocation)
    #expect(name(shader, identifier.identifier) == paramTypeName, sourceLocation: sourceLocation)
}

private func checkVec2F32Type(
    _ shader: borrowing ShaderModule,
    _ type: ExpressionID,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    try checkVecType(shader, type, "vec2", "f32", sourceLocation: sourceLocation)
}

private func checkVec4F32Type(
    _ shader: borrowing ShaderModule,
    _ type: ExpressionID,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    try checkVecType(shader, type, "vec4", "f32", sourceLocation: sourceLocation)
}

/// TestWGSLAPI::parse: `std::expected<ShaderModule, FailedCheck>`; warnings alone are a failure too, as in C++.
private enum ParseResult: ~Copyable {
    case success(ShaderModule)
    case failure(FailedCheck)

    var hasValue: Bool {
        switch self {
        case .success: true
        case .failure: false
        }
    }

    var error: FailedCheck? {
        switch self {
        case .success: nil
        case .failure(let failedCheck): failedCheck
        }
    }
}

private func parse(_ wgsl: String) -> ParseResult {
    var shaderModule = ShaderModule(source: wtfSource(wgsl), configuration: noFeaturesConfiguration)
    if let maybeError = WGSL.parse(&shaderModule) {
        return .failure(maybeError)
    }
    return .success(shaderModule)
}

/// EXPECT_SHADER: the module, or nil once the errors are logged (the C++ macro returns from the test).
private func expectShader(_ shader: consuming ParseResult, sourceLocation: SourceLocation = #_sourceLocation) -> ShaderModule? {
    switch consume shader {
    case .success(let shaderModule):
        return shaderModule
    case .failure(let failedCheck):
        logCompilationError(failedCheck, sourceLocation: sourceLocation)
        return nil
    }
}

private struct StructAttributeTest {
    enum Kind {
        case align
        case size
    }
    let kind: Kind
    let value: UInt32
}

private func extractInteger(_ shader: borrowing ShaderModule, _ expression: ExpressionID) -> UInt32? {
    let kind = shader[expression].kind
    if case .abstractIntegerLiteral(let literal) = kind {
        return UInt32(truncatingIfNeeded: literal.value)
    }
    if case .unsigned32Literal(let literal) = kind {
        return literal.value
    }
    if case .signed32Literal(let literal) = kind {
        return UInt32(bitPattern: literal.value)
    }
    return nil
}

private func testStruct(
    _ program: String,
    _ fieldNames: [String],
    _ typeNames: [String],
    _ attributeTests: [[StructAttributeTest]] = [],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    assert(fieldNames.count == typeNames.count)

    guard let shader = expectShader(parse(program), sourceLocation: sourceLocation) else {
        return
    }
    #expect(shader.count(shader.directives) == 0, sourceLocation: sourceLocation)
    #expect(shader.count(shader.declarations) == 1, sourceLocation: sourceLocation)
    let declaration = try at(shader, shader.declarations, 0, sourceLocation: sourceLocation)
    let str = shader[try #require(asStructure(declaration), sourceLocation: sourceLocation)]
    #expect(name(shader, str.name) == "B", sourceLocation: sourceLocation)

    #expect(shader.count(str.members) == fieldNames.count, sourceLocation: sourceLocation)
    for i in 0..<fieldNames.count {
        let member = shader[try at(shader, str.members, i, sourceLocation: sourceLocation)]
        let attributes = member.attributes
        if attributeTests.isEmpty {
            #expect(shader.count(attributes) == 0, sourceLocation: sourceLocation)
        } else {
            let tests = attributeTests[i]
            #expect(tests.count == shader.count(attributes), sourceLocation: sourceLocation)
            for j in 0..<tests.count {
                let test = tests[j]
                let attribute = try at(shader, attributes, j, sourceLocation: sourceLocation)
                switch test.kind {
                case .align:
                    expectIs(shader, AlignAttribute.self, attribute, sourceLocation: sourceLocation)
                    let alignAttribute = try downcast(shader, AlignAttribute.self, attribute, sourceLocation: sourceLocation)
                    let alignment = extractInteger(shader, alignAttribute.alignment)
                    #expect(alignment != nil, sourceLocation: sourceLocation)
                    #expect(alignment == test.value, sourceLocation: sourceLocation)
                case .size:
                    expectIs(shader, SizeAttribute.self, attribute, sourceLocation: sourceLocation)
                    let sizeAttribute = try downcast(shader, SizeAttribute.self, attribute, sourceLocation: sourceLocation)
                    let size = extractInteger(shader, sizeAttribute.size)
                    #expect(size != nil, sourceLocation: sourceLocation)
                    #expect(size == test.value, sourceLocation: sourceLocation)
                }
            }
        }
        #expect(name(shader, member.name) == fieldNames[i], sourceLocation: sourceLocation)
        expectIs(shader, IdentifierExpression.self, member.type, sourceLocation: sourceLocation)
        let memberType = try downcast(shader, IdentifierExpression.self, member.type, sourceLocation: sourceLocation)
        #expect(name(shader, memberType.identifier) == typeNames[i], sourceLocation: sourceLocation)
    }
}

private func testUnaryExpressionX(_ program: String, _ op: UnaryOperation, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let source = "fn f() {\n" + "_ = " + program + ";" + "}\n"
    guard let shader = expectShader(parse(source), sourceLocation: sourceLocation) else {
        return
    }
    #expect(shader.count(shader.directives) == 0, sourceLocation: sourceLocation)
    #expect(shader.count(shader.declarations) == 1, sourceLocation: sourceLocation)
    let declaration = try at(shader, shader.declarations, 0, sourceLocation: sourceLocation)
    let function = shader[try #require(asFunction(declaration), sourceLocation: sourceLocation)]

    let body = try statements(shader, function, sourceLocation: sourceLocation)
    #expect(shader.count(body) == 1, sourceLocation: sourceLocation)
    let first = try at(shader, body, 0, sourceLocation: sourceLocation)
    expectIs(shader, PhonyAssignmentStatement.self, first, sourceLocation: sourceLocation)
    let statement = try downcast(shader, PhonyAssignmentStatement.self, first, sourceLocation: sourceLocation)

    expectIs(shader, UnaryExpression.self, statement.rhs, sourceLocation: sourceLocation)
    let unaryExpression = try downcast(shader, UnaryExpression.self, statement.rhs, sourceLocation: sourceLocation)

    #expect(unaryExpression.operation == op, sourceLocation: sourceLocation)
    expectIs(shader, IdentifierExpression.self, unaryExpression.expression, sourceLocation: sourceLocation)
    let expr = try downcast(shader, IdentifierExpression.self, unaryExpression.expression, sourceLocation: sourceLocation)
    #expect(name(shader, expr.identifier) == "x", sourceLocation: sourceLocation)
}

private func testBinaryExpressionXY(
    _ program: String,
    _ op: BinaryOperation,
    _ ids: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(ids.count == 2, sourceLocation: sourceLocation)

    let source = "fn f() {\n" + "_ = " + program + ";" + "}\n"
    guard let shader = expectShader(parse(source), sourceLocation: sourceLocation) else {
        return
    }
    #expect(shader.count(shader.directives) == 0, sourceLocation: sourceLocation)
    #expect(shader.count(shader.declarations) == 1, sourceLocation: sourceLocation)
    let declaration = try at(shader, shader.declarations, 0, sourceLocation: sourceLocation)
    let function = shader[try #require(asFunction(declaration), sourceLocation: sourceLocation)]

    let body = try statements(shader, function, sourceLocation: sourceLocation)
    #expect(shader.count(body) == 1, sourceLocation: sourceLocation)
    let first = try at(shader, body, 0, sourceLocation: sourceLocation)
    expectIs(shader, PhonyAssignmentStatement.self, first, sourceLocation: sourceLocation)
    let statement = try downcast(shader, PhonyAssignmentStatement.self, first, sourceLocation: sourceLocation)
    expectIs(shader, BinaryExpression.self, statement.rhs, sourceLocation: sourceLocation)
    let binaryExpression = try downcast(shader, BinaryExpression.self, statement.rhs, sourceLocation: sourceLocation)

    #expect(binaryExpression.operation == op, sourceLocation: sourceLocation)
    expectIs(shader, IdentifierExpression.self, binaryExpression.leftExpression, sourceLocation: sourceLocation)
    let lhs = try downcast(shader, IdentifierExpression.self, binaryExpression.leftExpression, sourceLocation: sourceLocation)
    #expect(name(shader, lhs.identifier) == ids[0], sourceLocation: sourceLocation)
    expectIs(shader, IdentifierExpression.self, binaryExpression.rightExpression, sourceLocation: sourceLocation)
    let rhs = try downcast(shader, IdentifierExpression.self, binaryExpression.rightExpression, sourceLocation: sourceLocation)
    #expect(name(shader, rhs.identifier) == ids[1], sourceLocation: sourceLocation)
}

private func testBinaryExpressionXYZ(
    _ program: String,
    _ ops: [BinaryOperation],
    _ ids: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(ops.count == 2, sourceLocation: sourceLocation)
    #expect(ids.count == 3, sourceLocation: sourceLocation)

    let source = "fn f() {\n" + "_ = " + program + ";" + "}\n"
    guard let shader = expectShader(parse(source), sourceLocation: sourceLocation) else {
        return
    }
    #expect(shader.count(shader.directives) == 0, sourceLocation: sourceLocation)
    #expect(shader.count(shader.declarations) == 1, sourceLocation: sourceLocation)
    let declaration = try at(shader, shader.declarations, 0, sourceLocation: sourceLocation)
    let function = shader[try #require(asFunction(declaration), sourceLocation: sourceLocation)]

    let body = try statements(shader, function, sourceLocation: sourceLocation)
    #expect(shader.count(body) == 1, sourceLocation: sourceLocation)
    let first = try at(shader, body, 0, sourceLocation: sourceLocation)
    expectIs(shader, PhonyAssignmentStatement.self, first, sourceLocation: sourceLocation)
    let statement = try downcast(shader, PhonyAssignmentStatement.self, first, sourceLocation: sourceLocation)

    expectIs(shader, BinaryExpression.self, statement.rhs, sourceLocation: sourceLocation)
    let binaryExpression = try downcast(shader, BinaryExpression.self, statement.rhs, sourceLocation: sourceLocation)

    let leftIsBinary = shader.is(BinaryExpression.self, binaryExpression.leftExpression)
    let complex = leftIsBinary ? binaryExpression.leftExpression : binaryExpression.rightExpression
    let simple = leftIsBinary ? binaryExpression.rightExpression : binaryExpression.leftExpression
    expectIs(shader, IdentifierExpression.self, simple, sourceLocation: sourceLocation)

    do {
        let binaryExpression2 = try downcast(shader, BinaryExpression.self, complex, sourceLocation: sourceLocation)

        #expect(binaryExpression2.operation == ops[0], sourceLocation: sourceLocation)
        expectIs(shader, IdentifierExpression.self, binaryExpression2.leftExpression, sourceLocation: sourceLocation)
        let lhs = try downcast(shader, IdentifierExpression.self, binaryExpression2.leftExpression, sourceLocation: sourceLocation)
        #expect(name(shader, lhs.identifier) == ids[0], sourceLocation: sourceLocation)
        expectIs(shader, IdentifierExpression.self, binaryExpression2.rightExpression, sourceLocation: sourceLocation)
        let rhs = try downcast(shader, IdentifierExpression.self, binaryExpression2.rightExpression, sourceLocation: sourceLocation)
        #expect(name(shader, rhs.identifier) == ids[1], sourceLocation: sourceLocation)
    }

    do {
        #expect(binaryExpression.operation == ops[1], sourceLocation: sourceLocation)
        let rhs = try downcast(shader, IdentifierExpression.self, simple, sourceLocation: sourceLocation)
        #expect(name(shader, rhs.identifier) == ids[2], sourceLocation: sourceLocation)
    }
}

@Suite
struct WGSLParserTests {
    @Test
    func SourceLifecycle() throws {
        let parsed = {
            let source = "@group(0)" + " " + "@binding(0)" + "var<storage, read_write>" + " " + "x: B;"
            return parse(source)
        }()

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let variable = shader[try #require(asVariable(try at(shader, shader.declarations, 0)))]
        #expect(shader.count(variable.attributes) == 2)
        let attribute0 = try at(shader, variable.attributes, 0)
        expectIs(shader, GroupAttribute.self, attribute0)
        let group = extractInteger(shader, try downcast(shader, GroupAttribute.self, attribute0).group)
        #expect(group != nil)
        #expect(group == 0)
        let attribute1 = try at(shader, variable.attributes, 1)
        expectIs(shader, BindingAttribute.self, attribute1)
        let binding = extractInteger(shader, try downcast(shader, BindingAttribute.self, attribute1).binding)
        #expect(binding != nil)
        #expect(binding == 0)
        #expect(name(shader, variable.name) == "x")
        #expect(variable.maybeQualifier != nil)
        #expect(variable.maybeQualifier?.addressSpace == .storage)
        #expect(variable.maybeQualifier?.accessMode == .readWrite)
        let typeName = try #require(variable.maybeTypeName)
        expectIs(shader, IdentifierExpression.self, typeName)
        let namedType = try downcast(shader, IdentifierExpression.self, typeName)
        #expect(name(shader, namedType.identifier) == "B")
        #expect(variable.maybeInitializer == nil)
    }

    @Test
    func Struct() throws {
        // 1 field, without trailing comma
        try testStruct(
            "struct B {\n"
                + "    a: i32\n"
                + "}",
            ["a"],
            ["i32"]
        )

        // 1 field, with trailing comma
        try testStruct(
            "struct B {\n"
                + "    a: i32,\n"
                + "}",
            ["a"],
            ["i32"]
        )

        // 2 fields, without trailing comma
        try testStruct(
            "struct B {\n"
                + "    a: i32,\n"
                + "    b: f32\n"
                + "}",
            ["a", "b"],
            ["i32", "f32"]
        )

        // 2 fields, with trailing comma
        try testStruct(
            "struct B {\n"
                + "    @size(8) a: i32,\n"
                + "    @align(8) b: f32,\n"
                + "}",
            ["a", "b"],
            ["i32", "f32"],
            [[StructAttributeTest(kind: .size, value: 8)], [StructAttributeTest(kind: .align, value: 8)]]
        )
    }

    @Test
    func GlobalVariable() throws {
        let parsed = parse(
            "@group(0) @binding(0)\n"
                + "var<storage, read_write> x: B;\n"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let variable = shader[try #require(asVariable(try at(shader, shader.declarations, 0)))]
        #expect(shader.count(variable.attributes) == 2)
        let attribute0 = try at(shader, variable.attributes, 0)
        expectIs(shader, GroupAttribute.self, attribute0)
        let groupAttribute = try downcast(shader, GroupAttribute.self, attribute0)
        let group = extractInteger(shader, groupAttribute.group)
        #expect(group != nil)
        #expect(group == 0)
        let attribute1 = try at(shader, variable.attributes, 1)
        expectIs(shader, BindingAttribute.self, attribute1)
        let bindingAttribute = try downcast(shader, BindingAttribute.self, attribute1)
        let binding = extractInteger(shader, bindingAttribute.binding)
        #expect(binding != nil)
        #expect(binding == 0)
        #expect(name(shader, variable.name) == "x")
        #expect(variable.maybeQualifier != nil)
        #expect(variable.maybeQualifier?.addressSpace == .storage)
        #expect(variable.maybeQualifier?.accessMode == .readWrite)
        let typeName = try #require(variable.maybeTypeName)
        expectIs(shader, IdentifierExpression.self, typeName)
        let namedType = try downcast(shader, IdentifierExpression.self, typeName)
        #expect(name(shader, namedType.identifier) == "B")
        #expect(variable.maybeInitializer == nil)
    }

    @Test
    func FunctionDecl() throws {
        let parsed = parse(
            "@compute\n"
                + "fn main() {\n"
                + "    x.a = 42i;\n"
                + "}"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
        #expect(shader.count(function.attributes) == 1)
        let attribute = try at(shader, function.attributes, 0)
        expectIs(shader, StageAttribute.self, attribute)
        #expect(shader.dynamicDowncast(StageAttribute.self, attribute)?.stage == .compute)
        #expect(name(shader, function.name) == "main")
        #expect(shader.count(function.parameters) == 0)
        #expect(shader.count(function.returnAttributes) == 0)
        #expect(function.maybeReturnType == nil)
        let body = try statements(shader, function)
        #expect(shader.count(body) == 1)
        let first = try at(shader, body, 0)
        expectIs(shader, AssignmentStatement.self, first)
        let stmt = try downcast(shader, AssignmentStatement.self, first)
        expectIs(shader, FieldAccessExpression.self, stmt.lhs)
        let structAccess = try downcast(shader, FieldAccessExpression.self, stmt.lhs)
        expectIs(shader, IdentifierExpression.self, structAccess.base)
        let base = try downcast(shader, IdentifierExpression.self, structAccess.base)
        #expect(name(shader, base.identifier) == "x")
        #expect(name(shader, structAccess.fieldName) == "a")
        expectIs(shader, Signed32Literal.self, stmt.rhs)
        let rhs = try downcast(shader, Signed32Literal.self, stmt.rhs)
        #expect(rhs.value == 42)
    }

    @Test
    func TrivialGraphicsShader() throws {
        let parsed = parse(
            "@vertex\n"
                + "fn vertexShader(@location(0) x: vec4<f32>) -> @builtin(position) vec4<f32> {\n"
                + "    return x;\n"
                + "}\n\n"
                + "@fragment\n"
                + "fn fragmentShader() -> @location(0) vec4<f32> {\n"
                + "    return vec4<f32>(0.4, 0.4, 0.8, 1.0);\n"
                + "}"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 2)

        do {
            let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
            #expect(shader.count(function.attributes) == 1)
            let attribute = try at(shader, function.attributes, 0)
            expectIs(shader, StageAttribute.self, attribute)
            #expect(shader.dynamicDowncast(StageAttribute.self, attribute)?.stage == .vertex)
            #expect(name(shader, function.name) == "vertexShader")
            #expect(shader.count(function.parameters) == 1)
            let parameter = shader[try at(shader, function.parameters, 0)]
            #expect(name(shader, parameter.name) == "x")
            #expect(shader.count(parameter.attributes) == 1)
            let parameterAttribute = try at(shader, parameter.attributes, 0)
            expectIs(shader, LocationAttribute.self, parameterAttribute)
            let locationAttribute = try downcast(shader, LocationAttribute.self, parameterAttribute)
            let location = extractInteger(shader, locationAttribute.location)
            #expect(location != nil)
            #expect(location == 0)
            expectIs(shader, ElaboratedTypeExpression.self, parameter.typeName)
            let paramType = try downcast(shader, ElaboratedTypeExpression.self, parameter.typeName)
            #expect(name(shader, paramType.base) == "vec4")
            #expect(shader.count(paramType.arguments) == 1)
            let argument = try at(shader, paramType.arguments, 0)
            expectIs(shader, IdentifierExpression.self, argument)
            let argumentIdentifier = try downcast(shader, IdentifierExpression.self, argument)
            #expect(name(shader, argumentIdentifier.identifier) == "f32")
            #expect(shader.count(function.returnAttributes) == 1)
            checkBuiltin(shader, try at(shader, function.returnAttributes, 0), .position)
            let returnType = try #require(function.maybeReturnType)
            expectIs(shader, ElaboratedTypeExpression.self, returnType)
            let body = try statements(shader, function)
            #expect(shader.count(body) == 1)
            let first = try at(shader, body, 0)
            expectIs(shader, ReturnStatement.self, first)
            let stmt = try downcast(shader, ReturnStatement.self, first)
            let expression = try #require(stmt.maybeExpression)
            expectIs(shader, IdentifierExpression.self, expression)
        }

        do {
            let function = shader[try #require(asFunction(try at(shader, shader.declarations, 1)))]
            #expect(shader.count(function.attributes) == 1)
            let attribute = try at(shader, function.attributes, 0)
            expectIs(shader, StageAttribute.self, attribute)
            #expect(shader.dynamicDowncast(StageAttribute.self, attribute)?.stage == .fragment)
            #expect(name(shader, function.name) == "fragmentShader")
            #expect(shader.count(function.parameters) == 0)
            #expect(shader.count(function.returnAttributes) == 1)
            let returnAttribute = try at(shader, function.returnAttributes, 0)
            expectIs(shader, LocationAttribute.self, returnAttribute)
            let locationAttribute = try downcast(shader, LocationAttribute.self, returnAttribute)
            let location = extractInteger(shader, locationAttribute.location)
            #expect(location != nil)
            #expect(location == 0)
            let returnType = try #require(function.maybeReturnType)
            expectIs(shader, ElaboratedTypeExpression.self, returnType)
            let body = try statements(shader, function)
            #expect(shader.count(body) == 1)
            let first = try at(shader, body, 0)
            expectIs(shader, ReturnStatement.self, first)
            let stmt = try downcast(shader, ReturnStatement.self, first)
            let expression = try #require(stmt.maybeExpression)
            expectIs(shader, CallExpression.self, expression)
            let expr = try downcast(shader, CallExpression.self, expression)
            expectIs(shader, ElaboratedTypeExpression.self, expr.target)
            #expect(shader.count(expr.arguments) == 4)
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, expr.arguments, 0))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, expr.arguments, 1))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, expr.arguments, 2))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, expr.arguments, 3))
        }
    }

    // MARK: - Declarations

    @Test
    func GlobalConstant() throws {
        guard let shader = expectShader(parse("const x: i32 = 1;\n")) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)

        do {
            // const x: i32 = 1
            let constant = shader[try #require(asVariable(try at(shader, shader.declarations, 0)))]
            #expect(constant.flavor == .const)
            #expect(name(shader, constant.name) == "x")
            let maybeTypeName = try #require(constant.maybeTypeName)
            expectIs(shader, IdentifierExpression.self, maybeTypeName)
            let typeName = try downcast(shader, IdentifierExpression.self, maybeTypeName)
            #expect(name(shader, typeName.identifier) == "i32")
            let maybeInitializer = try #require(constant.maybeInitializer)
            expectIs(shader, AbstractIntegerLiteral.self, maybeInitializer)
        }
    }

    @Test
    func LocalConstant() throws {
        let parsed = parse(
            "@vertex\n"
                + "fn main() -> vec4<f32> {\n"
                + "    const x = vec4<f32>(0.4, 0.4, 0.8, 1.0);\n"
                + "    return x;\n"
                + "}"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)

        do {
            let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
            // @vertex
            #expect(shader.count(function.attributes) == 1)
            let attribute = try at(shader, function.attributes, 0)
            expectIs(shader, StageAttribute.self, attribute)
            #expect(shader.dynamicDowncast(StageAttribute.self, attribute)?.stage == .vertex)

            // fn main() -> vec4<f32> {
            #expect(name(shader, function.name) == "main")
            #expect(shader.count(function.parameters) == 0)
            #expect(shader.count(function.returnAttributes) == 0)
            let returnType = try #require(function.maybeReturnType)
            expectIs(shader, ElaboratedTypeExpression.self, returnType)
            let body = try statements(shader, function)
            #expect(shader.count(body) == 2)

            // const x = vec4<f32>(0.4, 0.4, 0.8, 1.0);
            let first = try at(shader, body, 0)
            expectIs(shader, VariableStatement.self, first)
            let varStmt = try downcast(shader, VariableStatement.self, first)
            let constant = shader[varStmt.variable]
            #expect(constant.flavor == .const)
            #expect(name(shader, constant.name) == "x")
            #expect(constant.maybeTypeName == nil)
            let initializer = try #require(constant.maybeInitializer)
            expectIs(shader, CallExpression.self, initializer)
            let constantInitExpr = try downcast(shader, CallExpression.self, initializer)
            expectIs(shader, ElaboratedTypeExpression.self, constantInitExpr.target)
            #expect(shader.count(constantInitExpr.arguments) == 4)
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, constantInitExpr.arguments, 0))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, constantInitExpr.arguments, 1))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, constantInitExpr.arguments, 2))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, constantInitExpr.arguments, 3))

            // return x;
            let second = try at(shader, body, 1)
            expectIs(shader, ReturnStatement.self, second)
            let retStmt = try downcast(shader, ReturnStatement.self, second)
            let returned = try #require(retStmt.maybeExpression)
            expectIs(shader, IdentifierExpression.self, returned)
            let retExpr = try downcast(shader, IdentifierExpression.self, returned)
            #expect(name(shader, retExpr.identifier) == "x")
        }
    }

    @Test
    func LocalLet() throws {
        let parsed = parse(
            "@vertex\n"
                + "fn main() -> vec4<f32> {\n"
                + "    let x = vec4<f32>(0.4, 0.4, 0.8, 1.0);\n"
                + "    return x;\n"
                + "}"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)

        do {
            let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
            // @vertex
            #expect(shader.count(function.attributes) == 1)
            let attribute = try at(shader, function.attributes, 0)
            expectIs(shader, StageAttribute.self, attribute)
            #expect(shader.dynamicDowncast(StageAttribute.self, attribute)?.stage == .vertex)

            // fn main() -> vec4<f32> {
            #expect(name(shader, function.name) == "main")
            #expect(shader.count(function.parameters) == 0)
            #expect(shader.count(function.returnAttributes) == 0)
            let returnType = try #require(function.maybeReturnType)
            expectIs(shader, ElaboratedTypeExpression.self, returnType)
            let body = try statements(shader, function)
            #expect(shader.count(body) == 2)

            // lex x = vec4<f32>(0.4, 0.4, 0.8, 1.0);
            let first = try at(shader, body, 0)
            expectIs(shader, VariableStatement.self, first)
            let varStmt = try downcast(shader, VariableStatement.self, first)
            let variable = shader[varStmt.variable]
            #expect(variable.flavor == .let)
            #expect(name(shader, variable.name) == "x")
            #expect(variable.maybeTypeName == nil)
            let initializer = try #require(variable.maybeInitializer)
            expectIs(shader, CallExpression.self, initializer)
            let letInitExpr = try downcast(shader, CallExpression.self, initializer)
            expectIs(shader, ElaboratedTypeExpression.self, letInitExpr.target)
            #expect(shader.count(letInitExpr.arguments) == 4)
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, letInitExpr.arguments, 0))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, letInitExpr.arguments, 1))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, letInitExpr.arguments, 2))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, letInitExpr.arguments, 3))

            // return x;
            let second = try at(shader, body, 1)
            expectIs(shader, ReturnStatement.self, second)
            let retStmt = try downcast(shader, ReturnStatement.self, second)
            let returned = try #require(retStmt.maybeExpression)
            expectIs(shader, IdentifierExpression.self, returned)
            let retExpr = try downcast(shader, IdentifierExpression.self, returned)
            #expect(name(shader, retExpr.identifier) == "x")
        }
    }

    @Test
    func GlobalOverride() throws {
        guard let shader = expectShader(parse("override x: i32;\n")) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)

        do {
            // override x: i32
            let override = shader[try #require(asVariable(try at(shader, shader.declarations, 0)))]
            #expect(shader.count(override.attributes) == 0)
            #expect(override.flavor == .override)
            #expect(name(shader, override.name) == "x")
            let maybeTypeName = try #require(override.maybeTypeName)
            expectIs(shader, IdentifierExpression.self, maybeTypeName)
            let typeName = try downcast(shader, IdentifierExpression.self, maybeTypeName)
            #expect(name(shader, typeName.identifier) == "i32")
            #expect(override.maybeInitializer == nil)
        }
    }

    @Test
    func LocalVariable() throws {
        let parsed = parse(
            "@vertex\n"
                + "fn main() -> vec4<f32> {\n"
                + "    var x = vec4<f32>(0.4, 0.4, 0.8, 1.0);\n"
                + "    return x;\n"
                + "}"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]

        do {
            // @vertex
            #expect(shader.count(function.attributes) == 1)
            let attribute = try at(shader, function.attributes, 0)
            expectIs(shader, StageAttribute.self, attribute)
            #expect(shader.dynamicDowncast(StageAttribute.self, attribute)?.stage == .vertex)

            // fn main() -> vec4<f32> {
            #expect(name(shader, function.name) == "main")
            #expect(shader.count(function.parameters) == 0)
            #expect(shader.count(function.returnAttributes) == 0)
            let returnType = try #require(function.maybeReturnType)
            expectIs(shader, ElaboratedTypeExpression.self, returnType)
            let body = try statements(shader, function)
            #expect(shader.count(body) == 2)

            // var x = vec4<f32>(0.4, 0.4, 0.8, 1.0);
            let first = try at(shader, body, 0)
            expectIs(shader, VariableStatement.self, first)
            let varStmt = try downcast(shader, VariableStatement.self, first)
            let variable = shader[varStmt.variable]
            #expect(variable.flavor == .var)
            #expect(name(shader, variable.name) == "x")
            #expect(shader.count(variable.attributes) == 0)
            #expect(variable.maybeQualifier == nil)
            #expect(variable.maybeTypeName == nil)
            let initializer = try #require(variable.maybeInitializer)
            let varInitExpr = try downcast(shader, CallExpression.self, initializer)
            expectIs(shader, ElaboratedTypeExpression.self, varInitExpr.target)
            #expect(shader.count(varInitExpr.arguments) == 4)
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, varInitExpr.arguments, 0))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, varInitExpr.arguments, 1))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, varInitExpr.arguments, 2))
            expectIs(shader, AbstractFloatLiteral.self, try at(shader, varInitExpr.arguments, 3))

            // return x;
            let second = try at(shader, body, 1)
            expectIs(shader, ReturnStatement.self, second)
            let retStmt = try downcast(shader, ReturnStatement.self, second)
            let returned = try #require(retStmt.maybeExpression)
            expectIs(shader, IdentifierExpression.self, returned)
            let retExpr = try downcast(shader, IdentifierExpression.self, returned)
            #expect(name(shader, retExpr.identifier) == "x")
        }
    }

    // MARK: - Expressions

    @Test
    func ArrayAccess() throws {
        guard let shader = expectShader(parse("fn test() { return x[42i]; }")) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)

        do {
            let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
            // fn test() { ... }
            #expect(name(shader, function.name) == "test")
            #expect(shader.count(function.parameters) == 0)
            #expect(shader.count(function.returnAttributes) == 0)
            #expect(function.maybeReturnType == nil)

            let body = try statements(shader, function)
            #expect(shader.count(body) == 1)
            // return x[42];
            let first = try at(shader, body, 0)
            expectIs(shader, ReturnStatement.self, first)
            let retStmt = try downcast(shader, ReturnStatement.self, first)
            let returned = try #require(retStmt.maybeExpression)
            expectIs(shader, IndexAccessExpression.self, returned)
            let arrayAccess = try downcast(shader, IndexAccessExpression.self, returned)
            expectIs(shader, IdentifierExpression.self, arrayAccess.base)
            let base = try downcast(shader, IdentifierExpression.self, arrayAccess.base)
            #expect(name(shader, base.identifier) == "x")
            expectIs(shader, Signed32Literal.self, arrayAccess.index)
            let index = try downcast(shader, Signed32Literal.self, arrayAccess.index)
            #expect(index.value == 42)
        }
    }

    @Test
    func UnaryExpression() throws {
        let parsed = parse(
            "fn negate(x: f32) -> f32 {\n"
                + "    return -x;\n"
                + "}"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)

        do {
            let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
            // @vertex
            #expect(shader.count(function.attributes) == 0)

            // fn negate(x: f32) -> f32 {
            #expect(name(shader, function.name) == "negate")
            #expect(shader.count(function.parameters) == 1)
            #expect(shader.count(function.returnAttributes) == 0)
            let returnType = try #require(function.maybeReturnType)
            expectIs(shader, IdentifierExpression.self, returnType)

            let body = try statements(shader, function)
            #expect(shader.count(body) == 1)
            // return x;
            let first = try at(shader, body, 0)
            expectIs(shader, ReturnStatement.self, first)
            let retStmt = try downcast(shader, ReturnStatement.self, first)
            let returned = try #require(retStmt.maybeExpression)
            expectIs(shader, WGSL.UnaryExpression.self, returned)
            let retExpr = try downcast(shader, WGSL.UnaryExpression.self, returned)
            #expect(retExpr.operation == .negate)
            expectIs(shader, IdentifierExpression.self, retExpr.expression)
            let negateExpr = try downcast(shader, IdentifierExpression.self, retExpr.expression)
            #expect(name(shader, negateExpr.identifier) == "x")
        }
    }

    @Test
    func UnaryExpression2() throws {
        try testUnaryExpressionX("&x", .addressOf)
        try testUnaryExpressionX("~x", .complement)
        try testUnaryExpressionX("*x", .dereference)
        try testUnaryExpressionX("-x", .negate)
        try testUnaryExpressionX("!x", .not)
    }

    @Test
    func BinaryExpression() throws {
        let parsed = parse(
            "fn add(x: f32, y: f32) -> f32 {\n"
                + "    return x + y;\n"
                + "}"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)

        do {
            let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
            #expect(shader.count(function.attributes) == 0)

            // fn add(x: f32, y: f32) -> f32 {
            #expect(name(shader, function.name) == "add")
            #expect(shader.count(function.parameters) == 2)
            #expect(shader.count(function.returnAttributes) == 0)
            let returnType = try #require(function.maybeReturnType)
            expectIs(shader, IdentifierExpression.self, returnType)

            let body = try statements(shader, function)
            #expect(shader.count(body) == 1)

            // return x + y;
            let first = try at(shader, body, 0)
            expectIs(shader, ReturnStatement.self, first)
            let retStmt = try downcast(shader, ReturnStatement.self, first)
            let returned = try #require(retStmt.maybeExpression)
            expectIs(shader, WGSL.BinaryExpression.self, returned)
            let binaryExpression = try downcast(shader, WGSL.BinaryExpression.self, returned)
            #expect(binaryExpression.operation == .add)

            expectIs(shader, IdentifierExpression.self, binaryExpression.leftExpression)
            let lhs = try downcast(shader, IdentifierExpression.self, binaryExpression.leftExpression)
            #expect(name(shader, lhs.identifier) == "x")

            expectIs(shader, IdentifierExpression.self, binaryExpression.rightExpression)
            let rhs = try downcast(shader, IdentifierExpression.self, binaryExpression.rightExpression)
            #expect(name(shader, rhs.identifier) == "y")
        }
    }

    @Test
    func BinaryExpression2() throws {
        try testBinaryExpressionXYZ("x - y + z", [.subtract, .add], ["x", "y", "z"])

        try testBinaryExpressionXYZ("x + y * z", [.multiply, .add], ["y", "z", "x"])

        try testBinaryExpressionXYZ("x / y + z", [.divide, .add], ["x", "y", "z"])
    }

    @Test
    func BinaryLeftShiftExpression() throws {
        try testBinaryExpressionXY("x << y", .leftShift, ["x", "y"])
    }

    @Test
    func BinaryRightShiftExpression() throws {
        try testBinaryExpressionXY("x >> y", .rightShift, ["x", "y"])
    }

    @Test
    func BinaryBitwiseExpression() throws {
        try testBinaryExpressionXYZ("x & y & z", [.and, .and], ["x", "y", "z"])

        try testBinaryExpressionXYZ("x | y | z", [.or, .or], ["x", "y", "z"])

        try testBinaryExpressionXYZ("x ^ y ^ z", [.xor, .xor], ["x", "y", "z"])
    }

    @Test
    func RelationalExpression() throws {
        try testBinaryExpressionXY("x == y", .equal, ["x", "y"])
        try testBinaryExpressionXY("x != y", .notEqual, ["x", "y"])
        try testBinaryExpressionXY("x > y", .greaterThan, ["x", "y"])
        try testBinaryExpressionXY("x >= y", .greaterEqual, ["x", "y"])
        try testBinaryExpressionXY("x < y", .lessThan, ["x", "y"])
        try testBinaryExpressionXY("x <= y", .lessEqual, ["x", "y"])
    }

    // MARK: - WebGPU Example Shaders

    @Test
    func TriangleVert() throws {
        let parsed = parse(
            "@vertex\n"
                + "fn main(\n"
                + "    @builtin(vertex_index) VertexIndex : u32\n"
                + ") -> @builtin(position) vec4<f32> {\n"
                + "    var pos = array<vec2<f32>, 3>(\n"
                + "        vec2<f32>(0.0, 0.5),\n"
                + "        vec2<f32>(-0.5, -0.5),\n"
                + "        vec2<f32>(0.5, -0.5)\n"
                + "    );\n\n"
                + "    return vec4<f32>(pos[VertexIndex], 0.0, 1.0);\n"
                + "}\n"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]

        // fn main(...)
        do {
            // @vertex
            #expect(shader.count(function.attributes) == 1)

            // fn main(@builtin(vertex_index) VertexIndex : u32) -> @builtin(position) vec4<f32> {
            #expect(name(shader, function.name) == "main")
            #expect(shader.count(function.parameters) == 1)
            #expect(shader.count(function.returnAttributes) == 1)
            let returnType = try #require(function.maybeReturnType)
            try checkVec4F32Type(shader, returnType)
            #expect(shader.count(function.returnAttributes) == 1)
            checkBuiltin(shader, try at(shader, function.returnAttributes, 0), .position)
        }

        let body = try statements(shader, function)

        // var pos = array<vec2<f32>, 3>(...);
        do {
            #expect(shader.count(body) >= 1)
            let stmt = try at(shader, body, 0)
            expectIs(shader, VariableStatement.self, stmt)
            let varStmt = try downcast(shader, VariableStatement.self, stmt)
            let variable = shader[varStmt.variable]
            #expect(name(shader, variable.name) == "pos")
            #expect(shader.count(variable.attributes) == 0)
            #expect(variable.maybeQualifier == nil)
            #expect(variable.maybeTypeName == nil)
            let initializer = try #require(variable.maybeInitializer)
            expectIs(shader, CallExpression.self, initializer)
            let varInitExpr = try downcast(shader, CallExpression.self, initializer)
            expectIs(shader, ArrayTypeExpression.self, varInitExpr.target)
            let varInitArrayType = try downcast(shader, ArrayTypeExpression.self, varInitExpr.target)
            let elementType = try #require(varInitArrayType.maybeElementType)
            try checkVec2F32Type(shader, elementType)
            let elementCount = try #require(varInitArrayType.maybeElementCount)
            expectIs(shader, AbstractIntegerLiteral.self, elementCount)
            try checkIntLiteral(shader, elementCount, 3)
        }

        // return vec4<f32>(..);
        do {
            #expect(shader.count(body) >= 1)
            let stmt = try at(shader, body, 1)
            expectIs(shader, ReturnStatement.self, stmt)
            let retStmt = try downcast(shader, ReturnStatement.self, stmt)
            let returned = try #require(retStmt.maybeExpression)
            expectIs(shader, CallExpression.self, returned)
            let expr = try downcast(shader, CallExpression.self, returned)
            expectIs(shader, ElaboratedTypeExpression.self, expr.target)
        }
    }

    @Test
    func VectorWithOutComponentType() throws {
        let parsed = parse(
            "@vertex\n"
                + "fn main() {\n"
                + "    x = vec4(1.0);\n"
                + "}\n"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
        let body = try statements(shader, function)
        #expect(shader.count(body) == 1)

        // x = vec4(1.0);
        let first = try at(shader, body, 0)
        expectIs(shader, AssignmentStatement.self, first)
        let stmt = try downcast(shader, AssignmentStatement.self, first)
        expectIs(shader, IdentifierExpression.self, stmt.lhs)
        let id = try downcast(shader, IdentifierExpression.self, stmt.lhs)
        #expect(name(shader, id.identifier) == "x")

        expectIs(shader, CallExpression.self, stmt.rhs)
        let constructor = try downcast(shader, CallExpression.self, stmt.rhs)
        expectIs(shader, IdentifierExpression.self, constructor.target)
        let vec4 = try downcast(shader, IdentifierExpression.self, constructor.target)
        #expect(name(shader, vec4.identifier) == "vec4")
    }

    @Test
    func VectorWithComponentType() throws {
        let parsed = parse(
            "@vertex\n"
                + "fn main() {\n"
                + "    x = vec4<f32>(1.0);\n"
                + "}\n"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let function = shader[try #require(asFunction(try at(shader, shader.declarations, 0)))]
        let body = try statements(shader, function)
        #expect(shader.count(body) == 1)

        // x = vec4<f32>(1.0);
        let first = try at(shader, body, 0)
        expectIs(shader, AssignmentStatement.self, first)
        let stmt = try downcast(shader, AssignmentStatement.self, first)
        expectIs(shader, IdentifierExpression.self, stmt.lhs)
        let id = try downcast(shader, IdentifierExpression.self, stmt.lhs)
        #expect(name(shader, id.identifier) == "x")

        expectIs(shader, CallExpression.self, stmt.rhs)
        let constructor = try downcast(shader, CallExpression.self, stmt.rhs)
        expectIs(shader, ElaboratedTypeExpression.self, constructor.target)
        try checkVec4F32Type(shader, constructor.target)
    }

    @Test
    func RedFrag() throws {
        let parsed = parse(
            "@fragment\n"
                + "fn main() -> @location(0) vec4<f32> {\n"
                + "    return vec4<f32>(1.0, 0.0, 0.0, 1.0);\n"
                + "}\n"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        #expect(asFunction(try at(shader, shader.declarations, 0)) != nil)
    }

    @Test
    func TrailingSemicolon() throws {
        let parsed = parse(
            "fn f(){\n"
                + "  ;;;\n"
                + "}\n"
                + ";;;\n"
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.declarations) == 1)
        #expect(asFunction(try at(shader, shader.declarations, 0)) != nil)
    }

    @Test
    func GlobalVarWithoutTypeOrInitializer() {
        let shader = parse("var x;")
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "var declaration requires a type or initializer")
    }

    @Test
    func GlobalConstWithoutTypeOrInitializer() {
        let shader = parse("const x;")
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "Expected a =, but got a ;")
    }

    @Test
    func GlobalConstWithoutInitializer() {
        let shader = parse("const x: i32;")
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "Expected a =, but got a ;")
    }

    @Test
    func GlobalOverrideWithoutTypeOrInitializer() {
        let shader = parse("override x;")
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "override declaration requires a type or initializer")
    }

    @Test
    func LocalVarWithoutTypeOrInitializer() {
        let shader = parse(
            "fn f() {\n"
                + "   var x;\n"
                + "}"
        )
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "var declaration requires a type or initializer")
    }

    @Test
    func LocalLetWithoutTypeOrInitializer() {
        let shader = parse(
            "fn f() {\n"
                + "   let x;\n"
                + "}"
        )
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "Expected a =, but got a ;")
    }

    @Test
    func LocalLetWithoutInitializer() {
        let shader = parse(
            "fn f() {\n"
                + "   let x: i32;\n"
                + "}"
        )
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "Expected a =, but got a ;")
    }

    @Test
    func LocalConstWithoutTypeOrInitializer() {
        let shader = parse(
            "fn f() {\n"
                + "   const x;\n"
                + "}"
        )
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "Expected a =, but got a ;")
    }

    @Test
    func LocalConstWithoutInitializer() {
        let shader = parse(
            "fn f() {\n"
                + "   const x: i32;\n"
                + "}"
        )
        #expect(shader.hasValue == false)
        expectMessage(shader.error?.errors.first, "Expected a =, but got a ;")
    }
}

@Suite
struct WGSLParserTest {
    @Test
    func ShortCircuitAndExpression() throws {
        try testBinaryExpressionXY("x && y", .shortCircuitAnd, ["x", "y"])
        try testBinaryExpressionXYZ("x && y && z", [.shortCircuitAnd, .shortCircuitAnd], ["x", "y", "z"])
    }

    @Test
    func ShortCircuitOrExpression() throws {
        try testBinaryExpressionXY("x || y", .shortCircuitOr, ["x", "y"])
        try testBinaryExpressionXYZ("x || y || z", [.shortCircuitOr, .shortCircuitOr], ["x", "y", "z"])
    }

    // MARK: - Statements

    @Test
    func IfStatement() throws {
        let parsed = parse(
            """
            fn foo() {
                           if true {
                               return;
                           } else if false {
                               return;
                           } else {
                               return;
                           }
                    }
            """
        )

        guard let shader = expectShader(parsed) else {
            return
        }
        #expect(shader.count(shader.directives) == 0)
        #expect(shader.count(shader.declarations) == 1)
        let declaration = try at(shader, shader.declarations, 0)
        #expect(asFunction(declaration) != nil)

        let function = shader[try #require(asFunction(declaration))]
        let body = try statements(shader, function)
        #expect(shader.count(body) >= 1)
        let stmt = try at(shader, body, 0)
        expectIs(shader, WGSL.IfStatement.self, stmt)
        let ifStmt = try downcast(shader, WGSL.IfStatement.self, stmt)
        let testExpr = ifStmt.test
        expectIs(shader, BoolLiteral.self, testExpr)
        let trueBody = ifStmt.trueBody
        expectIs(shader, CompoundStatement.self, trueBody)
        let falseBody = try #require(ifStmt.maybeFalseBody)
        expectIs(shader, WGSL.IfStatement.self, falseBody)
    }
}
