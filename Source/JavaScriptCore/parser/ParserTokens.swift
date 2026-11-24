// Copyright (C) 2010, 2013 Apple Inc. All rights reserved.
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

internal import JSCSwiftBoundary

/// A token's type, with the values and bit layout of ParserTokens.h's JSTokenType.
extension JSC.JSTokenType {
    static let unaryOpFlag = JSC.UnaryOpTokenFlag.rawValue
    static let keywordFlag = JSC.KeywordTokenFlag.rawValue
    static let binaryOpAllowsInPrecedenceAdditionalShift = JSC.BinaryOpTokenAllowsInPrecedenceAdditionalShift.rawValue
    static let binaryOpPrecedenceMask = JSC.BinaryOpTokenPrecedenceMask.rawValue
    static let canBeErrorFlag = JSC.CanBeErrorTokenFlag.rawValue

    static let nullKeyword = JSC.NULLTOKEN
    static let trueKeyword = JSC.TRUETOKEN
    static let falseKeyword = JSC.FALSETOKEN
    static let breakKeyword = JSC.BREAK
    static let caseKeyword = JSC.CASE
    static let defaultKeyword = JSC.DEFAULT
    static let forKeyword = JSC.FOR
    static let newKeyword = JSC.NEW
    static let varKeyword = JSC.VAR
    static let constKeyword = JSC.CONSTTOKEN
    static let continueKeyword = JSC.CONTINUE
    static let functionKeyword = JSC.FUNCTION
    static let returnKeyword = JSC.RETURN
    static let ifKeyword = JSC.IF
    static let thisKeyword = JSC.THISTOKEN
    static let doKeyword = JSC.DO
    static let whileKeyword = JSC.WHILE
    static let switchKeyword = JSC.SWITCH
    static let withKeyword = JSC.WITH
    static let reserved = JSC.RESERVED
    static let reservedIfStrict = JSC.RESERVED_IF_STRICT
    static let throwKeyword = JSC.THROW
    static let tryKeyword = JSC.TRY
    static let catchKeyword = JSC.CATCH
    static let finallyKeyword = JSC.FINALLY
    static let debuggerKeyword = JSC.DEBUGGER
    static let elseKeyword = JSC.ELSE
    static let importKeyword = JSC.IMPORT
    static let exportKeyword = JSC.EXPORT_
    static let classKeyword = JSC.CLASSTOKEN
    static let extendsKeyword = JSC.EXTENDS
    static let superKeyword = JSC.SUPER
    static let letKeyword = JSC.LET
    static let yieldKeyword = JSC.YIELD
    static let awaitKeyword = JSC.AWAIT
    static let firstContextualKeyword = JSC.FirstContextualKeywordToken
    static let lastContextualKeyword = JSC.LastContextualKeywordToken
    static let openBrace = JSC.OPENBRACE
    static let closeBrace = JSC.CLOSEBRACE
    static let openParen = JSC.OPENPAREN
    static let closeParen = JSC.CLOSEPAREN
    static let openBracket = JSC.OPENBRACKET
    static let closeBracket = JSC.CLOSEBRACKET
    static let comma = JSC.COMMA
    static let question = JSC.QUESTION
    static let backQuote = JSC.BACKQUOTE
    static let integer = JSC.INTEGER
    static let double = JSC.DOUBLE
    static let bigInt = JSC.BIGINT
    static let identifier = JSC.IDENT
    static let privateName = JSC.PRIVATENAME
    static let string = JSC.STRING
    static let template = JSC.TEMPLATE
    static let regExp = JSC.REGEXP
    static let semicolon = JSC.SEMICOLON
    static let colon = JSC.COLON
    static let dot = JSC.DOT
    static let eof = JSC.EOFTOK
    static let equal = JSC.EQUAL
    static let plusEqual = JSC.PLUSEQUAL
    static let minusEqual = JSC.MINUSEQUAL
    static let multEqual = JSC.MULTEQUAL
    static let divEqual = JSC.DIVEQUAL
    static let lShiftEqual = JSC.LSHIFTEQUAL
    static let rShiftEqual = JSC.RSHIFTEQUAL
    static let urShiftEqual = JSC.URSHIFTEQUAL
    static let modEqual = JSC.MODEQUAL
    static let powEqual = JSC.POWEQUAL
    static let bitAndEqual = JSC.BITANDEQUAL
    static let bitXorEqual = JSC.BITXOREQUAL
    static let bitOrEqual = JSC.BITOREQUAL
    static let coalesceEqual = JSC.COALESCEEQUAL
    static let orEqual = JSC.OREQUAL
    static let andEqual = JSC.ANDEQUAL
    static let dotDotDot = JSC.DOTDOTDOT
    static let arrowFunction = JSC.ARROWFUNCTION
    static let questionDot = JSC.QUESTIONDOT
    static let plusPlus = JSC.PLUSPLUS
    static let minusMinus = JSC.MINUSMINUS
    static let autoPlusPlus = JSC.AUTOPLUSPLUS
    static let autoMinusMinus = JSC.AUTOMINUSMINUS
    static let exclamation = JSC.EXCLAMATION
    static let tilde = JSC.TILDE
    static let typeofKeyword = JSC.TYPEOF
    static let voidKeyword = JSC.VOIDTOKEN
    static let deleteKeyword = JSC.DELETETOKEN
    static let coalesce = JSC.COALESCE
    static let or = JSC.OR
    static let and = JSC.AND
    static let bitOr = JSC.BITOR
    static let bitXor = JSC.BITXOR
    static let bitAnd = JSC.BITAND
    static let eqEq = JSC.EQEQ
    static let ne = JSC.NE
    static let strEq = JSC.STREQ
    static let strNEq = JSC.STRNEQ
    static let lt = JSC.LT
    static let gt = JSC.GT
    static let le = JSC.LE
    static let ge = JSC.GE
    static let instanceofKeyword = JSC.INSTANCEOF
    static let inKeyword = JSC.INTOKEN
    static let lShift = JSC.LSHIFT
    static let rShift = JSC.RSHIFT
    static let urShift = JSC.URSHIFT
    static let plus = JSC.PLUS
    static let minus = JSC.MINUS
    static let times = JSC.TIMES
    static let divide = JSC.DIVIDE
    static let mod = JSC.MOD
    static let pow = JSC.POW
    static let error = JSC.ERRORTOK
    static let unterminatedIdentifierEscapeError = JSC.UNTERMINATED_IDENTIFIER_ESCAPE_ERRORTOK
    static let invalidIdentifierEscapeError = JSC.INVALID_IDENTIFIER_ESCAPE_ERRORTOK
    static let unterminatedIdentifierUnicodeEscapeError = JSC.UNTERMINATED_IDENTIFIER_UNICODE_ESCAPE_ERRORTOK
    static let invalidIdentifierUnicodeEscapeError = JSC.INVALID_IDENTIFIER_UNICODE_ESCAPE_ERRORTOK
    static let unterminatedMultilineCommentError = JSC.UNTERMINATED_MULTILINE_COMMENT_ERRORTOK
    static let unterminatedNumericLiteralError = JSC.UNTERMINATED_NUMERIC_LITERAL_ERRORTOK
    static let unterminatedOctalNumberError = JSC.UNTERMINATED_OCTAL_NUMBER_ERRORTOK
    static let invalidNumericLiteralError = JSC.INVALID_NUMERIC_LITERAL_ERRORTOK
    static let unterminatedStringLiteralError = JSC.UNTERMINATED_STRING_LITERAL_ERRORTOK
    static let invalidStringLiteralError = JSC.INVALID_STRING_LITERAL_ERRORTOK
    static let invalidPrivateNameError = JSC.INVALID_PRIVATE_NAME_ERRORTOK
    static let unterminatedHexNumberError = JSC.UNTERMINATED_HEX_NUMBER_ERRORTOK
    static let unterminatedBinaryNumberError = JSC.UNTERMINATED_BINARY_NUMBER_ERRORTOK
    static let unterminatedTemplateLiteralError = JSC.UNTERMINATED_TEMPLATE_LITERAL_ERRORTOK
    static let unterminatedRegexpLiteralError = JSC.UNTERMINATED_REGEXP_LITERAL_ERRORTOK
    static let invalidTemplateLiteralError = JSC.INVALID_TEMPLATE_LITERAL_ERRORTOK
    static let escapedKeyword = JSC.ESCAPED_KEYWORD
    static let invalidUnicodeEncodingError = JSC.INVALID_UNICODE_ENCODING_ERRORTOK
    static let invalidIdentifierUnicodeError = JSC.INVALID_IDENTIFIER_UNICODE_ERRORTOK

    var isUpdateOp: Bool { rawValue >= Self.plusPlus.rawValue && rawValue <= Self.autoMinusMinus.rawValue }
    var isKeyword: Bool { rawValue & Self.keywordFlag != 0 }
    var isContextualKeyword: Bool {
        rawValue >= Self.firstContextualKeyword.rawValue && rawValue <= Self.lastContextualKeyword.rawValue
    }
    var isAssignmentOperator: Bool { rawValue >= Self.equal.rawValue && rawValue <= Self.andEqual.rawValue }
    var isUnaryOp: Bool { rawValue & Self.unaryOpFlag != 0 }
    var canBeError: Bool { rawValue & Self.canBeErrorFlag != 0 }
    var isRestrictedKeyword: Bool {
        self == .continueKeyword || self == .breakKeyword || self == .returnKeyword || self == .throwKeyword
    }
}

// A token's value: `ident` holds the name, the cooked string, the BigInt digits or the pattern, `secondIdent` the raw
// template part or the flags; the named accessors read the one that holds the value for the token's type.
struct TokenData {
    var ident = JSC.JSParseIdentifier()
    var secondIdent = JSC.JSParseIdentifier()
    var doubleValue = 0.0
    var escaped = false
    var isTail = false
    var radix: UInt8 = 0

    var cooked: JSC.JSParseIdentifier {
        get { ident }
        set { ident = newValue }
    }
    var raw: JSC.JSParseIdentifier {
        get { secondIdent }
        set { secondIdent = newValue }
    }
    var bigIntString: JSC.JSParseIdentifier {
        get { ident }
        set { ident = newValue }
    }
    var pattern: JSC.JSParseIdentifier {
        get { ident }
        set { ident = newValue }
    }
    var flags: JSC.JSParseIdentifier {
        get { secondIdent }
        set { secondIdent = newValue }
    }
}

struct Token {
    var type = JSC.JSTokenType.error
    var data = TokenData()
    var startPosition = JSC.JSTextPosition()
    var endPosition = JSC.JSTextPosition()

    /// Whether the token is the keyword or an escaped spelling of it (`l\u0065t`), which the lexer reports as `.escapedKeyword`.
    @inline(always)
    func isPossiblyEscaped(
        _ keyword: JSC.JSTokenType,
        named name: JSC.JSParseWellKnownName,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        type == keyword || (type == .escapedKeyword && data.ident.matches(name, &facade))
    }

    var location: JSC.JSTokenLocation {
        var result = JSC.JSTokenLocation()
        result.startOffset = UInt32(truncatingIfNeeded: startPosition.offset)
        result.endOffset = UInt32(truncatingIfNeeded: endPosition.offset)
        return result
    }
}
