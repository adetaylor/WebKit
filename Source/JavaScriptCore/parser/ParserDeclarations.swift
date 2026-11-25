//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
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

extension DeclarationType {
    var destructuringKind: DestructuringKind {
        switch self {
        case .var:
            return .variables
        case .let:
            return .let
        case .const:
            return .const
        case .using, .awaitUsing:
            preconditionFailure("not reached")
        }
    }

    var variableKindName: Swift.String {
        switch self {
        case .var:
            return "variable name"
        case .let, .const:
            return "lexical variable name"
        case .using, .awaitUsing:
            return "using variable name"
        }
    }

    var assignmentContext: JSC.AssignmentContext {
        switch self {
        case .const:
            return .ConstDeclarationStatement
        case .using:
            return .UsingDeclarationStatement
        case .awaitUsing:
            return .AwaitUsingDeclarationStatement
        default:
            return .DeclarationStatement
        }
    }

    var isUsing: Bool {
        self == .using || self == .awaitUsing
    }

    var isConstant: Bool {
        self == .const || isUsing
    }
}

extension DestructuringKind {
    var variableKindName: Swift.String {
        switch self {
        case .let, .const:
            return "lexical variable name"
        case .variables:
            return "variable name"
        case .parameters:
            return "parameter name"
        case .catchParameters:
            return "catch parameter name"
        case .expressions:
            return "expression name"
        }
    }

    var isLexical: Bool {
        self == .let || self == .const
    }
}

extension Parser {
    mutating func parseVariableDeclaration<B: TreeBuilder>(
        _ context: inout B,
        _ declarationType: DeclarationType,
        _ exportType: ExportType = .notExported,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        let location = tokenLocation
        var output = VariableDeclarationListOutput<B>()
        let variableDecls = parseVariableDeclarationList(
            &context,
            &output,
            .var,
            declarationType,
            exportType,
            isLetKeywordConsumed: false,
            &facade
        )
        if hasError {
            return .null
        }
        if !autoSemiColon(&facade) {
            return fail("Expected ';' after variable declaration")
        }

        return context.createDeclarationStatement(&facade, location, variableDecls)
    }

    mutating func parseVariableDeclarationList<B: TreeBuilder>(
        _ context: inout B,
        _ output: inout VariableDeclarationListOutput<B>,
        _ declarationListContext: VarDeclarationListContext,
        _ declarationType: DeclarationType,
        _ exportType: ExportType,
        isLetKeywordConsumed: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        var isLetKeywordConsumed = isLetKeywordConsumed
        var head = B.Expression.null
        var headLocation = JSC.JSTokenLocation()
        var tail = B.Expression.null
        var lastIdent = JSC.JSParseIdentifier()
        var lastIdentToken = Token()
        let assignmentContext = declarationType.assignmentContext
        let isUsingDeclaration = declarationType.isUsing
        repeat {
            output.lastPattern = .null
            lastIdent = JSC.JSParseIdentifier()
            var location = tokenLocation
            if isLetKeywordConsumed {
                location = lastTokenLocation
                isLetKeywordConsumed = false
            } else {
                next([], &facade)
            }
            if head.isNull && declarationType == .awaitUsing {
                assert(match(.identifier) && token.data.ident.matches(.usingIdentifier, &facade))
                next([], &facade)
            }
            if !head.isNull {
                // Move the location of subsequent declarations after the comma.
                location = tokenLocation
            }
            var node = B.Expression.null
            output.declarations += 1
            var hasInitializer = false

            if match(.privateName) {
                return fail("Cannot use a private name to declare a variable")
            }
            if isUsingDeclaration {
                // 'using' declarations cannot have a destructuring pattern.
                if match(.openBrace) || match(.openBracket) {
                    return fail("'using' declarations cannot have a destructuring pattern")
                }
                if !matchSpecIdentifier(&facade) {
                    return fail("Expected an identifier name in 'using' declaration")
                }
            }
            if matchSpecIdentifier(&facade) {
                if scopes[topScope].isStaticBlock && isArgumentsIdentifier(&facade) {
                    return semanticFail("Cannot use 'arguments' as an identifier in static block")
                }
                if isPossiblyEscapedLet(token, &facade)
                    && (declarationType == .let || declarationType == .const || isUsingDeclaration)
                {
                    return fail("Cannot use 'let' as an identifier name for a LexicalDeclaration")
                }
                if isDisallowedIdentifierAwait(token, &facade) {
                    return semanticFail(
                        .text(
                            "Cannot use 'await' as a \(declarationType.variableKindName) \(disallowedIdentifierAwaitReason())"
                        )
                    )
                }
                let varStart = tokenStartPosition
                let varStartLocation = tokenLocation
                output.identStart = varStart
                let name = token.data.ident
                lastIdent = name
                lastIdentToken = token
                next([], &facade)
                hasInitializer = match(.equal)
                let declarationResult = declareVariable(name, declarationType, .notImported, &facade)
                if !declarationResult.isEmpty {
                    if declarationResult.contains(.invalidStrictMode) && strictMode {
                        return semanticFail(
                            ErrorMessage(.text("Cannot declare a variable named "), .identifier(name), .text(" in strict mode"))
                        )
                    }
                    if declarationResult.contains(.invalidDuplicateDeclaration) {
                        if declarationType == .let {
                            return semanticFail(
                                ErrorMessage(.text("Cannot declare a let variable twice: '"), .identifier(name), .text("'"))
                            )
                        }
                        if declarationType == .const {
                            return semanticFail(
                                ErrorMessage(.text("Cannot declare a const variable twice: '"), .identifier(name), .text("'"))
                            )
                        }
                        if isUsingDeclaration {
                            return semanticFail(
                                ErrorMessage(.text("Cannot declare a using variable twice: '"), .identifier(name), .text("'"))
                            )
                        }
                        assert(declarationType == .var)
                        return semanticFail(
                            ErrorMessage(
                                .text("Cannot declare a var variable that shadows a let/const/class variable: '"),
                                .identifier(name),
                                .text("'")
                            )
                        )
                    }
                }
                if exportType == .exported {
                    if !exportName(name, &facade) {
                        return semanticFail(ErrorMessage(.text("Cannot export a duplicate name '"), .identifier(name), .text("'")))
                    }
                    facade.moduleExportBinding(name)
                }

                if hasInitializer {
                    let varDivot = JSC.JSTextPosition(offset: Int(tokenStartPosition.offset) + 1)
                    output.initStart = tokenStartPosition
                    next(B.dontBuildStrings, &facade) // consume '='
                    if hasError {
                        return .null
                    }
                    let initializer = parseAssignmentExpression(&context, &facade)
                    output.initEnd = lastTokenEndPosition
                    output.lastInitializer = initializer
                    if initializer.isNull {
                        return fail(
                            ErrorMessage(.text("Expected expression as the intializer for the variable '"), .identifier(name), .text("'"))
                        )
                    }

                    node = context.createAssignResolve(
                        &facade,
                        location,
                        name,
                        initializer,
                        varStart,
                        varDivot,
                        lastTokenEndPosition,
                        assignmentContext
                    )
                } else {
                    if isUsingDeclaration {
                        guard declarationListContext == .forLoop else {
                            return fail("'using' declaration requires an initializer")
                        }
                        output.forLoopConstDoesNotHaveInitializer = true
                    }
                    if declarationListContext == .forLoop && declarationType == .const {
                        output.forLoopConstDoesNotHaveInitializer = true
                    }
                    if declarationListContext != .forLoop && declarationType == .const {
                        return fail(
                            ErrorMessage(.text("const declared variable '"), .identifier(name), .text("' must have an initializer"))
                        )
                    }
                    if declarationType == .var {
                        node = context.createEmptyVarExpression(&facade, varStartLocation, name)
                    } else {
                        node = context.createEmptyLetExpression(&facade, varStartLocation, name)
                    }
                }
            } else {
                assert(!isUsingDeclaration) // Already rejected above.
                var pattern = B.DestructuringPattern.null
                do {
                    let savedAllowsIn = allowsIn
                    allowsIn = true
                    defer { allowsIn = savedAllowsIn }
                    var duplicateIdentifier = JSC.JSParseIdentifier()
                    var hasDestructuringPattern = false
                    pattern = parseDestructuringPattern(
                        &context,
                        declarationType.destructuringKind,
                        exportType,
                        &duplicateIdentifier,
                        &hasDestructuringPattern,
                        assignmentContext,
                        depth: 0,
                        &facade
                    )
                }
                if pattern.isNull {
                    return fail("Cannot parse this destructuring pattern")
                }
                hasInitializer = match(.equal)
                if !hasInitializer
                    && (declarationListContext == .var
                        || (!match(.inKeyword) && !matchContextualKeyword(.of, &facade)))
                {
                    return fail("Expected an initializer in destructuring variable declaration")
                }
                output.lastPattern = pattern
                if hasInitializer {
                    next(B.dontBuildStrings, &facade) // consume '='
                    let rhs = parseAssignmentExpression(&context, &facade)
                    if hasError {
                        return .null
                    }
                    assert(!rhs.isNull)
                    node = context.createDestructuringAssignment(&facade, location, pattern, rhs)
                    output.lastInitializer = rhs
                }
            }

            if !node.isNull {
                if head.isNull {
                    head = node
                    headLocation = location
                } else {
                    if tail.isNull {
                        recordPauseLocation(context.breakpointLocation(&facade, head), &facade)
                        tail = context.createCommaExpr(&facade, headLocation, head)
                        head = tail
                    }
                    recordPauseLocation(context.breakpointLocation(&facade, node), &facade)
                    tail = context.appendToCommaExpr(&facade, location, tail, node)
                }
            }
        } while match(.comma)
        if !lastIdent.isNull {
            output.lastPattern = context.createBindingLocation(
                &facade,
                lastIdentToken.location,
                lastIdent,
                lastIdentToken.startPosition,
                lastIdentToken.endPosition,
                assignmentContext
            )
        }

        return head
    }

    // MARK: Parameters and patterns

    mutating func declareRestOrNormalParameter(
        _ name: JSC.JSParseIdentifier,
        _ duplicateIdentifier: inout JSC.JSParseIdentifier,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        let declarationResult = declareParameter(name, &facade)
        if declarationResult.contains(.invalidStrictMode) && strictMode {
            if name.isEvalOrArguments(&facade) {
                logSemanticError(
                    ErrorMessage(.text("Cannot destructure to a parameter name '"), .identifier(name), .text("' in strict mode"))
                )
                return false
            }
            let lastFunctionName = parserState.lastFunctionName
            if !lastFunctionName.isNull && facade.sameIdentifier(name, lastFunctionName) {
                logSemanticError(
                    ErrorMessage(
                        .text("Cannot declare a parameter named '"),
                        .identifier(name),
                        .text("' as it shadows the name of a strict mode function")
                    )
                )
                return false
            }
            if failDueToKeyword(token, "parameter name", &facade) {
                return false
            }
            if !lexer.isReparsingFunction && hasDeclaredParameter(name, &facade) {
                logSemanticError(
                    ErrorMessage(
                        .text("Cannot declare a parameter named '"),
                        .identifier(name),
                        .text("' in strict mode as it has already been declared")
                    )
                )
                return false
            }
            logSemanticError(ErrorMessage(.text("Cannot declare a parameter named '"), .identifier(name), .text("' in strict mode")))
            return false
        }
        if declarationResult.contains(.invalidDuplicateDeclaration) {
            // It's not always an error to define a duplicate parameter.
            // It's only an error when there are default parameter values or destructuring parameters.
            // We note this value now so we can check it later.
            duplicateIdentifier = name
        }

        return true
    }

    mutating func createBindingPattern<B: TreeBuilder>(
        _ context: inout B,
        _ kind: DestructuringKind,
        _ exportType: ExportType,
        _ name: JSC.JSParseIdentifier,
        _ token: Token,
        _ bindingContext: JSC.AssignmentContext,
        _ duplicateIdentifier: inout JSC.JSParseIdentifier,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        assert(!name.isNull)

        switch kind {
        case .variables:
            let declarationResult = declareVariable(name, .var, .notImported, &facade)
            if declarationResult.contains(.invalidStrictMode) && strictMode {
                return semanticFail(ErrorMessage(.text("Cannot declare a variable named '"), .identifier(name), .text("' in strict mode")))
            }
            if declarationResult.contains(.invalidDuplicateDeclaration) {
                return semanticFail(
                    ErrorMessage(
                        .text("Cannot declare a var variable that shadows a let/const/class variable: '"),
                        .identifier(name),
                        .text("'")
                    )
                )
            }

        case .let, .const, .catchParameters:
            let declarationResult = declareVariable(
                name,
                kind == .const ? .const : .let,
                .notImported,
                &facade
            )
            if !declarationResult.isEmpty {
                if declarationResult.contains(.invalidStrictMode) && strictMode {
                    return semanticFail(
                        ErrorMessage(.text("Cannot destructure to a variable named '"), .identifier(name), .text("' in strict mode"))
                    )
                }
                if declarationResult.contains(.invalidDuplicateDeclaration) {
                    return fail(ErrorMessage(.text("Cannot declare a lexical variable twice: '"), .identifier(name), .text("'")))
                }
            }

        case .parameters:
            _ = declareRestOrNormalParameter(name, &duplicateIdentifier, &facade)
            if hasError {
                return .null
            }

        case .expressions:
            break
        }

        if exportType == .exported {
            if !exportName(name, &facade) {
                return semanticFail(ErrorMessage(.text("Cannot export a duplicate name '"), .identifier(name), .text("'")))
            }
            facade.moduleExportBinding(name)
        }
        return context.createBindingLocation(&facade, token.location, name, token.startPosition, token.endPosition, bindingContext)
    }

    @inline(never)
    mutating func createAssignmentElement<B: TreeBuilder>(
        _ context: inout B,
        _ assignmentTarget: B.Expression,
        _ startPosition: JSC.JSTextPosition,
        _ endPosition: JSC.JSTextPosition,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        context.createAssignmentElement(&facade, assignmentTarget, startPosition, endPosition)
    }

    mutating func tryParseDestructuringPatternExpression<B: TreeBuilder>(
        _ context: inout B,
        _ bindingContext: JSC.AssignmentContext,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        var duplicateIdentifier = JSC.JSParseIdentifier()
        var hasDestructuringPattern = false
        return parseDestructuringPattern(
            &context,
            .expressions,
            .notExported,
            &duplicateIdentifier,
            &hasDestructuringPattern,
            bindingContext,
            depth: 0,
            &facade
        )
    }

    mutating func parseBindingOrAssignmentElement<B: TreeBuilder>(
        _ context: inout B,
        _ kind: DestructuringKind,
        _ exportType: ExportType,
        _ duplicateIdentifier: inout JSC.JSParseIdentifier,
        _ hasDestructuringPattern: inout Bool,
        _ bindingContext: JSC.AssignmentContext,
        depth: Int,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        if kind == .expressions {
            return parseAssignmentElement(
                &context,
                kind,
                exportType,
                &duplicateIdentifier,
                &hasDestructuringPattern,
                bindingContext,
                depth: depth,
                &facade
            )
        }
        return parseDestructuringPattern(
            &context,
            kind,
            exportType,
            &duplicateIdentifier,
            &hasDestructuringPattern,
            bindingContext,
            depth: depth,
            &facade
        )
    }

    mutating func parseObjectRestAssignmentElement<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        let startPosition = tokenStartPosition
        let element = parseMemberExpression(&context, &facade)

        if element.isNull || !context.isAssignmentLocation(&facade, element) {
            return semanticFail("Invalid destructuring assignment target")
        }
        let lastIdentifier = parserState.lastIdentifier
        if strictMode && !lastIdentifier.isNull && context.isResolve(&facade, element) {
            if lastIdentifier.isEvalOrArguments(&facade) {
                return fail(ErrorMessage(.text("Cannot modify '"), .identifier(lastIdentifier), .text("' in strict mode")))
            }
        }

        return createAssignmentElement(&context, element, startPosition, lastTokenEndPosition, &facade)
    }

    mutating func parseAssignmentElement<B: TreeBuilder>(
        _ context: inout B,
        _ kind: DestructuringKind,
        _ exportType: ExportType,
        _ duplicateIdentifier: inout JSC.JSParseIdentifier,
        _ hasDestructuringPattern: inout Bool,
        _ bindingContext: JSC.AssignmentContext,
        depth: Int,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        var assignmentTarget = B.DestructuringPattern.null

        if match(.openBrace) || match(.openBracket) {
            let savePoint = createSavePoint(&context, &facade)
            assignmentTarget = parseDestructuringPattern(
                &context,
                kind,
                exportType,
                &duplicateIdentifier,
                &hasDestructuringPattern,
                bindingContext,
                depth: depth,
                &facade
            )
            if !assignmentTarget.isNull && !match(.dot) && !match(.openBracket) && !match(.openParen) && !match(.backQuote) {
                return assignmentTarget
            }
            restoreSavePoint(&context, savePoint, &facade)
        }

        let startPosition = tokenStartPosition
        let element = parseMemberExpression(&context, &facade)

        if element.isNull || !context.isAssignmentLocation(&facade, element) {
            return semanticFail("Invalid destructuring assignment target")
        }

        let lastIdentifier = parserState.lastIdentifier
        if strictMode && !lastIdentifier.isNull && context.isResolve(&facade, element) {
            if lastIdentifier.isEvalOrArguments(&facade) && strictMode {
                return semanticFail(ErrorMessage(.text("Cannot modify '"), .identifier(lastIdentifier), .text("' in strict mode")))
            }
        }

        return createAssignmentElement(&context, element, startPosition, lastTokenEndPosition, &facade)
    }

    mutating func parseObjectRestElement<B: TreeBuilder>(
        _ context: inout B,
        _ kind: DestructuringKind,
        _ exportType: ExportType,
        _ duplicateIdentifier: inout JSC.JSParseIdentifier,
        _ bindingContext: JSC.AssignmentContext,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        assert(kind != .expressions)
        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }

        if !matchSpecIdentifier(&facade) {
            if failDueToKeyword(token, kind.variableKindName, &facade) {
                return .null
            }
            return fail("Expected a binding element")
        }
        if match(.letKeyword) && kind.isLexical {
            return fail("Cannot use 'let' as an identifier name for a LexicalDeclaration")
        }
        if isDisallowedIdentifierAwait(token, &facade) {
            return semanticFail(
                .text("Cannot use 'await' as a \(kind.variableKindName) \(disallowedIdentifierAwaitReason())")
            )
        }
        let pattern = createBindingPattern(
            &context,
            kind,
            exportType,
            token.data.ident,
            token,
            bindingContext,
            &duplicateIdentifier,
            &facade
        )
        next([], &facade)
        return pattern
    }

    mutating func parseObjectRestBindingOrAssignmentElement<B: TreeBuilder>(
        _ context: inout B,
        _ kind: DestructuringKind,
        _ exportType: ExportType,
        _ duplicateIdentifier: inout JSC.JSParseIdentifier,
        _ bindingContext: JSC.AssignmentContext,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        if kind == .expressions {
            return parseObjectRestAssignmentElement(&context, &facade)
        }
        return parseObjectRestElement(&context, kind, exportType, &duplicateIdentifier, bindingContext, &facade)
    }

    mutating func parseDestructuringPattern<B: TreeBuilder>(
        _ context: inout B,
        _ kind: DestructuringKind,
        _ exportType: ExportType,
        _ duplicateIdentifier: inout JSC.JSParseIdentifier,
        _ hasDestructuringPattern: inout Bool,
        _ bindingContext: JSC.AssignmentContext,
        depth: Int,
        _ facade: inout JSC.JSParseFacade
    ) -> B.DestructuringPattern {
        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }
        parserState.assignmentCount &+= 1
        let savedNonLHSCount = parserState.nonLHSCount
        defer { parserState.nonLHSCount = savedNonLHSCount }
        var pattern = B.DestructuringPattern.null
        switch token.type {
        case .openBracket:
            let divotStart = tokenStartPosition
            let arrayPattern = context.createArrayPattern(&facade, token.location)
            next([], &facade)

            hasDestructuringPattern = true

            var restElementWasFound = false

            repeat {
                while match(.comma) {
                    context.appendArrayPatternSkipEntry(&facade, arrayPattern, token.location)
                    next([], &facade)
                }
                if hasError {
                    return .null
                }

                if match(.closeBracket) {
                    break
                }

                if match(.dotDotDot) {
                    let location = token.location
                    next([], &facade)
                    let innerPattern = parseBindingOrAssignmentElement(
                        &context,
                        kind,
                        exportType,
                        &duplicateIdentifier,
                        &hasDestructuringPattern,
                        bindingContext,
                        depth: depth + 1,
                        &facade
                    )
                    if kind == .expressions && innerPattern.isNull {
                        return .null
                    }
                    if innerPattern.isNull {
                        return fail("Cannot parse this destructuring pattern")
                    }
                    context.appendArrayPatternRestEntry(&facade, arrayPattern, location, innerPattern)
                    restElementWasFound = true
                    break
                }

                let location = token.location
                let innerPattern = parseBindingOrAssignmentElement(
                    &context,
                    kind,
                    exportType,
                    &duplicateIdentifier,
                    &hasDestructuringPattern,
                    bindingContext,
                    depth: depth + 1,
                    &facade
                )
                if kind == .expressions && innerPattern.isNull {
                    return .null
                }
                if innerPattern.isNull {
                    return fail("Cannot parse this destructuring pattern")
                }
                let defaultValue = parseDefaultValueForDestructuringPattern(&context, &facade)
                if hasError {
                    return .null
                }
                context.appendArrayPatternEntry(&facade, arrayPattern, location, innerPattern, defaultValue)
            } while consume(.comma, [], &facade)

            if !consumeOrFail(
                .closeBracket,
                restElementWasFound
                    ? "Expected a closing ']' following a rest element destructuring pattern"
                    : "Expected either a closing ']' or a ',' following an element destructuring pattern",
                &facade
            ) {
                return .null
            }
            context.finishArrayPattern(&facade, arrayPattern, divotStart, divotStart, lastTokenEndPosition)
            pattern = arrayPattern

        case .openBrace:
            let divotStart = tokenStartPosition
            let objectPattern = context.createObjectPattern(&facade, token.location)
            next([], &facade)

            hasDestructuringPattern = true

            var restElementWasFound = false

            repeat {
                var wasString = false

                if match(.closeBrace) {
                    break
                }

                if match(.dotDotDot) {
                    let location = token.location
                    next([], &facade)
                    let innerPattern = parseObjectRestBindingOrAssignmentElement(
                        &context,
                        kind,
                        exportType,
                        &duplicateIdentifier,
                        bindingContext,
                        &facade
                    )
                    if hasError {
                        return .null
                    }
                    if innerPattern.isNull {
                        return .null
                    }
                    context.appendObjectPatternRestEntry(&facade, objectPattern, location, innerPattern)
                    restElementWasFound = true
                    context.setContainsObjectRestElement(&facade, objectPattern, restElementWasFound)
                    break
                }

                var propertyName = JSC.JSParseIdentifier()
                var propertyExpression = B.Expression.null
                var innerPattern = B.DestructuringPattern.null
                let location = token.location
                let escapedKeyword = match(.escapedKeyword)
                if escapedKeyword || matchSpecIdentifier(&facade) {
                    let letMatched = match(.letKeyword)
                    propertyName = token.data.ident
                    let identifierToken = token
                    next([], &facade)
                    if consume(.colon, [], &facade) {
                        innerPattern = parseBindingOrAssignmentElement(
                            &context,
                            kind,
                            exportType,
                            &duplicateIdentifier,
                            &hasDestructuringPattern,
                            bindingContext,
                            depth: depth + 1,
                            &facade
                        )
                    } else {
                        if letMatched && kind.isLexical {
                            return semanticFail("Cannot use the keyword 'let' as a lexical variable name")
                        }
                        if escapedKeyword {
                            return semanticFail(
                                ErrorMessage(
                                    .text("Cannot use abbreviated destructuring syntax for keyword '"),
                                    .identifier(propertyName),
                                    .text("'")
                                )
                            )
                        }
                        if isDisallowedIdentifierAwait(identifierToken, &facade) {
                            return semanticFail(
                                .text(
                                    "Cannot use 'await' as a \(kind.variableKindName) \(disallowedIdentifierAwaitReason())"
                                )
                            )
                        }
                        if kind == .expressions {
                            let isEvalOrArguments = propertyName.isEvalOrArguments(&facade)
                            if isEvalOrArguments && strictMode {
                                return semanticFail(
                                    ErrorMessage(.text("Cannot modify '"), .identifier(propertyName), .text("' in strict mode"))
                                )
                            }

                            if match(.equal) {
                                let isEval = propertyName.matches(.eval, &facade)
                                scopes[topScope].useVariable(propertyName, isEval: isEval, &facade)
                            }
                        }
                        innerPattern = createBindingPattern(
                            &context,
                            kind,
                            exportType,
                            propertyName,
                            identifierToken,
                            bindingContext,
                            &duplicateIdentifier,
                            &facade
                        )
                    }
                } else {
                    let tokenType = token.type
                    switch token.type {
                    case .double, .integer:
                        propertyName = facade.makeNumericIdentifier(token.data.doubleValue)
                    case .string:
                        propertyName = token.data.ident
                        wasString = true
                    case .bigInt:
                        propertyName = facade.makeBigIntDecimalIdentifier(token.data.bigIntString, token.data.radix)
                        if propertyName.isNull {
                            return fail("Cannot parse big int property name")
                        }
                    case .openBracket:
                        next([], &facade)
                        propertyExpression = parseAssignmentExpression(&context, &facade)
                        if propertyExpression.isNull {
                            return fail("Cannot parse computed property name")
                        }
                        if !match(.closeBracket) {
                            return fail("Expected ']' to end end a computed property name")
                        }
                    default:
                        if token.type != .reserved && token.type != .reservedIfStrict && !token.type.isKeyword {
                            if kind == .expressions {
                                return .null
                            }
                            return fail("Expected a property name")
                        }
                        propertyName = token.data.ident
                    }
                    next([], &facade)
                    if !consume(.colon, [], &facade) {
                        if kind == .expressions {
                            return .null
                        }
                        if tokenType == .reserved {
                            return semanticFail(
                                ErrorMessage(
                                    .text("Cannot use abbreviated destructuring syntax for reserved name '"),
                                    .identifier(propertyName),
                                    .text("'")
                                )
                            )
                        }
                        if tokenType == .reservedIfStrict {
                            return semanticFail(
                                ErrorMessage(
                                    .text("Cannot use abbreviated destructuring syntax for reserved name '"),
                                    .identifier(propertyName),
                                    .text("' in strict mode")
                                )
                            )
                        }
                        if tokenType.isKeyword {
                            return semanticFail(
                                ErrorMessage(
                                    .text("Cannot use abbreviated destructuring syntax for keyword '"),
                                    .identifier(propertyName),
                                    .text("'")
                                )
                            )
                        }
                        return fail("Expected a ':' prior to a named destructuring property")
                    }
                    innerPattern = parseBindingOrAssignmentElement(
                        &context,
                        kind,
                        exportType,
                        &duplicateIdentifier,
                        &hasDestructuringPattern,
                        bindingContext,
                        depth: depth + 1,
                        &facade
                    )
                }
                if kind == .expressions && innerPattern.isNull {
                    return .null
                }
                if innerPattern.isNull {
                    return fail("Cannot parse this destructuring pattern")
                }
                let defaultValue = parseDefaultValueForDestructuringPattern(&context, &facade)
                if hasError {
                    return .null
                }
                if !propertyExpression.isNull {
                    context.appendObjectPatternEntry(&facade, objectPattern, location, propertyExpression, innerPattern, defaultValue)
                    context.setContainsComputedProperty(&facade, objectPattern, true)
                } else {
                    assert(!propertyName.isNull)
                    context.appendObjectPatternEntry(&facade, objectPattern, location, wasString, propertyName, innerPattern, defaultValue)
                }
            } while consume(.comma, [], &facade)

            if kind == .expressions && !match(.closeBrace) {
                return .null
            }
            if !consumeOrFail(
                .closeBrace,
                restElementWasFound
                    ? "Expected a closing '}' following a rest element destructuring pattern"
                    : "Expected either a closing '}' or an ',' after a property destructuring pattern",
                &facade
            ) {
                return .null
            }
            context.finishObjectPattern(&facade, objectPattern, divotStart, divotStart, lastTokenEndPosition)
            pattern = objectPattern

        default:
            if !matchSpecIdentifier(&facade) {
                if kind == .expressions {
                    return .null
                }
                if failDueToKeyword(token, kind.variableKindName, &facade) {
                    return .null
                }
                if kind != .parameters && match(.privateName) {
                    return fail(.text("Cannot use a private name as a \(kind.variableKindName)"))
                }
                return fail("Expected a parameter pattern or a ')' in parameter list")
            }
            if match(.letKeyword) && kind.isLexical {
                return fail("Cannot use 'let' as an identifier name for a LexicalDeclaration")
            }
            if isDisallowedIdentifierAwait(token, &facade) {
                return semanticFail(
                    .text("Cannot use 'await' as a \(kind.variableKindName) \(disallowedIdentifierAwaitReason())")
                )
            }
            pattern = createBindingPattern(
                &context,
                kind,
                exportType,
                token.data.ident,
                token,
                bindingContext,
                &duplicateIdentifier,
                &facade
            )
            next([], &facade)
        }
        return pattern
    }

    mutating func parseDefaultValueForDestructuringPattern<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        if !match(.equal) {
            return .null
        }

        next(B.dontBuildStrings, &facade) // consume '='
        return parseAssignmentExpression(&context, &facade)
    }
}
