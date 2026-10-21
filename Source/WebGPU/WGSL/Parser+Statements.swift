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
    mutating func parseStatement() throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition
        let parseDepthLevel = try parseDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
        defer { parseDepth.leave(parseDepthLevel) }

        switch current.type {
        case .keywordReturn:
            let returnStmt = try parseReturnStatement()
            try consumeType(.semicolon, startOfElementPosition)
            return returnStmt
        case .keywordConst, .keywordLet, .keywordVar:
            let variable = try parseVariable()
            try consumeType(.semicolon, startOfElementPosition)
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), VariableStatement(variable: variable))
        case .identifier:
            let statement = try parseCallOrVariableUpdatingStatement()
            try consumeType(.semicolon, startOfElementPosition)
            return statement
        case .parenLeft, .and, .star:
            let variableUpdatingStatement = try parseVariableUpdatingStatement()
            try consumeType(.semicolon, startOfElementPosition)
            return variableUpdatingStatement
        case .keywordBreak:
            consume()
            try consumeType(.semicolon, startOfElementPosition)
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), BreakStatement())
        case .keywordContinue:
            consume()
            try consumeType(.semicolon, startOfElementPosition)
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), ContinueStatement())
        case .keywordDiscard:
            consume()
            try consumeType(.semicolon, startOfElementPosition)
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), DiscardStatement())
        case .underbar:
            let phonyAssignment = try parsePhonyAssignmentStatement()
            try consumeType(.semicolon, startOfElementPosition)
            return phonyAssignment
        case .keywordConstAssert:
            let assert = try parseConstAssert()
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                ConstAssertStatement(assertion: assert)
            )
        default: // lint-exempt(L-ENUM-1): every other token type goes on to the attributed statements, as the C++ default
            break
        }

        let attributes = try parseAttributes()

        switch current.type {
        case .keywordIf:
            return try parseIfStatementWithAttributes(attributes, startOfElementPosition)
        case .keywordFor:
            return try parseForStatement(attributes)
        case .keywordLoop:
            return try parseLoopStatement(attributes)
        case .keywordSwitch:
            return try parseSwitchStatement(attributes)
        case .keywordWhile:
            return try parseWhileStatement(attributes)
        case .braceLeft:
            let compoundStmt = try parseCompoundStatement(attributes)
            return compoundStmt
        default: // lint-exempt(L-ENUM-1): every other token type is an error, as the C++ default
            throw fail("Not a valid statement", startOfElementPosition)
        }
    }

    mutating func parseCompoundStatement() throws(CompilationMessage) -> StatementID {
        let attributes = try parseAttributes()

        return try parseCompoundStatement(attributes)
    }

    mutating func parseCompoundStatement(_ attributes: [AttributeID]) throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        try consumeType(.braceLeft, startOfElementPosition)

        var statements: [StatementID] = []
        while current.type != .braceRight {
            if current.type == .semicolon {
                consume()
                continue
            }

            let stmt = try parseStatement()
            statements.append(stmt)
        }

        try consumeType(.braceRight, startOfElementPosition)

        return shaderModule.construct(
            span: SourceSpan(startOfElementPosition, currentPosition),
            CompoundStatement(attributes: shaderModule.makeList(attributes), statements: shaderModule.makeList(statements))
        )
    }

    mutating func parseIfStatement() throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        let attributes = try parseAttributes()

        return try parseIfStatementWithAttributes(attributes, startOfElementPosition)
    }

    mutating func parseIfStatementWithAttributes(
        _ attributes: [AttributeID],
        _ startOfElementPosition: SourcePosition
    ) throws(CompilationMessage) -> StatementID {
        try consumeType(.keywordIf, startOfElementPosition)
        let testExpr = try parseExpression()
        let thenStmt = try parseCompoundStatement()

        var maybeElseStmt: StatementID?
        if current.type == .keywordElse {
            consume()
            // The syntax following an 'else' keyword can be either an 'if'
            // statement or a brace-delimited compound statement.
            if current.type == .keywordIf {
                let parseDepthLevel = try parseDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
                defer { parseDepth.leave(parseDepthLevel) }
                let elseStmt = try parseIfStatementWithAttributes([], startOfElementPosition)
                maybeElseStmt = elseStmt
            } else {
                let elseStmt = try parseCompoundStatement()
                maybeElseStmt = elseStmt
            }
        }

        return shaderModule.construct(
            span: SourceSpan(startOfElementPosition, currentPosition),
            IfStatement(test: testExpr, trueBody: thenStmt, maybeFalseBody: maybeElseStmt, attributes: shaderModule.makeList(attributes))
        )
    }

    mutating func parseForStatement(_ attributes: [AttributeID]) throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordFor, startOfElementPosition)

        var maybeInitializer: StatementID?
        var maybeTest: ExpressionID?
        var maybeUpdate: StatementID?

        try consumeType(.parenLeft, startOfElementPosition)

        if current.type != .semicolon {
            switch current.type {
            case .keywordConst, .keywordLet, .keywordVar:
                let variable = try parseVariable()
                maybeInitializer = shaderModule.construct(
                    span: SourceSpan(startOfElementPosition, currentPosition),
                    VariableStatement(variable: variable)
                )
            case .identifier:
                let statement = try parseCallOrVariableUpdatingStatement()
                maybeInitializer = statement
            case .underbar:
                // A phony assignment is a variable_updating_statement, so it is allowed here.
                let phonyAssignment = try parsePhonyAssignmentStatement()
                maybeInitializer = phonyAssignment
            default: // lint-exempt(L-ENUM-1): every other token type is an error, as the C++ default
                throw fail("Invalid for-loop initialization clause", startOfElementPosition)
            }
        }
        try consumeType(.semicolon, startOfElementPosition)

        if current.type != .semicolon {
            let test = try parseExpression()
            maybeTest = test
        }
        try consumeType(.semicolon, startOfElementPosition)

        if current.type != .parenRight {
            if current.type == .underbar {
                let phonyAssignment = try parsePhonyAssignmentStatement()
                maybeUpdate = phonyAssignment
            } else {
                guard current.type == .identifier else {
                    throw fail("Invalid for-loop update clause", startOfElementPosition)
                }

                let statement = try parseCallOrVariableUpdatingStatement()
                maybeUpdate = statement
            }
        }
        try consumeType(.parenRight, startOfElementPosition)

        let body = try parseCompoundStatement()

        return shaderModule.construct(
            span: SourceSpan(startOfElementPosition, currentPosition),
            ForStatement(
                attributes: shaderModule.makeList(attributes),
                maybeInitializer: maybeInitializer,
                maybeTest: maybeTest,
                maybeUpdate: maybeUpdate,
                body: body
            )
        )
    }

    mutating func parseLoopStatement(_ attributes: [AttributeID]) throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordLoop, startOfElementPosition)
        let bodyAttributes = try parseAttributes()

        try consumeType(.braceLeft, startOfElementPosition)
        var bodyStatements: [StatementID] = []
        var maybeContinuing: Continuing?

        while current.type != .braceRight {
            if current.type == .semicolon {
                consume()
                continue
            }

            if current.type != .keywordContinuing {
                let statement = try parseStatement()
                bodyStatements.append(statement)
                continue
            }

            try consumeType(.keywordContinuing, startOfElementPosition)

            var continuingStatements: [StatementID] = []
            var breakIf: ExpressionID?
            let continuingAttributes = try parseAttributes()

            try consumeType(.braceLeft, startOfElementPosition)
            while current.type != .braceRight {
                if current.type == .semicolon {
                    consume()
                    continue
                }

                if current.type != .keywordBreak {
                    let statement = try parseStatement()
                    continuingStatements.append(statement)
                    continue
                }

                try consumeType(.keywordBreak, startOfElementPosition)
                if current.type != .keywordIf {
                    try consumeType(.semicolon, startOfElementPosition)
                    continuingStatements.append(
                        shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), BreakStatement())
                    )
                    continue
                }

                try consumeType(.keywordIf, startOfElementPosition)
                let expression = try parseExpression()
                try consumeType(.semicolon, startOfElementPosition)

                breakIf = expression
                break
            }
            try consumeType(.braceRight, startOfElementPosition)

            maybeContinuing = Continuing(
                body: shaderModule.makeList(continuingStatements),
                attributes: shaderModule.makeList(continuingAttributes),
                breakIf: breakIf
            )

            // https://www.w3.org/TR/WGSL/#loop-statement
            // The continuing block closes the loop body, so anything following it is a parse error.
            break
        }
        try consumeType(.braceRight, startOfElementPosition)

        return shaderModule.construct(
            span: SourceSpan(startOfElementPosition, currentPosition),
            LoopStatement(
                attributes: shaderModule.makeList(attributes),
                bodyAttributes: shaderModule.makeList(bodyAttributes),
                body: shaderModule.makeList(bodyStatements),
                continuing: maybeContinuing
            )
        )
    }

    mutating func parseSwitchStatement(_ attributes: [AttributeID]) throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordSwitch, startOfElementPosition)

        let value = try parseExpression()

        let bodyAttributes = try parseAttributes()

        try consumeType(.braceLeft, startOfElementPosition)

        var clauses: [SwitchClauseID] = []
        var defaultClause: SwitchClauseID?
        var selectorCount: UInt32 = 0
        while current.type != .braceRight {
            var selectors: [ExpressionID] = []
            var hasDefault = false
            if current.type == .keywordCase {
                consume()
                repeat {
                    if current.type == .keywordDefault {
                        consume()
                        hasDefault = true
                    } else {
                        selectorCount &+= 1
                        let selector = try parseExpression()
                        selectors.append(selector)
                    }

                    if current.type != .comma {
                        break
                    }
                    try consumeType(.comma, startOfElementPosition)
                } while current.type != .braceLeft && current.type != .colon
            } else if current.type == .keywordDefault {
                consume()
                hasDefault = true
            } else {
                throw fail("Expected either a `case` or `default` switch clause", startOfElementPosition)
            }

            if hasDefault && defaultClause != nil {
                throw fail("Switch statement contains more than one default clause", startOfElementPosition)
            }

            if current.type == .colon {
                consume()
            }
            let body = try parseCompoundStatement()
            assert(hasDefault || !selectors.isEmpty)
            if hasDefault {
                defaultClause = shaderModule.constructSwitchClause(selectors: shaderModule.makeList(selectors), body: body)
            } else {
                clauses.append(shaderModule.constructSwitchClause(selectors: shaderModule.makeList(selectors), body: body))
            }

            // https://www.w3.org/TR/WGSL/#limits
            let maximumNumberOfCaseSelectors: UInt32 = 1023
            if selectorCount > maximumNumberOfCaseSelectors {
                throw fail(
                    "switch statement cannot have more than \(maximumNumberOfCaseSelectors) case selector values",
                    startOfElementPosition
                )
            }
        }
        try consumeType(.braceRight, startOfElementPosition)

        guard let defaultClause else {
            throw fail("Switch statement must have exactly one default clause, but it has none", startOfElementPosition)
        }

        return shaderModule.construct(
            span: SourceSpan(startOfElementPosition, currentPosition),
            SwitchStatement(
                attributes: shaderModule.makeList(attributes),
                value: value,
                bodyAttributes: shaderModule.makeList(bodyAttributes),
                clauses: shaderModule.makeList(clauses),
                defaultClause: defaultClause
            )
        )
    }

    mutating func parseWhileStatement(_ attributes: [AttributeID]) throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordWhile, startOfElementPosition)

        let test = try parseExpression()
        let body = try parseCompoundStatement()

        return shaderModule.construct(
            span: SourceSpan(startOfElementPosition, currentPosition),
            WhileStatement(attributes: shaderModule.makeList(attributes), test: test, body: body)
        )
    }

    mutating func parseReturnStatement() throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordReturn, startOfElementPosition)

        if current.type == .semicolon {
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), ReturnStatement(maybeExpression: nil))
        }

        let expr = try parseExpression()
        return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), ReturnStatement(maybeExpression: expr))
    }

    mutating func parseVariableUpdatingStatement() throws(CompilationMessage) -> StatementID {
        // https://www.w3.org/TR/WGSL/#recursive-descent-syntax-variable_updating_statement
        let lhs = try parseLHSExpression()
        return try parseVariableUpdatingStatement(lhs)
    }

    mutating func parseVariableUpdatingStatement(_ lhs: ExpressionID) throws(CompilationMessage) -> StatementID {
        let startOfElementPosition = currentPosition

        var operation: DecrementIncrementStatement.Operation?
        if current.type == .plusPlus {
            operation = .increment
        } else if current.type == .minusMinus {
            operation = .decrement
        }
        if let operation {
            consume()
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                DecrementIncrementStatement(expression: lhs, operation: operation)
            )
        }

        var maybeOp: BinaryOperation?
        if canContinueCompoundAssignmentStatement(current) {
            maybeOp = toBinaryOperation(current)
            consume()
        } else if current.type == .equal {
            consume()
        } else {
            throw fail("Expected one of `=`, `++`, or `--`", startOfElementPosition)
        }

        let rhs = try parseExpression()

        if let maybeOp {
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                CompoundAssignmentStatement(leftExpression: lhs, rightExpression: rhs, operation: maybeOp)
            )
        }

        return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), AssignmentStatement(lhs: lhs, rhs: rhs))
    }

    mutating func parseCallOrVariableUpdatingStatement() throws(CompilationMessage) -> StatementID {
        // A func_call_statement and a variable_updating_statement both start with an identifier, so
        // which one this is only becomes apparent once that identifier has been consumed. Neither
        // consumes a trailing `;`, since a for-loop's init and update clauses do not have one.
        let startOfElementPosition = currentPosition

        let ident = try parseIdentifier()

        if current.type == .templateArgsLeft || current.type == .parenLeft {
            let type = try parseTypeNameAfterIdentifier(ident, startOfElementPosition)
            let arguments = try parseArgumentExpressionList()
            let call = shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                CallExpression(target: type, arguments: shaderModule.makeList(arguments))
            )
            return shaderModule.constructCallStatement(span: SourceSpan(startOfElementPosition, currentPosition), call: call)
        }

        let identifierExpression = shaderModule.constructIdentifierExpression(
            span: SourceSpan(startOfElementPosition, currentPosition),
            identifier: ident
        )
        let lhs = try parsePostfixExpression(identifierExpression, startOfElementPosition)
        return try parseVariableUpdatingStatement(lhs)
    }

    mutating func parsePhonyAssignmentStatement() throws(CompilationMessage) -> StatementID {
        // https://www.w3.org/TR/WGSL/#recursive-descent-syntax-assignment_statement
        let startOfElementPosition = currentPosition

        try consumeType(.underbar, startOfElementPosition)
        try consumeType(.equal, startOfElementPosition)
        let rhs = try parseExpression()
        return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), PhonyAssignmentStatement(rhs: rhs))
    }
}
