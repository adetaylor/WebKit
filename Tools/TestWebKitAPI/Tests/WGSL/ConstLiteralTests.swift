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

private struct ParsedPrimaryExpression: ~Copyable {
    let shaderModule: ShaderModule
    let expression: ExpressionID
}

private func parseLCharPrimaryExpression(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) -> ParsedPrimaryExpression? {
    let source = wtfSource(input)
    let shaderModule = ShaderModule(source: source, configuration: Configuration())
    let lexer = Lexer(source, identifierCharacterClasses: .standardLibrary)
    var parser = Parser(shaderModule, lexer)

    let expression: ExpressionID
    do throws(CompilationMessage) {
        expression = try parser.parsePrimaryExpression()
    } catch {
        Issue.record(Comment(rawValue: error.dumpDescription), sourceLocation: sourceLocation)
        return nil
    }
    return ParsedPrimaryExpression(shaderModule: parser.takeShaderModule(), expression: expression)
}

private struct ConstLiteralTestCase<NumberType> {
    let input: String
    let expectedValue: NumberType
}

@Suite
struct WGSLConstLiteralTests {
    @Test
    func BoolLiteral() {
        let testCases = [
            ConstLiteralTestCase(input: "true", expectedValue: true),
            ConstLiteralTestCase(input: "false", expectedValue: false),
        ]

        for testCase in testCases {
            guard let parseResult = parseLCharPrimaryExpression(testCase.input) else {
                continue
            }

            let expr = parseResult.expression
            expectIs(parseResult.shaderModule, WGSL.BoolLiteral.self, expr)

            let intLiteral = parseResult.shaderModule.dynamicDowncast(WGSL.BoolLiteral.self, expr)
            #expect(intLiteral?.value == testCase.expectedValue)
            let inputLength = UInt32(testCase.input.utf16.count)
            #expect(parseResult.shaderModule.span(of: expr) == SourceSpan(line: 1, lineOffset: 0, offset: 0, length: inputLength))
        }
    }

    @Test
    func AbstractIntegerLiteralDecimal() {
        let testCases = [
            ConstLiteralTestCase<Int64>(input: "0", expectedValue: 0),
            ConstLiteralTestCase<Int64>(input: "1", expectedValue: 1),
            ConstLiteralTestCase<Int64>(input: "12345", expectedValue: 12345),
        ]

        for testCase in testCases {
            guard let parseResult = parseLCharPrimaryExpression(testCase.input) else {
                continue
            }

            let expr = parseResult.expression
            expectIs(parseResult.shaderModule, AbstractIntegerLiteral.self, expr)

            let intLiteral = parseResult.shaderModule.dynamicDowncast(AbstractIntegerLiteral.self, expr)
            #expect(intLiteral?.value == testCase.expectedValue)
            let inputLength = UInt32(testCase.input.utf16.count)
            #expect(parseResult.shaderModule.span(of: expr) == SourceSpan(line: 1, lineOffset: 0, offset: 0, length: inputLength))
        }
    }

    @Test
    func AbstractIntegerLiteralHex() {
        let testCases = [
            ConstLiteralTestCase<Int64>(input: "0x0", expectedValue: 0x0),
            ConstLiteralTestCase<Int64>(input: "0x1", expectedValue: 0x1),
            ConstLiteralTestCase<Int64>(input: "0x12345", expectedValue: 0x12345),
        ]

        for testCase in testCases {
            guard let parseResult = parseLCharPrimaryExpression(testCase.input) else {
                continue
            }

            let expr = parseResult.expression
            expectIs(parseResult.shaderModule, AbstractIntegerLiteral.self, expr)

            let intLiteral = parseResult.shaderModule.dynamicDowncast(AbstractIntegerLiteral.self, expr)
            #expect(intLiteral?.value == testCase.expectedValue)
            let inputLength = UInt32(testCase.input.utf16.count)
            #expect(parseResult.shaderModule.span(of: expr) == SourceSpan(line: 1, lineOffset: 0, offset: 0, length: inputLength))
        }
    }

    @Test
    func AbstractFloatLiteralDec() {
        let testCases = [
            ConstLiteralTestCase<Double>(input: "0.0", expectedValue: 0.0),
            ConstLiteralTestCase<Double>(input: "0.1", expectedValue: 0.1),
            ConstLiteralTestCase<Double>(input: "2612.0324", expectedValue: 2612.0324),
            ConstLiteralTestCase<Double>(input: "0.00000001", expectedValue: 0.00000001),
            ConstLiteralTestCase<Double>(input: "1234.5678e-3", expectedValue: 1234.5678e-3),
            ConstLiteralTestCase<Double>(input: "01.", expectedValue: 01.0),
            ConstLiteralTestCase<Double>(input: ".01", expectedValue: 0.01),
            ConstLiteralTestCase<Double>(input: "1e-3", expectedValue: 1e-3),
        ]

        for testCase in testCases {
            guard let parseResult = parseLCharPrimaryExpression(testCase.input) else {
                continue
            }

            let expr = parseResult.expression
            expectIs(parseResult.shaderModule, AbstractFloatLiteral.self, expr)

            let floatLiteral = parseResult.shaderModule.dynamicDowncast(AbstractFloatLiteral.self, expr)
            #expect(floatLiteral?.value == testCase.expectedValue)
            let inputLength = UInt32(testCase.input.utf16.count)
            #expect(parseResult.shaderModule.span(of: expr) == SourceSpan(line: 1, lineOffset: 0, offset: 0, length: inputLength))
        }
    }
}
