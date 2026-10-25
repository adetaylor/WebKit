// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

private func latin1Source(_ text: String) -> SourceText {
    SourceText(latin1: ContiguousArray(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
}

private func utf16Source(_ text: String) -> SourceText {
    SourceText(utf16: ContiguousArray(text.utf16))
}

private func lexTokens(_ source: SourceText, _ classes: IdentifierCharacterClasses = .standardLibrary) -> [Token] {
    var lexer = Lexer(source, identifierCharacterClasses: classes)
    return lexer.lex()
}

private func text(_ source: SourceText, _ token: Token) -> String {
    var units = ContiguousArray<UInt16>()
    source.appendCodeUnits(token.identifierRange, to: &units)
    return String(decoding: units, as: UTF16.self)
}

private func types(_ tokens: [Token]) -> [TokenType] {
    tokens.map(\.type)
}

private struct TestLexer {
    let source: SourceText
    private let tokens: [Token]
    private var index = 0

    init(_ input: String) {
        source = latin1Source(input)
        tokens = lexTokens(source)
    }

    mutating func lex() -> Token {
        let token = tokens[index]
        index += 1
        return token
    }
}

@discardableResult
private func checkSingleToken(_ string: String, _ type: TokenType, sourceLocation: SourceLocation = #_sourceLocation) -> Token {
    var lexer = TestLexer(string)
    let result = lexer.lex()
    #expect(result.type == type, sourceLocation: sourceLocation)
    return result
}

private func checkSingleIntegerLiteral(
    _ string: String,
    _ type: TokenType,
    _ integerValue: Int64,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = checkSingleToken(string, type, sourceLocation: sourceLocation)
    #expect(result.integerValue == integerValue, sourceLocation: sourceLocation)
}

private func checkSingleFloatLiteral(
    _ string: String,
    _ type: TokenType,
    _ floatValue: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = checkSingleToken(string, type, sourceLocation: sourceLocation)
    #expect(result.floatValue == floatValue, sourceLocation: sourceLocation)
}

@discardableResult
private func checkNextTokenIs(
    _ lexer: inout TestLexer,
    _ type: TokenType,
    _ lineNumber: UInt32,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Token {
    let result = lexer.lex()
    #expect(result.type == type, sourceLocation: sourceLocation)
    #expect(result.span.line == lineNumber, sourceLocation: sourceLocation)
    return result
}

private func checkNextTokenIsIdentifier(
    _ lexer: inout TestLexer,
    _ ident: String,
    _ lineNumber: UInt32,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = checkNextTokenIs(&lexer, .identifier, lineNumber, sourceLocation: sourceLocation)
    #expect(text(lexer.source, result) == ident, sourceLocation: sourceLocation)
}

private func checkNextTokenIsIntegerLiteral(
    _ lexer: inout TestLexer,
    _ type: TokenType,
    _ integerValue: Int64,
    _ lineNumber: UInt32,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = checkNextTokenIs(&lexer, type, lineNumber, sourceLocation: sourceLocation)
    #expect(result.integerValue == integerValue, sourceLocation: sourceLocation)
}

private func checkNextTokenIsFloatLiteral(
    _ lexer: inout TestLexer,
    _ type: TokenType,
    _ floatValue: Double,
    _ lineNumber: UInt32,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = checkNextTokenIs(&lexer, type, lineNumber, sourceLocation: sourceLocation)
    #expect(result.floatValue == floatValue, sourceLocation: sourceLocation)
}

private func checkNextTokensAreBuiltinAttr(
    _ lexer: inout TestLexer,
    _ attr: String,
    _ lineNumber: UInt32,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    checkNextTokenIs(&lexer, .attribute, lineNumber, sourceLocation: sourceLocation)
    checkNextTokenIsIdentifier(&lexer, "builtin", lineNumber, sourceLocation: sourceLocation)
    checkNextTokenIs(&lexer, .parenLeft, lineNumber, sourceLocation: sourceLocation)
    checkNextTokenIsIdentifier(&lexer, attr, lineNumber, sourceLocation: sourceLocation)
    checkNextTokenIs(&lexer, .parenRight, lineNumber, sourceLocation: sourceLocation)
}

private let computeShaderSource =
    "@block struct B {\n"
    + "    a: i32,\n"
    + "}\n"
    + "\n"
    + "@group(0) @binding(0)\n"
    + "var<storage, read_write> x: B;\n"
    + "\n"
    + "@compute\n"
    + "fn main() {\n"
    + "    x.a = 42;\n"
    + "}"

private let graphicsShaderSource =
    "@vertex\n"
    + "fn vertexShader(@location(0) x: vec4<f32>) -> @builtin(position) vec4<f32> {\n"
    + "    return x;\n"
    + "}\n"
    + "\n"
    + "@fragment\n"
    + "fn fragmentShader() -> @location(0) vec4<f32> {\n"
    + "    return vec4<f32>(0.4, 0.4, 0.8, 1.0);\n"
    + "}"

private let triangleVertSource =
    "@vertex\n"
    + "fn main(\n"
    + "    @builtin(vertex_index) VertexIndex : u32\n"
    + ") -> @builtin(position) vec4<f32> {\n"
    + "    var pos = array<vec2<f32>, 3>(\n"
    + "        vec2<f32>(0.0, 0.5),\n"
    + "        vec2<f32>(-0.5, -0.5),\n"
    + "        vec2<f32>(0.5, -0.5)\n"
    + "    );\n\n"
    + "    return vec4<f32>(pos[VertexIndex] + vec2<f32>(0.5, 0.5), 0.0, 1.0);\n"
    + "}\n"

// https://www.w3.org/TR/WGSL/#reserved-words, as Lexer.cpp lists them.
private let reservedWords: [String] = [
    "NULL",
    "Self",
    "abstract",
    "active",
    "alignas",
    "alignof",
    "as",
    "asm",
    "asm_fragment",
    "async",
    "attribute",
    "auto",
    "await",
    "become",
    "cast",
    "catch",
    "class",
    "co_await",
    "co_return",
    "co_yield",
    "coherent",
    "column_major",
    "common",
    "compile",
    "compile_fragment",
    "concept",
    "const_cast",
    "consteval",
    "constexpr",
    "constinit",
    "crate",
    "debugger",
    "decltype",
    "delete",
    "demote",
    "demote_to_helper",
    "do",
    "dynamic_cast",
    "enum",
    "explicit",
    "export",
    "extends",
    "extern",
    "external",
    "fallthrough",
    "filter",
    "final",
    "finally",
    "friend",
    "from",
    "fxgroup",
    "get",
    "goto",
    "groupshared",
    "highp",
    "impl",
    "implements",
    "import",
    "inline",
    "instanceof",
    "interface",
    "layout",
    "lowp",
    "macro",
    "macro_rules",
    "match",
    "mediump",
    "meta",
    "mod",
    "module",
    "move",
    "mut",
    "mutable",
    "namespace",
    "new",
    "nil",
    "noexcept",
    "noinline",
    "nointerpolation",
    "non_coherent",
    "noncoherent",
    "noperspective",
    "null",
    "nullptr",
    "of",
    "operator",
    "package",
    "packoffset",
    "partition",
    "pass",
    "patch",
    "pixelfragment",
    "precise",
    "precision",
    "premerge",
    "priv",
    "protected",
    "pub",
    "public",
    "readonly",
    "ref",
    "regardless",
    "register",
    "reinterpret_cast",
    "require",
    "resource",
    "restrict",
    "self",
    "set",
    "shared",
    "sizeof",
    "smooth",
    "snorm",
    "static",
    "static_assert",
    "static_cast",
    "std",
    "subroutine",
    "super",
    "target",
    "template",
    "this",
    "thread_local",
    "throw",
    "trait",
    "try",
    "type",
    "typedef",
    "typeid",
    "typename",
    "typeof",
    "union",
    "unless",
    "unorm",
    "unsafe",
    "unsized",
    "use",
    "using",
    "varying",
    "virtual",
    "volatile",
    "wgsl",
    "where",
    "with",
    "writeonly",
    "yield",
]

@Suite
struct WGSLLexerTests {
    @Test
    func Comments() {
        checkSingleToken(
            "// This is line-ending comment.\n"
                + "/* This is a block comment\n"
                + "   that spans lines.\n"
                + "   /* Block comments can nest.\n"
                + "    */\n"
                + "   But all block comments must terminate.\n"
                + "*/",
            .endOfFile
        )
    }

    @Test
    func SingleTokens() {
        checkSingleToken("", .endOfFile)
        checkSingleIntegerLiteral("1", .integerLiteral, 1)
        checkSingleIntegerLiteral("0", .integerLiteral, 0)
        checkSingleIntegerLiteral("142", .integerLiteral, 142)
        checkSingleFloatLiteral("142f", .floatLiteral, 142.0)
        checkSingleFloatLiteral("1.1", .abstractFloatLiteral, 1.1)
        checkSingleFloatLiteral("0.4", .abstractFloatLiteral, 0.4)
        checkSingleFloatLiteral("0123.456", .abstractFloatLiteral, 0123.456)
        checkSingleToken("0123", .invalid)
        checkSingleFloatLiteral("0123.", .abstractFloatLiteral, 123)
        checkSingleFloatLiteral(".456", .abstractFloatLiteral, 0.456)
        checkSingleToken(".", .period)
        checkSingleFloatLiteral("42f", .floatLiteral, 42)
        checkSingleFloatLiteral("42e0f", .floatLiteral, 42)
        checkSingleFloatLiteral("042e0f", .floatLiteral, 42)
        checkSingleToken("042f", .invalid)
        checkSingleFloatLiteral("0123.f", .floatLiteral, 123)
        checkSingleFloatLiteral(".456f", .floatLiteral, Double(0.456 as Float))
        checkSingleFloatLiteral("42e-3", .abstractFloatLiteral, 42e-3)
        checkSingleFloatLiteral("42e-3f", .floatLiteral, Double(42e-3 as Float))
        checkSingleFloatLiteral(
            "34028235000000000000000000000000000000f",
            .floatLiteral,
            Double(34_028_234_663_852_885_981_170_418_348_451_692_544.0 as Float)
        )
    }

    @Test
    func KeywordTokens() {
        checkSingleToken("alias", .keywordAlias)
        checkSingleToken("break", .keywordBreak)
        checkSingleToken("case", .keywordCase)
        checkSingleToken("const", .keywordConst)
        checkSingleToken("const_assert", .keywordConstAssert)
        checkSingleToken("continue", .keywordContinue)
        checkSingleToken("default", .keywordDefault)
        checkSingleToken("diagnostic", .keywordDiagnostic)
        checkSingleToken("discard", .keywordDiscard)
        checkSingleToken("else", .keywordElse)
        checkSingleToken("enable", .keywordEnable)
        checkSingleToken("false", .keywordFalse)
        checkSingleToken("fn", .keywordFn)
        checkSingleToken("for", .keywordFor)
        checkSingleToken("if", .keywordIf)
        checkSingleToken("let", .keywordLet)
        checkSingleToken("loop", .keywordLoop)
        checkSingleToken("override", .keywordOverride)
        checkSingleToken("requires", .keywordRequires)
        checkSingleToken("return", .keywordReturn)
        checkSingleToken("struct", .keywordStruct)
        checkSingleToken("switch", .keywordSwitch)
        checkSingleToken("true", .keywordTrue)
        checkSingleToken("var", .keywordVar)
        checkSingleToken("while", .keywordWhile)
    }

    @Test
    func SpecialTokens() {
        checkSingleToken("->", .arrow)
        checkSingleToken("@", .attribute)
        checkSingleToken("!", .bang)
        checkSingleToken("!=", .bangEq)
        checkSingleToken("{", .braceLeft)
        checkSingleToken("}", .braceRight)
        checkSingleToken("[", .bracketLeft)
        checkSingleToken("]", .bracketRight)
        checkSingleToken(":", .colon)
        checkSingleToken(",", .comma)
        checkSingleToken("=", .equal)
        checkSingleToken("==", .eqEq)
        checkSingleToken(">", .gt)
        checkSingleToken(">=", .gtEq)
        checkSingleToken(">>", .gtGt)
        checkSingleToken(">>=", .gtGtEq)
        checkSingleToken("<", .lt)
        checkSingleToken("<=", .ltEq)
        checkSingleToken("<<", .ltLt)
        checkSingleToken("<<=", .ltLtEq)
        checkSingleToken("-", .minus)
        checkSingleToken("--", .minusMinus)
        checkSingleToken("-=", .minusEq)
        checkSingleToken("%", .modulo)
        checkSingleToken("%=", .moduloEq)
        checkSingleToken(".", .period)
        checkSingleToken("(", .parenLeft)
        checkSingleToken(")", .parenRight)
        checkSingleToken(";", .semicolon)
        checkSingleToken("/", .slash)
        checkSingleToken("/=", .slashEq)
        checkSingleToken("*", .star)
        checkSingleToken("*=", .starEq)
        checkSingleToken("+", .plus)
        checkSingleToken("++", .plusPlus)
        checkSingleToken("+=", .plusEq)
        checkSingleToken("&", .and)
        checkSingleToken("&&", .andAnd)
        checkSingleToken("&=", .andEq)
        checkSingleToken("|", .or)
        checkSingleToken("||", .orOr)
        checkSingleToken("|=", .orEq)
        checkSingleToken("^", .xor)
        checkSingleToken("^=", .xorEq)
        checkSingleToken("~", .tilde)
        checkSingleToken("_", .underbar)
    }

    @Test
    func ComputeShader() {
        var lexer = TestLexer(computeShaderSource)

        var lineNumber: UInt32 = 1
        // @block struct B {
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "block", lineNumber)
        checkNextTokenIs(&lexer, .keywordStruct, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "B", lineNumber)
        checkNextTokenIs(&lexer, .braceLeft, lineNumber)

        // a: i32;
        lineNumber += 1
        checkNextTokenIsIdentifier(&lexer, "a", lineNumber)
        checkNextTokenIs(&lexer, .colon, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "i32", lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)

        // }
        lineNumber += 1
        checkNextTokenIs(&lexer, .braceRight, lineNumber)

        // @group(0) @binding(0)
        lineNumber += 2
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "group", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsIntegerLiteral(&lexer, .integerLiteral, 0, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "binding", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsIntegerLiteral(&lexer, .integerLiteral, 0, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)

        // var<storage, read_write> x: B;
        lineNumber += 1
        checkNextTokenIs(&lexer, .keywordVar, lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "storage", lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "read_write", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "x", lineNumber)
        checkNextTokenIs(&lexer, .colon, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "B", lineNumber)
        checkNextTokenIs(&lexer, .semicolon, lineNumber)

        // @compute
        lineNumber += 2
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "compute", lineNumber)

        // fn main() {
        lineNumber += 1
        checkNextTokenIs(&lexer, .keywordFn, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "main", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .braceLeft, lineNumber)

        // x.a = 42;
        lineNumber += 1
        checkNextTokenIsIdentifier(&lexer, "x", lineNumber)
        checkNextTokenIs(&lexer, .period, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "a", lineNumber)
        checkNextTokenIs(&lexer, .equal, lineNumber)
        checkNextTokenIsIntegerLiteral(&lexer, .integerLiteral, 42, lineNumber)
        checkNextTokenIs(&lexer, .semicolon, lineNumber)

        // }
        lineNumber += 1
        checkNextTokenIs(&lexer, .braceRight, lineNumber)
        checkNextTokenIs(&lexer, .endOfFile, lineNumber)
    }

    @Test
    func GraphicsShader() {
        var lexer = TestLexer(graphicsShaderSource)

        var lineNumber: UInt32 = 1

        // @vertex
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vertex", lineNumber)

        lineNumber += 1
        // fn vertexShader(@location(0) x: vec4<f32>) -> @builtin(position) vec4<f32> {
        checkNextTokenIs(&lexer, .keywordFn, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vertexShader", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "location", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsIntegerLiteral(&lexer, .integerLiteral, 0, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "x", lineNumber)
        checkNextTokenIs(&lexer, .colon, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec4", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .arrow, lineNumber)
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "builtin", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "position", lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec4", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .braceLeft, lineNumber)

        // return x;
        lineNumber += 1
        checkNextTokenIs(&lexer, .keywordReturn, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "x", lineNumber)
        checkNextTokenIs(&lexer, .semicolon, lineNumber)

        // }
        lineNumber += 1
        checkNextTokenIs(&lexer, .braceRight, lineNumber)

        // @fragment
        lineNumber += 2
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "fragment", lineNumber)

        // fn fragmentShader() -> @location(0) vec4<f32> {
        lineNumber += 1
        checkNextTokenIs(&lexer, .keywordFn, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "fragmentShader", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .arrow, lineNumber)
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "location", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsIntegerLiteral(&lexer, .integerLiteral, 0, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec4", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .braceLeft, lineNumber)

        // return vec4<f32>(0.4, 0.4, 0.8, 1.0);
        lineNumber += 1
        checkNextTokenIs(&lexer, .keywordReturn, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec4", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.4, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.4, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.8, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 1.0, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .semicolon, lineNumber)

        // }
        lineNumber += 1
        checkNextTokenIs(&lexer, .braceRight, lineNumber)
        checkNextTokenIs(&lexer, .endOfFile, lineNumber)
    }

    @Test
    func TriangleVert() {
        var lexer = TestLexer(triangleVertSource)

        var lineNumber: UInt32 = 1

        // @vertex
        checkNextTokenIs(&lexer, .attribute, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vertex", lineNumber)

        lineNumber += 1
        // fn main(
        checkNextTokenIs(&lexer, .keywordFn, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "main", lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)

        lineNumber += 1
        //    @builtin(vertex_index) VertexIndex : u32
        checkNextTokensAreBuiltinAttr(&lexer, "vertex_index", lineNumber)
        checkNextTokenIsIdentifier(&lexer, "VertexIndex", lineNumber)
        checkNextTokenIs(&lexer, .colon, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "u32", lineNumber)

        lineNumber += 1
        // ) -> @builtin(position) vec4<f32> {
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .arrow, lineNumber)
        checkNextTokensAreBuiltinAttr(&lexer, "position", lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec4", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .braceLeft, lineNumber)

        lineNumber += 1
        //    var pos = array<vec2<f32>, 3>(
        checkNextTokenIs(&lexer, .keywordVar, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "pos", lineNumber)
        checkNextTokenIs(&lexer, .equal, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "array", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec2", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsIntegerLiteral(&lexer, .integerLiteral, 3, lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)

        lineNumber += 1
        //        vec2<f32>(0.0, 0.5),
        checkNextTokenIsIdentifier(&lexer, "vec2", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.0, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.5, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)

        lineNumber += 1
        //        vec2<f32>(-0.5, -0.5),
        checkNextTokenIsIdentifier(&lexer, "vec2", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIs(&lexer, .minus, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.5, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIs(&lexer, .minus, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.5, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)

        lineNumber += 1
        //        vec2<f32>(0.5, -0.5)
        checkNextTokenIsIdentifier(&lexer, "vec2", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.5, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIs(&lexer, .minus, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.5, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)

        lineNumber += 1
        //    );
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .semicolon, lineNumber)

        lineNumber += 2
        //    return vec4<f32>(pos[VertexIndex] + vec2<f32>(0.5, 0.5), 0.0, 1.0);
        checkNextTokenIs(&lexer, .keywordReturn, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec4", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "pos", lineNumber)
        checkNextTokenIs(&lexer, .bracketLeft, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "VertexIndex", lineNumber)
        checkNextTokenIs(&lexer, .bracketRight, lineNumber)
        checkNextTokenIs(&lexer, .plus, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "vec2", lineNumber)
        checkNextTokenIs(&lexer, .lt, lineNumber)
        checkNextTokenIsIdentifier(&lexer, "f32", lineNumber)
        checkNextTokenIs(&lexer, .gt, lineNumber)
        checkNextTokenIs(&lexer, .parenLeft, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.5, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.5, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 0.0, lineNumber)
        checkNextTokenIs(&lexer, .comma, lineNumber)
        checkNextTokenIsFloatLiteral(&lexer, .abstractFloatLiteral, 1.0, lineNumber)
        checkNextTokenIs(&lexer, .parenRight, lineNumber)
        checkNextTokenIs(&lexer, .semicolon, lineNumber)

        lineNumber += 1
        // }
        checkNextTokenIs(&lexer, .braceRight, lineNumber)
    }

    // MARK: - Swift-only

    @Test
    func IdentifierCharacterClassesRejectMalformedRanges() {
        #expect(IdentifierCharacterClasses.isWellFormed([]))
        #expect(IdentifierCharacterClasses.isWellFormed([0x41, 0x5B, 0x61, 0x7B]))
        #expect(IdentifierCharacterClasses.isWellFormed([0x41, 0x5B, 0x5B, 0x60, 0x10_0000, 0x11_0000]))
        #expect(!IdentifierCharacterClasses.isWellFormed([0x41]))
        #expect(!IdentifierCharacterClasses.isWellFormed([0x41, 0x5B, 0x61]))
        #expect(!IdentifierCharacterClasses.isWellFormed([0x41, 0x41]))
        #expect(!IdentifierCharacterClasses.isWellFormed([0x5B, 0x41]))
        #expect(!IdentifierCharacterClasses.isWellFormed([0x61, 0x7B, 0x41, 0x5B]))
        #expect(!IdentifierCharacterClasses.isWellFormed([0x41, 0x5B, 0x50, 0x60]))
        // The initializer traps on these: trap-tests scenario IdentifierCharacterClassesMalformedRanges.
    }

    @Test
    func IdentifierCharacterClassesOnlyClassifyNonASCII() {
        let none = IdentifierCharacterClasses(xidStartRanges: [], xidContinueRanges: [])
        for source in [latin1Source("_a9 Zz_0"), utf16Source("_a9 Zz_0")] {
            let tokens = lexTokens(source, none)
            #expect(types(tokens) == [.identifier, .identifier, .endOfFile])
            #expect(text(source, tokens[0]) == "_a9")
            #expect(text(source, tokens[1]) == "Zz_0")
        }
        for source in [latin1Source("\u{E9}t\u{E9}"), utf16Source("\u{E9}t\u{E9}")] {
            #expect(types(lexTokens(source, none)) == [.invalid])
            let tokens = lexTokens(source)
            #expect(types(tokens) == [.identifier, .endOfFile])
            #expect(text(source, tokens[0]) == "\u{E9}t\u{E9}")
            #expect(
                types(lexTokens(source, IdentifierCharacterClasses(xidStartRanges: [0xE9, 0xEA], xidContinueRanges: [0xE9, 0xEA]))) == [
                    .identifier, .endOfFile,
                ]
            )
        }
        // U+00B7 is XID_Continue but not XID_Start.
        for source in [latin1Source("a\u{B7}"), utf16Source("a\u{B7}")] {
            #expect(types(lexTokens(source)) == [.identifier, .endOfFile])
        }
        #expect(types(lexTokens(latin1Source("\u{B7}a"))) == [.invalid])
        #expect(types(lexTokens(utf16Source("\u{B7}a"))) == [.invalid])
    }

    // As in the C++, the UTF-16 isIdentifierContinue asks XID_Start first and the Latin-1 one asks only XID_Continue, which
    // only matters for classes where XID_Start is not a subset of XID_Continue.
    @Test
    func IdentifierContinueAsksStartFirstOnlyInUTF16() {
        let startOnly = IdentifierCharacterClasses(xidStartRanges: [0xE9, 0xEA], xidContinueRanges: [])
        #expect(types(lexTokens(latin1Source("a\u{E9}"), startOnly)) == [.identifier, .identifier, .endOfFile])
        #expect(types(lexTokens(utf16Source("a\u{E9}"), startOnly)) == [.identifier, .endOfFile])
    }

    @Test
    func SurrogatesAreNeverXID() {
        let surrogates = IdentifierCharacterClasses(xidStartRanges: [0xD800, 0xE000], xidContinueRanges: [0xD800, 0xE000])
        let loneSurrogates: [[UInt16]] = [[0xD800], [0xDC00], [0xD800, 0x61], [0xDC00, 0xD800], [0xDBFF, 0xDBFF]]
        for units in loneSurrogates {
            let source = SourceText(utf16: ContiguousArray(units))
            #expect(types(lexTokens(source)) == [.invalid])
            #expect(types(lexTokens(source, surrogates)) == [.invalid])
            let afterIdentifier = SourceText(utf16: ContiguousArray([0x61] + units))
            let tokens = lexTokens(afterIdentifier, surrogates)
            #expect(types(tokens) == [.identifier, .invalid])
            #expect(tokens[0].span.length == 1)
        }

        // U+10000 LINEAR B SYLLABLE B008 A is XID_Start; U+1F600 is not.
        let pair = utf16Source("\u{10000}x \u{10000}")
        let tokens = lexTokens(pair)
        #expect(types(tokens) == [.identifier, .identifier, .endOfFile])
        #expect(tokens[0].span == SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 3))
        #expect(tokens[1].span == SourceSpan(line: 1, lineOffset: 4, offset: 4, length: 2))
        #expect(text(pair, tokens[0]) == "\u{10000}x")
        #expect(types(lexTokens(utf16Source("\u{1F600}"))) == [.invalid])
        #expect(
            types(
                lexTokens(utf16Source("\u{1F600}"), IdentifierCharacterClasses(xidStartRanges: [0x1F600, 0x1F601], xidContinueRanges: []))
            ) == [
                .identifier, .endOfFile,
            ]
        )
    }

    @Test
    func UTF16MatchesLatin1() {
        let inputs = [
            computeShaderSource, graphicsShaderSource, triangleVertSource, "a >>= b >> c >= d -- e", "/* x */ 0x1.8p1 1e-3h 7u",
            "fn __x() {}", "\u{E9}\u{B7}\u{FF} \u{85} \u{AA}", "/* unterminated", "x // y\r\nz",
        ]
        for input in inputs {
            #expect(lexTokens(latin1Source(input)) == lexTokens(utf16Source(input)), "\(input)")
        }
    }

    @Test
    func Placeholders() {
        let tokens = lexTokens(latin1Source(">>= >> >= -- > -"))
        #expect(
            types(tokens) == [
                .gtGtEq, .placeholder, .placeholder, .gtGt, .placeholder, .gtEq, .placeholder, .minusMinus, .placeholder, .gt, .minus,
                .endOfFile,
            ]
        )
        #expect(tokens[1].span == tokens[0].span)
        #expect(tokens[2].span == tokens[0].span)
        #expect(tokens[4].span == tokens[3].span)
        #expect(tokens[6].span == tokens[5].span)
        #expect(tokens[8].span == tokens[7].span)
        #expect(tokens[7].span == SourceSpan(line: 1, lineOffset: 10, offset: 10, length: 2))
    }

    @Test
    func InvalidTokens() {
        // A comment that does not terminate makes an Invalid token with the span of the previous token's start.
        var tokens = lexTokens(latin1Source("/* unterminated"))
        #expect(types(tokens) == [.invalid])
        #expect(tokens[0].span == SourceSpan(line: 0, lineOffset: 0, offset: 0, length: 15))
        tokens = lexTokens(latin1Source("ab\n/* x"))
        #expect(types(tokens) == [.identifier, .invalid])
        #expect(tokens[1].span == SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 7))
        #expect(types(lexTokens(latin1Source("a // b\u{0}\nc"))) == [.identifier, .invalid])
        #expect(types(lexTokens(latin1Source("a /* b\u{0} */ c"))) == [.identifier, .invalid])
        #expect(types(lexTokens(latin1Source("a\u{0}b"))) == [.identifier, .invalid])

        #expect(types(lexTokens(latin1Source("__x"))) == [.invalid])
        #expect(types(lexTokens(latin1Source("__"))) == [.invalid])
        #expect(types(lexTokens(latin1Source("_x x__ _"))) == [.identifier, .identifier, .underbar, .endOfFile])
        #expect(types(lexTokens(latin1Source("$"))) == [.invalid])
    }

    @Test
    func ReservedWords() {
        for word in reservedWords {
            #expect(types(lexTokens(latin1Source(word))) == [.reservedWord, .endOfFile], "\(word)")
            #expect(types(lexTokens(utf16Source(word))) == [.reservedWord, .endOfFile], "\(word)")
            #expect(types(lexTokens(latin1Source(word + "_"))) == [.identifier, .endOfFile], "\(word)_")
        }
        #expect(types(lexTokens(latin1Source("Null nULL self_ wgs"))) == [.identifier, .identifier, .identifier, .identifier, .endOfFile])
    }

    @Test
    func Keywords() {
        for type in TokenType.allCases
        where type.rawValue >= TokenType.keywordAlias.rawValue && type.rawValue <= TokenType.keywordWhile.rawValue {
            let spelling = toString(type).description
            #expect(types(lexTokens(latin1Source(spelling))) == [type, .endOfFile], "\(spelling)")
            #expect(types(lexTokens(utf16Source(spelling))) == [type, .endOfFile], "\(spelling)")
        }
    }

    @Test
    func LineBreaksAndWhitespace() {
        var tokens = lexTokens(latin1Source("a\rb\u{0B}c\u{0C}d\u{85}e\tf\ng\r\nh"))
        #expect(tokens.map(\.span.line) == [1, 1, 1, 1, 1, 1, 2, 3, 3])
        #expect(tokens[7].span == SourceSpan(line: 3, lineOffset: 0, offset: 15, length: 1))

        // The UTF-16 lexer also skips U+200E, U+200F, U+2028 and U+2029; only "\n" starts a line.
        let source = utf16Source("a\u{200E}b\u{200F}c\u{2028}d\u{2029}e // f\u{2028}g")
        tokens = lexTokens(source)
        #expect(types(tokens) == [.identifier, .identifier, .identifier, .identifier, .identifier, .identifier, .endOfFile])
        #expect(tokens.map(\.span.line) == [1, 1, 1, 1, 1, 1, 1])
        #expect(text(source, tokens[5]) == "g")
        #expect(types(lexTokens(utf16Source("\u{2028}"))) == [.endOfFile])
        #expect(types(lexTokens(utf16Source("\u{A0}"))) == [.invalid])
    }

    @Test
    func NumberLiterals() {
        checkSingleIntegerLiteral("2147483647i", .integerLiteralSigned, 2_147_483_647)
        checkSingleToken("2147483648i", .invalid)
        checkSingleIntegerLiteral("4294967295u", .integerLiteralUnsigned, 4_294_967_295)
        checkSingleToken("4294967296u", .invalid)
        checkSingleIntegerLiteral("9223372036854775807", .integerLiteral, Int64.max)
        checkSingleToken("9223372036854775808", .invalid)
        checkSingleIntegerLiteral("0x7fffffffi", .integerLiteralSigned, 0x7fff_ffff)
        checkSingleIntegerLiteral("0XFFu", .integerLiteralUnsigned, 255)
        checkSingleToken("0x", .invalid)
        checkSingleToken("1e", .invalid)
        checkSingleToken("1e+", .invalid)
        checkSingleFloatLiteral("0.1h", .halfLiteral, Double(Half(0.1)))
        checkSingleFloatLiteral("65504h", .halfLiteral, 65504)
        checkSingleToken("65505h", .invalid)
        checkSingleFloatLiteral("0h", .halfLiteral, 0)
        checkSingleFloatLiteral("0x1.8p1", .abstractFloatLiteral, 3)
        checkSingleFloatLiteral("0x.8p-1f", .floatLiteral, 0.25)
        // HexFloatExponentRequireSuffix: one exponent digit needs a suffix, two do not.
        checkSingleToken("0x1p2", .invalid)
        checkSingleFloatLiteral("0x1p2f", .floatLiteral, 4)
        checkSingleFloatLiteral("0x1p22", .abstractFloatLiteral, 4_194_304)
        checkSingleToken("1e400", .invalid)
        checkSingleFloatLiteral(".5e+1", .abstractFloatLiteral, 5)

        let tokens = lexTokens(latin1Source("1u.5"))
        #expect(types(tokens) == [.integerLiteralUnsigned, .abstractFloatLiteral, .endOfFile])
        #expect(tokens[1].span == SourceSpan(line: 1, lineOffset: 2, offset: 2, length: 2))
    }

    @Test
    func TokenTypeStrings() {
        #expect(toString(.invalid).description == "Invalid")
        #expect(toString(.endOfFile).description == "EOF")
        #expect(toString(.templateArgsLeft).description == "<")
        #expect(toString(.templateArgsRight).description == ">")
        #expect(toString(.placeholder).description == "<placeholder>")
        #expect(toString(.keywordConstAssert).description == "const_assert")
        #expect(TokenType.allCases.count == 85)
        #expect(TokenType.templateArgsRight.rawValue == 84)
    }
}
