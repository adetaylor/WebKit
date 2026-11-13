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

private struct Read: Equatable {
    let name: String
    let depth: Int
    let value: Int?
}

/// Introduces every variable (after visiting its children) with its integer initializer as the value, and records the
/// scope depth and binding at every identifier expression.
private struct ScopeProbe: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<Int>()
    var reads: [Read] = []
    var introductions: [Int?] = []

    mutating func visit(_ variable: VariableID) {
        visitChildren(variable)
        let node = shaderModule[variable]
        var value = -1
        if let initializer = node.maybeInitializer, let literal = shaderModule.dynamicDowncast(AbstractIntegerLiteral.self, initializer) {
            value = Int(literal.value)
        }
        introductions.append(introduceVariable(node.name, value))
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        let name = shaderModule.symbols.text(of: shaderModule.symbol(of: expression.identifier))
        reads.append(
            Read(name: String(decoding: name.codeUnits, as: UTF16.self), depth: context.depth, value: readVariable(expression.identifier))
        )
    }
}

/// IOValidator.cpp:155 / AliasAnalysis.cpp:270: `AST::Visitor::visit(function)` from a ScopedVisitor skips the function scope.
private struct BypassingScopeProbe: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<Int>()
    var depths: [Int] = []

    mutating func visit(_ function: FunctionID) {
        visitChildren(function)
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        depths.append(context.depth)
    }
}

/// Overrides the scoped hooks and calls C++ `Base::visit(x)` as `scopedVisit`.
private struct OverridingScopeProbe: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<Int>()
    var depths: [Int] = []
    var hooks: [String] = []

    mutating func visit(_ function: FunctionID) {
        hooks.append("Function")
        scopedVisit(function)
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        hooks.append("CompoundStatement")
        scopedVisit(statement, id)
    }

    mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        hooks.append("ForStatement")
        scopedVisit(statement, id)
    }

    mutating func visit(_ loopStatement: LoopStatement, _ id: StatementID) {
        hooks.append("LoopStatement")
        scopedVisit(loopStatement, id)
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        depths.append(context.depth)
    }
}

private struct ScopeModuleBuilder: ~Copyable {
    var module = ShaderModule(source: SourceText(""))
    var offset: UInt32 = 0

    mutating func span() -> SourceSpan {
        offset += 1
        return SourceSpan(line: 1, lineOffset: offset, offset: offset, length: 1)
    }

    mutating func use(_ name: StaticString) -> ExpressionID {
        let span = span()
        return module.constructIdentifierExpression(span: span, identifier: module.makeIdentifier(name, span: span))
    }

    mutating func useStatement(_ name: StaticString) -> StatementID {
        let span = span()
        return module.construct(span: span, PhonyAssignmentStatement(rhs: use(name)))
    }

    mutating func variable(_ name: StaticString, _ value: Int64) -> VariableID {
        let span = span()
        let initializer = module.construct(span: span, AbstractIntegerLiteral(value: value))
        return module.constructVariable(
            span: span,
            flavor: .var,
            name: module.makeIdentifier(name),
            type: nil,
            initializer: initializer,
            attributes: module.makeEmptyList(AttributeID.self)
        )
    }

    mutating func declare(_ name: StaticString, _ value: Int64) -> StatementID {
        let span = span()
        return module.construct(span: span, VariableStatement(variable: variable(name, value)))
    }

    mutating func compound(_ statements: [StatementID]) -> StatementID {
        let span = span()
        return module.construct(
            span: span,
            CompoundStatement(attributes: module.makeEmptyList(AttributeID.self), statements: module.makeList(statements))
        )
    }
}

// var g = 7;
// fn f() {
//     var a = 1;
//     { var a = 2; _ = a; }
//     _ = a;
//     var a = 3;
//     for (var i = 4; i; ) { _ = i; }
//     _ = i;
//     loop { var l = 5; _ = l; continuing { break if l; } }
//     _ = l;
//     while (a) { var w = 6; _ = w; }
//     _ = w;
//     _ = g;
// }
private func buildScopeModule() -> ShaderModule {
    var b = ScopeModuleBuilder()
    b.module.append(b.module.declarations, .variable(b.variable("g", 7)))
    var statements: [StatementID] = []
    statements.append(b.declare("a", 1))
    statements.append(b.compound([b.declare("a", 2), b.useStatement("a")]))
    statements.append(b.useStatement("a"))
    statements.append(b.declare("a", 3))
    let forInitializer = b.declare("i", 4)
    let forTest = b.use("i")
    let forBody = b.compound([b.useStatement("i")])
    let forSpan = b.span()
    statements.append(
        b.module.construct(
            span: forSpan,
            ForStatement(
                attributes: b.module.makeEmptyList(AttributeID.self),
                maybeInitializer: forInitializer,
                maybeTest: forTest,
                maybeUpdate: nil,
                body: forBody
            )
        )
    )
    statements.append(b.useStatement("i"))
    let loopBody = [b.declare("l", 5), b.useStatement("l")]
    let continuing = Continuing(
        body: b.module.makeEmptyList(StatementID.self),
        attributes: b.module.makeEmptyList(AttributeID.self),
        breakIf: b.use("l")
    )
    let loopSpan = b.span()
    statements.append(
        b.module.construct(
            span: loopSpan,
            LoopStatement(
                attributes: b.module.makeEmptyList(AttributeID.self),
                bodyAttributes: b.module.makeEmptyList(AttributeID.self),
                body: b.module.makeList(loopBody),
                continuing: continuing
            )
        )
    )
    statements.append(b.useStatement("l"))
    let whileTest = b.use("a")
    let whileBody = b.compound([b.declare("w", 6), b.useStatement("w")])
    let whileSpan = b.span()
    statements.append(
        b.module.construct(
            span: whileSpan,
            WhileStatement(attributes: b.module.makeEmptyList(AttributeID.self), test: whileTest, body: whileBody)
        )
    )
    statements.append(b.useStatement("w"))
    statements.append(b.useStatement("g"))
    let body = b.compound(statements)
    let functionSpan = b.span()
    let function = b.module.constructFunction(
        span: functionSpan,
        name: b.module.makeIdentifier("f"),
        parameters: b.module.makeEmptyList(ParameterID.self),
        returnType: nil,
        body: body,
        attributes: b.module.makeEmptyList(AttributeID.self),
        returnAttributes: b.module.makeEmptyList(AttributeID.self)
    )
    b.module.append(b.module.declarations, .function(function))
    return b.module
}

@Suite
struct WGSLScopedVisitorTests {
    @Test
    func scopePoints() {
        var probe = ScopeProbe(shaderModule: buildScopeModule())
        probe.visitShaderModule()
        let result = probe.result()
        #expect(result == nil)
        // Global scope 1, function 2, body 3; a nested block, for, loop and while body 4; for body and continuing 5.
        #expect(
            probe.reads == [
                Read(name: "a", depth: 4, value: 2),
                Read(name: "a", depth: 3, value: 1),
                Read(name: "i", depth: 4, value: 4),
                Read(name: "i", depth: 5, value: 4),
                Read(name: "i", depth: 3, value: nil),
                Read(name: "l", depth: 4, value: 5),
                Read(name: "l", depth: 5, value: 5),
                Read(name: "l", depth: 3, value: nil),
                Read(name: "a", depth: 3, value: 1),
                Read(name: "w", depth: 4, value: 6),
                Read(name: "w", depth: 3, value: nil),
                Read(name: "g", depth: 3, value: 7),
            ]
        )
        // g, a, a (shadowing), a again in the same scope (C++ nullptr), i, l, w.
        #expect(probe.introductions == [7, 1, 2, nil, 4, 5, 6])
        #expect(probe.context.depth == 1)
    }

    @Test
    func visitChildrenOfAFunctionBypassesTheFunctionScope() {
        var probe = BypassingScopeProbe(shaderModule: buildScopeModule())
        probe.visitShaderModule()
        #expect(probe.depths == [3, 2, 3, 4, 2, 3, 4, 2, 2, 3, 2, 2])
        #expect(probe.context.depth == 1)
    }

    @Test
    func overridingHooksKeepTheScopesThroughScopedVisit() {
        var probe = OverridingScopeProbe(shaderModule: buildScopeModule())
        probe.visitShaderModule()
        #expect(probe.depths == [4, 3, 4, 5, 3, 4, 5, 3, 3, 4, 3, 3])
        #expect(
            probe.hooks == [
                "Function", "CompoundStatement", "CompoundStatement", "ForStatement", "CompoundStatement", "LoopStatement",
                "CompoundStatement",
            ]
        )
        #expect(probe.context.depth == 1)
    }

    @Test
    func contextProviderBindings() {
        var module = ShaderModule(source: SourceText(""))
        let a = module.symbols.intern("a")
        let b = module.symbols.intern("b")
        let unseen = module.symbols.intern("unseen")
        var context = ContextProvider<String>()
        #expect(context.depth == 1)
        #expect(context.readVariable(a) == nil)
        #expect(context.introduceVariable(a, "global a") == "global a")
        #expect(context.introduceVariable(a, "global a again") == nil)
        #expect(context.readVariable(a) == "global a")
        let outer = context.openScope()
        #expect(context.depth == 2)
        #expect(context.readVariable(a) == "global a")
        #expect(context.introduceVariable(a, "outer a") == "outer a")
        #expect(context.introduceVariable(b, "outer b") == "outer b")
        let inner = context.openScope()
        #expect(context.introduceVariable(b, "inner b") == "inner b")
        #expect(context.readVariable(a) == "outer a")
        #expect(context.readVariable(b) == "inner b")
        context.closeScope(inner)
        #expect(context.readVariable(b) == "outer b")
        context.closeScope(outer)
        #expect(context.depth == 1)
        #expect(context.readVariable(a) == "global a")
        #expect(context.readVariable(b) == nil)
        #expect(context.readVariable(unseen) == nil)
        let reopened = context.openScope()
        #expect(context.introduceVariable(b, "reopened b") == "reopened b")
        context.closeScope(reopened)
        #expect(context.readVariable(b) == nil)
    }

    // The bindings cover only the range of symbols introduced so far, which grows below and above as needed.
    @Test
    func contextProviderBindingsOutOfOrder() {
        var module = ShaderModule(source: SourceText(""))
        var symbols: [Symbol] = []
        for index in 0..<300 {
            symbols.append(module.symbols.intern(ContiguousArray("s\(index)".utf16)))
        }
        let predeclared = module.symbols.intern("vec4f")
        var context = ContextProvider<Int>()
        #expect(context.readVariable(symbols[150]) == nil)
        #expect(context.introduceVariable(symbols[150], 150) == 150)
        #expect(context.introduceVariable(symbols[10], 10) == 10)
        #expect(context.introduceVariable(predeclared, -1) == -1)
        #expect(context.introduceVariable(symbols[299], 299) == 299)
        #expect(context.introduceVariable(symbols[10], 11) == nil)
        let scope = context.openScope()
        #expect(context.introduceVariable(symbols[10], 1_000) == 1_000)
        #expect(context.introduceVariable(symbols[0], 0) == 0)
        #expect(context.readVariable(symbols[10]) == 1_000)
        #expect(context.readVariable(predeclared) == -1)
        context.closeScope(scope)
        for (index, symbol) in symbols.enumerated() {
            let expected: Int? = [10, 150, 299].contains(index) ? index : nil
            #expect(context.readVariable(symbol) == expected)
        }
        #expect(context.readVariable(predeclared) == -1)
    }
}
