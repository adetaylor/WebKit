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

extension Parser {
    mutating func parseShortCircuitExpression(
        _ lhs: ExpressionID,
        _ continuingToken: TokenType,
        _ op: BinaryOperation
    ) throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        var lhs = lhs
        while current.type == continuingToken {
            consume()
            let rhs = try parseRelationalExpression()
            lhs = shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                BinaryExpression(leftExpression: lhs, rightExpression: rhs, operation: op)
            )
        }

        return lhs
    }

    mutating func parseRelationalExpression() throws(CompilationMessage) -> ExpressionID {
        let unary = try parseUnaryExpression()
        let relational = try parseRelationalExpressionPostUnary(unary)
        return relational
    }

    mutating func parseRelationalExpressionPostUnary(_ lhs: ExpressionID) throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        var lhs = try parseShiftExpressionPostUnary(lhs)

        if canContinueRelationalExpression(current) {
            let op = toBinaryOperation(current)
            consume()
            let rhs = try parseShiftExpression()
            lhs = shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                BinaryExpression(leftExpression: lhs, rightExpression: rhs, operation: op)
            )
        }

        return lhs
    }

    mutating func parseShiftExpression() throws(CompilationMessage) -> ExpressionID {
        let unary = try parseUnaryExpression()
        let shift = try parseShiftExpressionPostUnary(unary)
        return shift
    }

    mutating func parseShiftExpressionPostUnary(_ lhs: ExpressionID) throws(CompilationMessage) -> ExpressionID {
        if canContinueAdditiveExpression(current) {
            return try parseAdditiveExpressionPostUnary(lhs)
        }

        let startOfElementPosition = currentPosition
        switch current.type {
        case .gtGt:
            consume()
            let rhs = try parseUnaryExpression()
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                BinaryExpression(leftExpression: lhs, rightExpression: rhs, operation: .rightShift)
            )

        case .ltLt:
            consume()
            let rhs = try parseUnaryExpression()
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                BinaryExpression(leftExpression: lhs, rightExpression: rhs, operation: .leftShift)
            )

        default: // lint-exempt(L-ENUM-1): every other token type ends the shift expression, as the C++ default
            return lhs
        }
    }

    mutating func parseAdditiveExpressionPostUnary(_ lhs: ExpressionID) throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        var lhs = try parseMultiplicativeExpressionPostUnary(lhs)

        while canContinueAdditiveExpression(current) {
            // parseMultiplicativeExpression handles multiplicative operators so
            // token should be PLUS or MINUS.
            assert(current.type == .plus || current.type == .minus)
            let op = toBinaryOperation(current)
            consume()
            let unary = try parseUnaryExpression()
            let rhs = try parseMultiplicativeExpressionPostUnary(unary)
            lhs = shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                BinaryExpression(leftExpression: lhs, rightExpression: rhs, operation: op)
            )
        }

        return lhs
    }

    mutating func parseBitwiseExpressionPostUnary(_ lhs: ExpressionID) throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        let op = toBinaryOperation(current)
        let continuingToken = current.type
        var lhs = lhs
        while current.type == continuingToken {
            consume()
            let rhs = try parseUnaryExpression()
            lhs = shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                BinaryExpression(leftExpression: lhs, rightExpression: rhs, operation: op)
            )
        }

        return lhs
    }

    mutating func parseMultiplicativeExpressionPostUnary(_ lhs: ExpressionID) throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        var lhs = lhs
        while canContinueMultiplicativeExpression(current) {
            let op: BinaryOperation
            switch current.type {
            case .modulo:
                op = .modulo

            case .slash:
                op = .divide

            case .star:
                op = .multiply

            default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default (RELEASE_ASSERT_NOT_REACHED)
                wgslFatal("not a multiplicative operator token", cppSite: "Parser.cpp:1774")
            }

            consume()
            let rhs = try parseUnaryExpression()
            lhs = shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                BinaryExpression(leftExpression: lhs, rightExpression: rhs, operation: op)
            )
        }

        return lhs
    }

    mutating func parseUnaryExpression() throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        let parseDepthLevel = try parseDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
        defer { parseDepth.leave(parseDepthLevel) }

        if canBeginUnaryExpression(current) {
            let op = toUnaryOperation(current)
            consume()
            let expression = try parseUnaryExpression()
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                UnaryExpression(expression: expression, operation: op)
            )
        }

        return try parseSingularExpression()
    }

    mutating func parseSingularExpression() throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        let base = try parsePrimaryExpression()
        return try parsePostfixExpression(base, startOfElementPosition)
    }

    mutating func parsePostfixExpression(_ base: ExpressionID, _ startPosition: SourcePosition) throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition

        var expr = base
        while true {
            switch current.type {
            case .bracketLeft:
                consume()
                let arrayIndex = try parseExpression()
                try consumeType(.bracketRight, startOfElementPosition)
                let span = SourceSpan(startPosition, currentPosition)
                expr = shaderModule.construct(span: span, IndexAccessExpression(base: expr, index: arrayIndex))

            case .period:
                consume()
                let fieldName = try parseIdentifier()
                let span = SourceSpan(startPosition, currentPosition)
                expr = shaderModule.constructFieldAccessExpression(span: span, base: expr, fieldName: fieldName)

            default: // lint-exempt(L-ENUM-1): every other token type ends the postfix expression, as the C++ default
                return expr
            }
        }
    }

    // https://gpuweb.github.io/gpuweb/wgsl/#syntax-primary_expression
    // primary_expression:
    //   | ident
    //   | callable argument_expression_list
    //   | const_literal
    //   | paren_expression
    //   | bitcast less_than type_decl greater_than paren_expression
    @_spi(Testing)
    public mutating func parsePrimaryExpression() throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition

        switch current.type {
        // paren_expression
        case .parenLeft:
            consume()
            let expr = try parseExpression()
            try consumeType(.parenRight, startOfElementPosition)
            return expr
        case .identifier:
            let ident = try parseIdentifier()
            // FIXME: <rdar://150365759> remove the special case for array
            if equal(ident, "array") {
                let arrayType = try parseArrayType()
                let arguments = try parseArgumentExpressionList()
                return shaderModule.construct(
                    span: SourceSpan(startOfElementPosition, currentPosition),
                    CallExpression(target: arrayType, arguments: shaderModule.makeList(arguments))
                )
            }
            if current.type == .templateArgsLeft || current.type == .parenLeft {
                let type = try parseTypeNameAfterIdentifier(ident, startOfElementPosition)
                let arguments = try parseArgumentExpressionList()
                return shaderModule.construct(
                    span: SourceSpan(startOfElementPosition, currentPosition),
                    CallExpression(target: type, arguments: shaderModule.makeList(arguments))
                )
            }
            return shaderModule.constructIdentifierExpression(span: SourceSpan(startOfElementPosition, currentPosition), identifier: ident)

        // const_literal
        case .keywordTrue:
            consume()
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), BoolLiteral(value: true))
        case .keywordFalse:
            consume()
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), BoolLiteral(value: false))
        case .integerLiteral:
            let lit = try consumeType(.integerLiteral, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                AbstractIntegerLiteral(value: lit.integerValue)
            )
        case .integerLiteralSigned:
            let lit = try consumeType(.integerLiteralSigned, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                Signed32Literal(value: Int32(truncatingIfNeeded: lit.integerValue))
            )
        case .integerLiteralUnsigned:
            let lit = try consumeType(.integerLiteralUnsigned, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                Unsigned32Literal(value: UInt32(truncatingIfNeeded: lit.integerValue))
            )
        case .abstractFloatLiteral:
            let lit = try consumeType(.abstractFloatLiteral, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                AbstractFloatLiteral(value: lit.floatValue)
            )
        case .floatLiteral:
            let lit = try consumeType(.floatLiteral, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                Float32Literal(value: Float(lit.floatValue))
            )
        case .halfLiteral:
            if !shaderModule.enabledExtensions.contains(.f16) {
                throw fail("f16 literal used without f16 extension enabled", startOfElementPosition)
            }
            let lit = try consumeType(.halfLiteral, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                Float16Literal(value: Half(lit.floatValue))
            )
        // TODO: bitcast expression

        default: // lint-exempt(L-ENUM-1): every other token type is an error, as the C++ default
            break
        }

        throw fail("Expected one of '(', a literal, or an identifier", startOfElementPosition)
    }

    mutating func parseExpression() throws(CompilationMessage) -> ExpressionID {
        let unary = try parseUnaryExpression()
        if canContinueBitwiseExpression(current) {
            return try parseBitwiseExpressionPostUnary(unary)
        }

        var relational = try parseRelationalExpressionPostUnary(unary)
        if canContinueShortCircuitAndExpression(current) {
            relational = try parseShortCircuitExpression(relational, .andAnd, .shortCircuitAnd)
        } else if canContinueShortCircuitOrExpression(current) {
            relational = try parseShortCircuitExpression(relational, .orOr, .shortCircuitOr)
        }

        return relational
    }

    mutating func parseLHSExpression() throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition
        let parseDepthLevel = try parseDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
        defer { parseDepth.leave(parseDepthLevel) }

        if current.type == .and || current.type == .star {
            let op = toUnaryOperation(current)
            consume()
            let expression = try parseLHSExpression()
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                UnaryExpression(expression: expression, operation: op)
            )
        }

        let base = try parseCoreLHSExpression()
        return try parsePostfixExpression(base, startOfElementPosition)
    }

    mutating func parseCoreLHSExpression() throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition

        switch current.type {
        case .parenLeft:
            consume()
            let expr = try parseLHSExpression()
            try consumeType(.parenRight, startOfElementPosition)
            return expr
        case .identifier:
            let ident = try parseIdentifier()
            return shaderModule.constructIdentifierExpression(span: SourceSpan(startOfElementPosition, currentPosition), identifier: ident)
        default: // lint-exempt(L-ENUM-1): every other token type is an error, as the C++ default
            break
        }

        throw fail("Tried to parse the left-hand side of an assignment and failed", startOfElementPosition)
    }

    mutating func parseArgumentExpressionList() throws(CompilationMessage) -> [ExpressionID] {
        let startOfElementPosition = currentPosition
        let parseDepthLevel = try parseDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
        defer { parseDepth.leave(parseDepthLevel) }
        try consumeType(.parenLeft, startOfElementPosition)

        var arguments: [ExpressionID] = []
        while current.type != .parenRight {
            let expr = try parseExpression()
            arguments.append(expr)
            if current.type != .parenRight {
                try consumeType(.comma, startOfElementPosition)
            }
        }

        try consumeType(.parenRight, startOfElementPosition)
        return arguments
    }
}
