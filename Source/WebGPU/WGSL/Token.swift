// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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

@_spi(Testing)
public enum TokenType: UInt32, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    // Instead of having this type, we could have an optional Token everywhere that we currently have a Token.
    // I made this choice for two reasons:
    // - space efficiency: we don't use an extra word of memory for the variant's tag
    //     (although this part could be solved by using https://github.com/akrzemi1/markable)
    // - ease of use and time efficiency: everywhere that we check for a given TokenType, we would have to first check that the
    //     Token is not nil, and then check the TokenType.
    case invalid

    case endOfFile

    case abstractFloatLiteral
    case integerLiteral
    case integerLiteralSigned
    case integerLiteralUnsigned
    case floatLiteral
    case halfLiteral

    case identifier

    case reservedWord

    // https://www.w3.org/TR/WGSL/#keyword-summary
    case keywordAlias
    case keywordBreak
    case keywordCase
    case keywordConst
    case keywordConstAssert
    case keywordContinue
    case keywordContinuing
    case keywordDefault
    case keywordDiagnostic
    case keywordDiscard
    case keywordElse
    case keywordEnable
    case keywordFalse
    case keywordFn
    case keywordFor
    case keywordIf
    case keywordLet
    case keywordLoop
    case keywordOverride
    case keywordRequires
    case keywordReturn
    case keywordStruct
    case keywordSwitch
    case keywordTrue
    case keywordVar
    case keywordWhile

    case and
    case andAnd
    case andEq
    case arrow
    case attribute
    case bang
    case bangEq
    case braceLeft
    case braceRight
    case bracketLeft
    case bracketRight
    case colon
    case comma
    case equal
    case eqEq
    case gt
    case gtEq
    case gtGt
    case gtGtEq
    case lt
    case ltEq
    case ltLt
    case ltLtEq
    case minus
    case minusMinus
    case minusEq
    case modulo
    case moduloEq
    case or
    case orOr
    case orEq
    case parenLeft
    case parenRight
    case period
    case plus
    case plusPlus
    case plusEq
    case semicolon
    case slash
    case slashEq
    case star
    case starEq
    case tilde
    case underbar
    case xor
    case xorEq

    case placeholder
    case templateArgsLeft
    case templateArgsRight
}

@_spi(Testing)
public func toString(_ type: TokenType) -> StaticString {
    switch type {
    case .invalid:
        "Invalid"
    case .endOfFile:
        "EOF"
    case .abstractFloatLiteral:
        "AbstractFloatLiteral"
    case .integerLiteral:
        "IntegerLiteral"
    case .integerLiteralSigned:
        "IntegerLiteralSigned"
    case .integerLiteralUnsigned:
        "IntegerLiteralUnsigned"
    case .floatLiteral:
        "FloatLiteral"
    case .halfLiteral:
        "HalfLiteral"
    case .identifier:
        "Identifier"
    case .reservedWord:
        "ReservedWord"

    case .keywordAlias:
        "alias"
    case .keywordBreak:
        "break"
    case .keywordCase:
        "case"
    case .keywordConst:
        "const"
    case .keywordConstAssert:
        "const_assert"
    case .keywordContinue:
        "continue"
    case .keywordContinuing:
        "continuing"
    case .keywordDefault:
        "default"
    case .keywordDiagnostic:
        "diagnostic"
    case .keywordDiscard:
        "discard"
    case .keywordElse:
        "else"
    case .keywordEnable:
        "enable"
    case .keywordFalse:
        "false"
    case .keywordFn:
        "fn"
    case .keywordFor:
        "for"
    case .keywordIf:
        "if"
    case .keywordLet:
        "let"
    case .keywordLoop:
        "loop"
    case .keywordOverride:
        "override"
    case .keywordRequires:
        "requires"
    case .keywordReturn:
        "return"
    case .keywordStruct:
        "struct"
    case .keywordSwitch:
        "switch"
    case .keywordTrue:
        "true"
    case .keywordVar:
        "var"
    case .keywordWhile:
        "while"

    case .and:
        "&"
    case .andAnd:
        "&&"
    case .andEq:
        "&="
    case .arrow:
        "->"
    case .attribute:
        "@"
    case .bang:
        "!"
    case .bangEq:
        "!="
    case .bracketLeft:
        "["
    case .bracketRight:
        "]"
    case .braceLeft:
        "{"
    case .braceRight:
        "}"
    case .colon:
        ":"
    case .comma:
        ","
    case .equal:
        "="
    case .eqEq:
        "=="
    case .templateArgsRight, .gt:
        ">"
    case .gtEq:
        ">="
    case .gtGt:
        ">>"
    case .gtGtEq:
        ">>="
    case .templateArgsLeft, .lt:
        "<"
    case .ltEq:
        "<="
    case .ltLt:
        "<<"
    case .ltLtEq:
        "<<="
    case .minus:
        "-"
    case .minusMinus:
        "--"
    case .minusEq:
        "-="
    case .modulo:
        "%"
    case .moduloEq:
        "%="
    case .or:
        "|"
    case .orOr:
        "||"
    case .orEq:
        "|="
    case .plus:
        "+"
    case .plusPlus:
        "++"
    case .plusEq:
        "+="
    case .period:
        "."
    case .parenLeft:
        "("
    case .parenRight:
        ")"
    case .semicolon:
        ";"
    case .slash:
        "/"
    case .slashEq:
        "/="
    case .star:
        "*"
    case .starEq:
        "*="
    case .tilde:
        "~"
    case .underbar:
        "_"
    case .xor:
        "^"
    case .xorEq:
        "^="
    case .placeholder:
        "<placeholder>"
    }
}

@_spi(Testing)
public struct Token: BitwiseCopyable, Equatable, Sendable {
    @_spi(Testing)
    public var type: TokenType
    @_spi(Testing)
    public var span: SourceSpan
    // The C++ union of floatValue and integerValue. An identifier's text (the C++ ident) is the source range of its span.
    private var value: UInt64

    init(_ type: TokenType, _ position: SourcePosition, _ length: UInt32) {
        assert(
            type != .abstractFloatLiteral
                && type != .identifier
                && type != .integerLiteral
                && type != .integerLiteralSigned
                && type != .integerLiteralUnsigned
                && type != .floatLiteral
                && type != .halfLiteral
        )
        self.type = type
        span = SourceSpan(line: position.line, lineOffset: position.lineOffset, offset: position.offset, length: length)
        value = 0
    }

    init(_ type: TokenType, _ position: SourcePosition, _ length: UInt32, integerValue: Int64) {
        assert(type == .integerLiteral || type == .integerLiteralSigned || type == .integerLiteralUnsigned)
        self.type = type
        span = SourceSpan(line: position.line, lineOffset: position.lineOffset, offset: position.offset, length: length)
        value = UInt64(bitPattern: integerValue)
    }

    init(_ type: TokenType, _ position: SourcePosition, _ length: UInt32, floatValue: Double) {
        assert(type == .abstractFloatLiteral || type == .floatLiteral || type == .halfLiteral)
        self.type = type
        span = SourceSpan(line: position.line, lineOffset: position.lineOffset, offset: position.offset, length: length)
        value = floatValue.bitPattern
    }

    init(_ type: TokenType, _ position: SourcePosition, _ length: UInt32, ident: Range<Int>) {
        assert(type == .identifier)
        assert(ident.lowerBound == Int(position.offset) && ident.count == Int(length))
        self.type = type
        span = SourceSpan(line: position.line, lineOffset: position.lineOffset, offset: position.offset, length: length)
        value = 0
    }

    @_spi(Testing)
    public var floatValue: Double { Double(bitPattern: value) }

    @_spi(Testing)
    public var integerValue: Int64 { Int64(bitPattern: value) }

    /// C++ `ident`: the identifier's code units in the source.
    @_spi(Testing)
    public var identifierRange: Range<Int> { Int(span.offset)..<(Int(span.offset) + Int(span.length)) }
}
