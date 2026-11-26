//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
//  Copyright (C) 2003-2023 Apple Inc. All rights reserved.
//  Copyright (C) 2003-2024 Apple Inc. All rights reserved.
//  Copyright (C) 2026 Apple Inc. All rights reserved.
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Library General Public
//  License as published by the Free Software Foundation; either
//  version 2 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Library General Public License for more details.
//
//  You should have received a copy of the GNU Library General Public License
//  along with this library; see the file COPYING.LIB.  If not, write to
//  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  Boston, MA 02110-1301, USA.
//

internal import JSCSwiftBoundary

/// A piece of an error message, kept as a value so that a save point can hold the message and the
/// facade's StringBuilder receives it once, when the parse fails.
enum ErrorMessagePart {
    case text(Swift.String)
    case identifier(JSC.JSParseIdentifier)
    case number(Int64)
    /// The characters of the provider from `start` to `end`.
    case source(start: Int, end: Int)
    /// The message of a regular expression syntax error: Yarr::ErrorCode's raw value.
    case regularExpressionError(UInt8)
}

struct ErrorMessage: ExpressibleByStringLiteral {
    /// A literal message is a pointer and a length, so that the grammar's failure paths build no array; the parts are
    /// made when the message is recorded.
    enum Storage {
        case literal(StaticString)
        case parts([ErrorMessagePart])
    }

    private let storage: Storage

    init(stringLiteral value: StaticString) {
        storage = .literal(value)
    }

    init(_ parts: [ErrorMessagePart]) {
        storage = .parts(parts)
    }

    // A message of several parts, out of line and of fixed arity, so that the array is allocated here and not in each caller's frame.
    @inline(never)
    init(_ a: ErrorMessagePart, _ b: ErrorMessagePart) {
        self.init([a, b])
    }

    @inline(never)
    init(_ a: ErrorMessagePart, _ b: ErrorMessagePart, _ c: ErrorMessagePart) {
        self.init([a, b, c])
    }

    @inline(never)
    init(_ a: ErrorMessagePart, _ b: ErrorMessagePart, _ c: ErrorMessagePart, _ d: ErrorMessagePart) {
        self.init([a, b, c, d])
    }

    @inline(never)
    init(_ a: ErrorMessagePart, _ b: ErrorMessagePart, _ c: ErrorMessagePart, _ d: ErrorMessagePart, _ e: ErrorMessagePart) {
        self.init([a, b, c, d, e])
    }

    /// Appends this message's parts to `parts`, making no array for a literal.
    func append(to parts: inout [ErrorMessagePart]) {
        switch storage {
        case .literal(let text): parts.append(.text(text.description))
        case .parts(let own): parts.append(contentsOf: own)
        }
    }

    /// How many parts `append(to:)` appends.
    var partCount: Int {
        switch storage {
        case .literal: return 1
        case .parts(let own): return own.count
        }
    }

    var parts: [ErrorMessagePart] {
        switch storage {
        case .literal(let text): return [.text(text.description)]
        case .parts(let parts): return parts
        }
    }

    var isEmpty: Bool {
        switch storage {
        case .literal(let text): return text.utf8CodeUnitCount == 0
        case .parts(let parts): return parts.isEmpty
        }
    }
}

extension Parser {
    // MARK: Errors

    var hasError: Bool { errorMessage != nil }

    /// Records the message of the first failure; a later one does not replace it.
    @inline(never)
    mutating func logError(_ message: ErrorMessage) {
        if hasError {
            return
        }
        errorMessage = message
    }

    /// Replaces the message.
    @inline(never)
    mutating func setErrorMessage(_ message: ErrorMessage) {
        errorMessage = message
    }

    /// Records the message and a full stop, unless one is recorded.
    @inline(never)
    mutating func logSemanticError(_ message: ErrorMessage) {
        if hasError {
            return
        }
        var parts: [ErrorMessagePart] = []
        parts.reserveCapacity(message.partCount + 1)
        message.append(to: &parts)
        parts.append(.text("."))
        errorMessage = ErrorMessage(parts)
    }

    /// True when a failure returns before its message is made.
    ///
    /// An error is recorded, or the token is the end of the script or an error token, which report themselves alone.
    /// The message's arguments are not evaluated then (a static block's mode has no functionKindName).
    var failsBeforeMessage: Bool {
        hasError || token.type == .eof || token.type.canBeError
    }

    /// Records the unexpected token, a full stop and the message; an end-of-script or error token reports itself alone.
    @inline(never)
    mutating func logTokenError(_ message: ErrorMessage) {
        if hasError {
            return
        }
        let head = unexpectedTokenMessage()
        var parts: [ErrorMessagePart] = []
        if token.type != .eof && !token.type.canBeError {
            // One allocation for the whole message.
            parts.reserveCapacity(head.partCount + message.partCount + 2)
            head.append(to: &parts)
            parts.append(.text(". "))
            message.append(to: &parts)
            parts.append(.text("."))
        } else {
            head.append(to: &parts)
        }
        errorMessage = ErrorMessage(parts)
    }

    /// Records the message with the token and returns the production's null.
    @inline(never)
    mutating func fail<Result: TreeHandle>(_ message: ErrorMessage) -> Result {
        logTokenError(message)
        return .null
    }

    /// Records the message with the token and returns false.
    mutating func fail(_ message: ErrorMessage) -> Bool {
        logTokenError(message)
        return false
    }

    /// Records the unexpected token and returns null.
    @inline(never)
    mutating func failDueToUnexpectedToken<Result: TreeHandle>() -> Result {
        recordUnexpectedToken()
        return .null
    }

    /// Records the unexpected token and returns false.
    mutating func failDueToUnexpectedToken() -> Bool {
        recordUnexpectedToken()
        return false
    }

    @inline(always)
    private mutating func recordUnexpectedToken() {
        if !hasError {
            errorMessage = unexpectedTokenMessage()
        }
    }

    /// Records the message without the token and returns null.
    @inline(never)
    mutating func semanticFail<Result: TreeHandle>(_ message: ErrorMessage) -> Result {
        logSemanticError(message)
        return .null
    }

    /// Records the message without the token and returns false.
    mutating func semanticFail(_ message: ErrorMessage) -> Bool {
        logSemanticError(message)
        return false
    }

    @inline(always)
    mutating func canRecurse(_ facade: inout JSC.JSParseFacade) -> Bool {
        facade.isSafeToRecurse()
    }

    @inline(never)
    mutating func failForStackOverflow<Result: TreeHandle>() -> Result {
        if hasError {
            return .null
        }
        hasStackOverflow = true
        logSemanticError("Stack exhausted")
        return .null
    }

    /// Appends the message to the facade's StringBuilder, or "Unparseable script" when there is none.
    func flushErrorMessage(_ facade: inout JSC.JSParseFacade) {
        guard let message = errorMessage, !message.isEmpty else {
            appendErrorText("Unparseable script", &facade)
            return
        }
        for part in message.parts {
            switch part {
            case .text(let text):
                appendErrorText(text, &facade)
            case .identifier(let identifier):
                facade.appendErrorIdentifier(identifier)
            case .number(let number):
                facade.appendErrorNumber(number)
            case .source(let start, let end):
                Unit.appendPrintedErrorCharacters(charactersBeforeFirstNUL(lexer.tokenCharacters(start..<end)), &facade)
            case .regularExpressionError(let code):
                facade.appendRegularExpressionErrorMessage(code)
            }
        }
    }

    private func appendErrorText(_ text: Swift.String, _ facade: inout JSC.JSParseFacade) {
        facade.appendErrorCharacters8(text.utf8.span)
    }

    /// The characters before the first NUL, where an error message ends a token.
    @_lifetime(copy characters)
    private func charactersBeforeFirstNUL(_ characters: Span<Unit>) -> Span<Unit> {
        var count = 0
        while count < characters.count && characters[count] != 0 {
            count += 1
        }
        return characters.extracting(first: count)
    }

    // MARK: Messages and predicates

    /// The text an unexpected-token error starts with.
    mutating func unexpectedTokenMessage() -> ErrorMessage {
        let text = ErrorMessagePart.source(start: Int(token.startPosition.offset), end: Int(token.endPosition.offset))
        switch token.type {
        case .eof:
            return "Unexpected end of script"
        case .unterminatedIdentifierEscapeError, .unterminatedIdentifierUnicodeEscapeError:
            return ErrorMessage(.text("Incomplete unicode escape in identifier: '"), text, .text("'"))
        case .unterminatedMultilineCommentError:
            return "Unterminated multiline comment"
        case .unterminatedNumericLiteralError:
            return ErrorMessage(.text("Unterminated numeric literal '"), text, .text("'"))
        case .unterminatedStringLiteralError:
            return ErrorMessage(.text("Unterminated string literal '"), text, .text("'"))
        case .invalidIdentifierEscapeError:
            return ErrorMessage(.text("Invalid escape in identifier: '"), text, .text("'"))
        case .escapedKeyword:
            return ErrorMessage(.text("Unexpected escaped characters in keyword token: '"), text, .text("'"))
        case .invalidIdentifierUnicodeEscapeError:
            return ErrorMessage(.text("Invalid unicode escape in identifier: '"), text, .text("'"))
        case .invalidNumericLiteralError:
            return ErrorMessage(.text("Invalid numeric literal: '"), text, .text("'"))
        case .unterminatedOctalNumberError:
            return ErrorMessage(.text("Invalid use of octal: '"), text, .text("'"))
        case .invalidStringLiteralError:
            return ErrorMessage(.text("Invalid string literal: '"), text, .text("'"))
        case .invalidUnicodeEncodingError:
            return ErrorMessage(.text("Invalid unicode encoding: '"), text, .text("'"))
        case .invalidIdentifierUnicodeError:
            return ErrorMessage(.text("Invalid unicode code point in identifier: '"), text, .text("'"))
        case .error:
            return ErrorMessage(.text("Unrecognized token '"), text, .text("'"))
        case .string:
            return ErrorMessage(.text("Unexpected string literal "), text)
        case .integer, .double:
            return ErrorMessage(.text("Unexpected number '"), text, .text("'"))
        case .reservedIfStrict:
            return ErrorMessage(.text("Unexpected use of reserved word '"), text, .text("' in strict mode"))
        case .reserved:
            return ErrorMessage(.text("Unexpected use of reserved word '"), text, .text("'"))
        case .invalidPrivateNameError:
            return ErrorMessage(.text("Invalid private name '"), text, .text("'"))
        case .privateName:
            return ErrorMessage(.text("Unexpected private name "), text)
        case .awaitKeyword, .identifier:
            return ErrorMessage(.text("Unexpected identifier '"), text, .text("'"))
        default:
            break
        }

        if token.type.isKeyword {
            return ErrorMessage(.text("Unexpected keyword '"), text, .text("'"))
        }
        return ErrorMessage(.text("Unexpected token '"), text, .text("'"))
    }

    /// Logs the failure and returns true when `token` cannot be used as a `kind`.
    mutating func failDueToKeyword(_ token: Token, _ kind: Swift.String, _ facade: inout JSC.JSParseFacade) -> Bool {
        let text = ErrorMessagePart.source(start: Int(token.startPosition.offset), end: Int(token.endPosition.offset))
        if strictMode && token.type == .reservedIfStrict {
            logSemanticError(ErrorMessage(.text("Cannot use the reserved word '"), text, .text("' as a \(kind) in strict mode")))
            return true
        }
        if token.type == .reserved || token.type == .reservedIfStrict {
            logSemanticError(ErrorMessage(.text("Cannot use the reserved word '"), text, .text("' as a \(kind)")))
            return true
        }
        if token.type.isKeyword {
            if !token.type.isContextualKeyword {
                logSemanticError(ErrorMessage(.text("Cannot use the keyword '"), text, .text("' as a \(kind)")))
                return true
            }
            if token.type == .letKeyword && strictMode {
                logSemanticError(.text("Cannot use 'let' as a \(kind) \(disallowedIdentifierLetReason())"))
                return true
            }
            if token.type == .awaitKeyword && !canUseIdentifierAwait {
                logSemanticError(.text("Cannot use 'await' as a \(kind) \(disallowedIdentifierAwaitReason())"))
                return true
            }
            if token.type == .yieldKeyword && !canUseIdentifierYield {
                logSemanticError(.text("Cannot use 'yield' as a \(kind) \(disallowedIdentifierYieldReason())"))
                return true
            }
        }
        return false
    }

    /// Consumes type, or records the message with the token and returns false.
    mutating func consumeOrFail(_ type: JSC.JSTokenType, _ message: ErrorMessage, _ facade: inout JSC.JSParseFacade) -> Bool {
        if consume(type, [], &facade) {
            return true
        }
        logTokenError(message)
        return false
    }

    /// Consumes type, or records "Expected '<tokenString>' to <operation> <production>" and returns false.
    mutating func handleProductionOrFail(
        _ type: JSC.JSTokenType,
        _ tokenString: Swift.String,
        _ operation: Swift.String,
        _ production: Swift.String,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        if consume(type, [], &facade) {
            return true
        }
        logProductionError(tokenString, operation, production)
        return false
    }

    // Out of line, so a production that is there builds no message (the interpolation allocates).
    @inline(never)
    private mutating func logProductionError(_ tokenString: Swift.String, _ operation: Swift.String, _ production: Swift.String) {
        logTokenError(ErrorMessage.text("Expected '\(tokenString)' to \(operation) \(production)"))
    }
}

extension ErrorMessage {
    /// Out of line, as the multi-part ErrorMessage initialisers.
    @inline(never)
    static func text(_ string: Swift.String) -> ErrorMessage { ErrorMessage([.text(string)]) }
}
