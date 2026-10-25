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

// The expected strings are the reference C++ parser's output on the same inputs (Parser.cpp: disambiguateTemplates,
// maybeSplitToken, the '--' splits of canBeginUnaryExpression/canContinueAdditiveExpression, and parse()). Tokens are
// spelled with toString(TokenType), except that TemplateArgsLeft/Right are TAL/TAR.

private func makeParser(_ source: SourceText) -> Parser {
    Parser(ShaderModule(source: source), Lexer(source, identifierCharacterClasses: .standardLibrary))
}

private func name(_ type: TokenType) -> String {
    switch type {
    case .templateArgsLeft: "TAL"
    case .templateArgsRight: "TAR"
    default: toString(type).description
    }
}

private func spelled(_ tokens: [Token]) -> String {
    tokens.map { name($0.type) }.joined(separator: " ")
}

private func disambiguated(_ source: SourceText) -> String {
    var parser = makeParser(source)
    parser.disambiguateTemplates()
    return spelled(parser.tokens)
}

private func disambiguated(_ text: String) -> String {
    disambiguated(SourceText(text))
}

private func split(_ text: String, at index: Int) -> String {
    var parser = makeParser(SourceText(text))
    parser.maybeSplitToken(index)
    return spelled(parser.tokens)
}

private enum UnarySplit {
    case beginUnary
    case continueAdditive
}

// consume()s `count` tokens, asks the predicate about the current token, then consumes to the end, recording
// "index:token" for each token it lands on.
private func splitMinusMinus(_ text: String, after count: Int, _ predicate: UnarySplit) -> String {
    var parser = makeParser(SourceText(text))
    var consumed = 0
    while consumed < count {
        parser.consume()
        consumed += 1
    }
    let token = parser.current
    let result =
        switch predicate {
        case .beginUnary: parser.canBeginUnaryExpression(token)
        case .continueAdditive: parser.canContinueAdditiveExpression(token)
        }
    var description = "\(result) current=\(name(parser.current.type)) tokens=[\(spelled(parser.tokens))] consume=["
    while parser.current.type != .endOfFile {
        parser.consume()
        description += "\(parser.currentTokenIndex):\(name(parser.current.type)) "
    }
    return description + "]"
}

private func parseOutcome(_ text: String) -> String {
    var shaderModule = ShaderModule(source: SourceText(text))
    var description = ""
    if let failed = parse(&shaderModule) {
        for message in failed.errors {
            let span = message.span
            description += "error \(span.line):\(span.lineOffset):\(span.offset):\(span.length) \(message.message); "
        }
        for message in failed.warnings {
            let span = message.span
            description += "warning \(span.line):\(span.lineOffset):\(span.offset):\(span.length) \(message.message); "
        }
    } else {
        description = "ok"
    }
    let extensions = shaderModule.enabledExtensions.rawValue
    let features = shaderModule.requiredFeatures.rawValue
    let declarations = shaderModule.count(shaderModule.declarations)
    let directives = shaderModule.count(shaderModule.directives)
    return description + " ext=\(extensions) feat=\(features) decls=\(declarations) dirs=\(directives)"
}

@Suite
struct WGSLParserTokenStreamTests {
    @Test
    func templateArgumentLists() {
        #expect(
            disambiguated("var<private> x: array<vec4<f32>, 4>;")
                == "var TAL Identifier TAR Identifier : Identifier TAL Identifier TAL Identifier TAR , IntegerLiteral TAR ; EOF"
        )
        #expect(
            disambiguated("var<storage, read_write> v: array<array<u32, 2>>;")
                == "var TAL Identifier , Identifier TAR Identifier : Identifier TAL Identifier TAL Identifier , IntegerLiteral TAR TAR ; EOF"
        )
        #expect(disambiguated("select(a<b, c>d)") == "Identifier ( Identifier TAL Identifier , Identifier TAR Identifier ) EOF")
    }

    @Test
    func templateArgumentListsAreTheSameForUTF16Source() {
        let text = "var<storage, read_write> v: array<vec4<f32>>;"
        #expect(disambiguated(SourceText(utf16: ContiguousArray(text.utf16))) == disambiguated(text))
    }

    @Test
    func closingTokensAreSplit() {
        #expect(disambiguated("array<vec4<f32>>") == "Identifier TAL Identifier TAL Identifier TAR TAR EOF")
        #expect(disambiguated("a<b>=c") == "Identifier TAL Identifier TAR = Identifier EOF")
        #expect(disambiguated("x<a<b>>=c") == "Identifier TAL Identifier TAL Identifier TAR TAR = Identifier EOF")
        #expect(disambiguated("x = a<b>>c;") == "Identifier = Identifier TAL Identifier TAR > Identifier ; EOF")
        #expect(disambiguated("f(a<b>>=c)") == "Identifier ( Identifier TAL Identifier TAR >= <placeholder> Identifier ) EOF")
    }

    @Test
    func operatorsOutsideTemplatesAreNotSplit() {
        #expect(disambiguated("a >> b") == "Identifier >> <placeholder> Identifier EOF")
        #expect(disambiguated("a >= b") == "Identifier >= <placeholder> Identifier EOF")
    }

    @Test
    func shortCircuitOperatorsEndCandidates() {
        #expect(disambiguated("a<b || c>d") == "Identifier < Identifier || Identifier > Identifier EOF")
        #expect(disambiguated("a<b && c>d") == "Identifier < Identifier && Identifier > Identifier EOF")
        #expect(disambiguated("a<(b || c)>d") == "Identifier TAL ( Identifier || Identifier ) TAR Identifier EOF")
    }

    @Test
    func nestedExpressions() {
        #expect(disambiguated("a<(b>c)>d") == "Identifier TAL ( Identifier > Identifier ) TAR Identifier EOF")
        #expect(disambiguated("a[b<c]>d") == "Identifier [ Identifier < Identifier ] > Identifier EOF")
        #expect(disambiguated(") a<b>") == ") Identifier TAL Identifier TAR EOF")
    }

    @Test
    func expressionTerminatorsClearCandidates() {
        #expect(disambiguated("a<b; c>d") == "Identifier < Identifier ; Identifier > Identifier EOF")
        #expect(disambiguated("a<b{c>d") == "Identifier < Identifier { Identifier > Identifier EOF")
        #expect(disambiguated("a<b = c>d") == "Identifier < Identifier = Identifier > Identifier EOF")
        #expect(disambiguated("a<b:c>d") == "Identifier < Identifier : Identifier > Identifier EOF")
    }

    @Test
    func shortStreams() {
        #expect(disambiguated("a<") == "Identifier < EOF")
        #expect(disambiguated("") == "EOF")
    }

    @Test
    func maybeSplitToken() {
        #expect(split("a>>b", at: 1) == "Identifier > > Identifier EOF")
        #expect(split("a>=b", at: 1) == "Identifier > = Identifier EOF")
        #expect(split("a>>=b", at: 1) == "Identifier > >= <placeholder> Identifier EOF")
        #expect(split("a>>=b", at: 2) == "Identifier >>= <placeholder> <placeholder> Identifier EOF")
        #expect(split("a>>b", at: 0) == "Identifier >> <placeholder> Identifier EOF")
        #expect(split("a>b", at: 1) == "Identifier > Identifier EOF")
        #expect(split("a<b", at: 1) == "Identifier < Identifier EOF")
    }

    @Test
    func minusMinusSplitsWhenBeginningAUnaryExpression() {
        #expect(
            splitMinusMinus("--x", after: 0, .beginUnary) == "true current=- tokens=[-- - Identifier EOF] consume=[1:- 2:Identifier 3:EOF ]"
        )
        #expect(splitMinusMinus("-x", after: 0, .beginUnary) == "true current=- tokens=[- Identifier EOF] consume=[1:Identifier 2:EOF ]")
        #expect(splitMinusMinus("!x", after: 0, .beginUnary) == "true current=! tokens=[! Identifier EOF] consume=[1:Identifier 2:EOF ]")
        #expect(splitMinusMinus("+x", after: 0, .beginUnary) == "false current=+ tokens=[+ Identifier EOF] consume=[1:Identifier 2:EOF ]")
    }

    @Test
    func minusMinusSplitsWhenContinuingAnAdditiveExpression() {
        #expect(
            splitMinusMinus("a--b", after: 1, .continueAdditive)
                == "true current=- tokens=[Identifier -- - Identifier EOF] consume=[2:- 3:Identifier 4:EOF ]"
        )
        #expect(
            splitMinusMinus("a--", after: 1, .continueAdditive) == "true current=- tokens=[Identifier -- - EOF] consume=[2:- 3:EOF ]"
        )
        #expect(
            splitMinusMinus("a-b", after: 1, .continueAdditive)
                == "true current=- tokens=[Identifier - Identifier EOF] consume=[2:Identifier 3:EOF ]"
        )
        #expect(
            splitMinusMinus("a*b", after: 1, .continueAdditive)
                == "true current=* tokens=[Identifier * Identifier EOF] consume=[2:Identifier 3:EOF ]"
        )
        #expect(
            splitMinusMinus("a>b", after: 1, .continueAdditive)
                == "false current=> tokens=[Identifier > Identifier EOF] consume=[2:Identifier 3:EOF ]"
        )
    }

    @Test
    func directivesAndEmptyDeclarations() {
        #expect(parseOutcome("") == "ok ext=0 feat=0 decls=0 dirs=0")
        #expect(parseOutcome(";") == "ok ext=0 feat=0 decls=0 dirs=0")
        #expect(parseOutcome("enable f16, subgroups; ;;") == "ok ext=10 feat=0 decls=0 dirs=0")
        #expect(parseOutcome("enable f16;;") == "ok ext=2 feat=0 decls=0 dirs=0")
        #expect(parseOutcome("enable clip_distances,primitive_index,;") == "ok ext=5 feat=0 decls=0 dirs=0")
        #expect(
            parseOutcome("requires readonly_and_readwrite_storage_textures, pointer_composite_access;") == "ok ext=0 feat=6 decls=0 dirs=0"
        )
    }

    @Test
    func directiveErrors() {
        #expect(
            parseOutcome("enable foo;")
                == "error 1:0:0:10 Expected 'clip_distances', 'f16', 'primitive_index', or 'subgroups';  ext=0 feat=0 decls=0 dirs=0"
        )
        #expect(parseOutcome("enable;") == "error 1:0:0:6 Expected a Identifier, but got a ;;  ext=0 feat=0 decls=0 dirs=0")
        #expect(parseOutcome("enable f16 subgroups;") == "error 1:0:0:11 Expected a ;, but got a Identifier;  ext=2 feat=0 decls=0 dirs=0")
        #expect(parseOutcome("enable f16,") == "error 1:0:0:11 Expected a Identifier, but got a EOF;  ext=2 feat=0 decls=0 dirs=0")
        #expect(
            parseOutcome("requires clip_distances;")
                == "error 1:0:0:23 Expected 'clip_distances', 'readonly_and_readwrite_storage_textures', 'packed_4x8_integer_dot_product', 'unrestricted_pointer_parameters', 'texture_formats_tier1', 'subgroup_id', 'subgroup_uniformity', or 'pointer_composite_access';  ext=0 feat=0 decls=0 dirs=0"
        )
    }
}
