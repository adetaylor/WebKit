//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
//  Copyright (C) 2003-2023 Apple Inc. All rights reserved.
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

extension JSC.SourceParseMode {
    var functionKindArticle: Swift.String {
        switch self {
        case .GetterMode, .SetterMode, .NormalFunctionMode, .MethodMode, .GeneratorBodyMode, .GeneratorWrapperFunctionMode,
            .GeneratorWrapperMethodMode:
            return "a "
        case .ArrowFunctionMode, .AsyncFunctionMode, .AsyncFunctionBodyMode, .AsyncMethodMode, .AsyncArrowFunctionBodyMode,
            .AsyncArrowFunctionMode, .AsyncGeneratorWrapperFunctionMode, .AsyncGeneratorBodyMode, .AsyncGeneratorWrapperMethodMode:
            return "an "
        case .ProgramMode, .ModuleAnalyzeMode, .ModuleEvaluateMode, .ClassFieldInitializerMode, .ClassStaticBlockMode:
            preconditionFailure()
        @unknown default:
            preconditionFailure()
        }
    }

    var functionKindName: Swift.String {
        switch self {
        case .GetterMode: return "getter"
        case .SetterMode: return "setter"
        case .NormalFunctionMode: return "function"
        case .MethodMode: return "method"
        case .GeneratorWrapperFunctionMode, .GeneratorBodyMode: return "generator function"
        case .GeneratorWrapperMethodMode: return "generator method"
        case .ArrowFunctionMode: return "arrow function"
        case .AsyncFunctionMode, .AsyncFunctionBodyMode: return "async function"
        case .AsyncMethodMode: return "async method"
        case .AsyncArrowFunctionBodyMode, .AsyncArrowFunctionMode: return "async arrow function"
        case .AsyncGeneratorWrapperFunctionMode, .AsyncGeneratorBodyMode: return "async generator function"
        case .AsyncGeneratorWrapperMethodMode: return "async generator method"
        case .ProgramMode, .ModuleAnalyzeMode, .ModuleEvaluateMode, .ClassFieldInitializerMode, .ClassStaticBlockMode:
            preconditionFailure()
        @unknown default:
            preconditionFailure()
        }
    }

    var asyncFunctionBodyMode: JSC.SourceParseMode {
        switch self {
        case .AsyncGeneratorWrapperFunctionMode, .AsyncGeneratorWrapperMethodMode:
            return .AsyncGeneratorBodyMode
        case .AsyncArrowFunctionMode:
            return .AsyncArrowFunctionBodyMode
        default:
            return .AsyncFunctionBodyMode
        }
    }
}

extension Parser {
    mutating func parseFunctionDeclarationStatement<B: TreeBuilder>(
        _ context: inout B,
        _ parentAllowsFunctionDeclarationAsStatement: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        if strictMode {
            return semanticFail("Function declarations are only allowed inside blocks or switch statements in strict mode")
        }
        if !parentAllowsFunctionDeclarationAsStatement {
            return fail("Function declarations are only allowed inside block statements or at the top level of a program")
        }

        // Any function declaration that isn't in a block is a syntax error unless it's in an if/else statement, which
        // is treated as if it were inside a block statement: if (cond) function foo() { } is if (cond) { function foo() { } }.
        let blockScope = pushScope(&facade)
        var blockScopePopped = false
        defer {
            if !blockScopePopped {
                popScope(blockScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }
        withScope(blockScope) {
            $0.setIsLexicalScope()
            $0.preventVarDeclarations()
        }
        let location = tokenLocation

        let function = parseFunctionDeclaration(
            &context,
            .statement,
            exportType: .notExported,
            defaultContext: .standard,
            functionConstructorParametersEndPosition: nil,
            &facade
        )
        if hasError {
            return .null
        }
        if function.isNull {
            return fail("Expected valid function statement after 'function' keyword")
        }
        let sourceElements = context.createSourceElements(&facade)
        context.appendStatement(&facade, sourceElements, function)
        blockScopePopped = true
        let (lexicalEnvironment, functionDeclarations) = popScope(
            blockScope,
            shouldTrackClosedVariables: B.needsFreeVariableInfo,
            takeContainers: B.createsAST,
            &facade
        )
        return context.createBlockStatement(&facade, location, sourceElements, lexicalEnvironment, functionDeclarations)
    }

    /// "'name' is not a valid function name in strict mode": out of line, so a valid name builds no message.
    @inline(never)
    private mutating func failNotValidStrictFunctionName(_ name: JSC.JSParseIdentifier) -> Bool {
        semanticFail(ErrorMessage(.text("'"), .identifier(name), .text("' is not a valid function name in strict mode")))
    }

    private func adjustSuperBindingForBaseConstructor(
        _ constructorKind: JSC.ConstructorKind,
        _ superBinding: JSC.SuperBinding,
        _ parseMode: JSC.SourceParseMode,
        needsSuperBinding: Bool,
        usesEval: Bool,
        _ innerArrowFunctionFeatures: JSC.InnerArrowFunctionCodeFeatures
    ) -> JSC.SuperBinding {
        if superBinding == .NotNeeded {
            return .NotNeeded
        }
        if constructorKind == .None {
            if parseMode == .AsyncGeneratorWrapperMethodMode || parseMode == .GeneratorWrapperMethodMode || parseMode == .AsyncMethodMode {
                return .Needed
            }
        }
        if constructorKind == .None || constructorKind == .Base {
            let isSuperUsedInInnerArrowFunction = innerArrowFunctionFeatures & JSC.SuperPropertyInnerArrowFunctionFeature != 0
            return (needsSuperBinding || isSuperUsedInInnerArrowFunction || usesEval) ? .Needed : .NotNeeded
        }
        return .Needed
    }

    // MARK: Formal parameters

    mutating func parseFormalParameters<B: TreeBuilder>(
        _ context: inout B,
        _ list: B.FormalParameterList,
        isArrowFunction: Bool,
        isMethod: Bool,
        _ parameterCount: inout UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        var hasDefaultParameterValues = false
        var hasDestructuringPattern = false
        var isRestParameter = false
        var duplicateParameter = JSC.JSParseIdentifier()
        var restParameterStart = 0

        repeat {
            var parameter = B.DestructuringPattern.null
            var defaultValue = B.Expression.null

            if match(.closeParen) {
                break
            }

            if consume(.dotDotDot, [], &facade) {
                if isDisallowedIdentifierAwait(token, &facade) {
                    return semanticFail("Cannot use 'await' as a parameter name in an async function")
                }
                let destructuringPattern = parseDestructuringPattern(
                    &context,
                    .parameters,
                    .notExported,
                    &duplicateParameter,
                    &hasDestructuringPattern,
                    .DeclarationStatement,
                    depth: 0,
                    &facade
                )
                if hasError {
                    return false
                }
                parameter = context.createRestParameter(&facade, destructuringPattern, restParameterStart)
                if match(.comma) {
                    // Let's have a good error message for this common case.
                    return fail("Rest parameter should be the last parameter in a function declaration")
                }
                isRestParameter = true
            } else {
                parameter = parseDestructuringPattern(
                    &context,
                    .parameters,
                    .notExported,
                    &duplicateParameter,
                    &hasDestructuringPattern,
                    .DeclarationStatement,
                    depth: 0,
                    &facade
                )
            }
            if parameter.isNull {
                return fail("Cannot parse parameter pattern")
            }
            if !isRestParameter {
                defaultValue = parseDefaultValueForDestructuringPattern(&context, &facade)
                if !defaultValue.isNull {
                    hasDefaultParameterValues = true
                }
            }
            if hasError {
                return false
            }
            if !duplicateParameter.isNull {
                let id = ErrorMessagePart.identifier(duplicateParameter)
                if hasDefaultParameterValues {
                    return semanticFail(
                        ErrorMessage(.text("Duplicate parameter '"), id, .text("' not allowed in function with default parameter values"))
                    )
                }
                if hasDestructuringPattern {
                    return semanticFail(
                        ErrorMessage(.text("Duplicate parameter '"), id, .text("' not allowed in function with destructuring parameters"))
                    )
                }
                if isRestParameter {
                    return semanticFail(
                        ErrorMessage(.text("Duplicate parameter '"), id, .text("' not allowed in function with a rest parameter"))
                    )
                }
                if isArrowFunction {
                    return semanticFail(ErrorMessage(.text("Duplicate parameter '"), id, .text("' not allowed in an arrow function")))
                }
                if isMethod {
                    return semanticFail(ErrorMessage(.text("Duplicate parameter '"), id, .text("' not allowed in a method")))
                }
            }
            if isRestParameter || !defaultValue.isNull || hasDestructuringPattern {
                scopes[topScope].setHasNonSimpleParameterList()
            }
            context.appendParameter(&facade, list, parameter, defaultValue)
            if !isRestParameter {
                restParameterStart += 1
                if !hasDefaultParameterValues {
                    parameterCount += 1
                }
            }
        } while !isRestParameter && consume(.comma, [], &facade)

        return true
    }

    // MARK: Function body

    mutating func parseFunctionBody<B: TreeBuilder, S: TreeBuilder>(
        _ context: inout B,
        _ syntaxChecker: inout S,
        _ startLocation: JSC.JSTokenLocation,
        _ functionStart: UInt32,
        _ functionNameStart: Int,
        _ parametersStart: Int,
        _ constructorKind: JSC.ConstructorKind,
        _ superBinding: JSC.SuperBinding,
        _ bodyType: FunctionBodyType,
        _ parameterCount: UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> B.FunctionBody {
        let savedParsingClassFieldInitializer = parserState.isParsingClassFieldInitializer
        parserState.isParsingClassFieldInitializer = bodyType != .standardFunctionBodyBlock && savedParsingClassFieldInitializer
        defer { parserState.isParsingClassFieldInitializer = savedParsingClassFieldInitializer }
        let savedClassFieldInitMasksAsync = parserState.classFieldInitMasksAsync
        parserState.classFieldInitMasksAsync = !JSC.isAsyncFunctionParseMode(parseMode) && savedClassFieldInitMasksAsync
        defer { parserState.classFieldInitMasksAsync = savedClassFieldInitMasksAsync }
        let savedAllowAwait = parserState.allowAwait
        parserState.allowAwait = true
        defer { parserState.allowAwait = savedAllowAwait }

        let isArrowFunctionBodyExpression = bodyType == .arrowFunctionBodyExpression
        if !isArrowFunctionBodyExpression {
            next([], &facade)
            if match(.closeBrace) {
                let functionSuperBinding = adjustSuperBindingForBaseConstructor(
                    constructorKind,
                    superBinding,
                    parseMode,
                    needsSuperBinding: scopes[topScope].needsSuperBinding,
                    usesEval: scopes[topScope].usesEval,
                    scopes[topScope].innerArrowFunctionFeatures.rawValue
                )
                return context.createFunctionMetadata(
                    &facade,
                    startLocation,
                    tokenLocation,
                    functionStart,
                    Int32(truncatingIfNeeded: functionNameStart),
                    Int32(truncatingIfNeeded: parametersStart),
                    currentImplementationVisibility,
                    currentLexicallyScopedFeatures,
                    constructorKind,
                    functionSuperBinding,
                    parameterCount,
                    parseMode,
                    isArrowFunctionBodyExpression
                )
            }
        }

        let savedStatementDepth = statementDepth
        statementDepth = 0
        defer { statementDepth = savedStatementDepth }
        if !parseBodySourceElements(&context, &syntaxChecker, isArrowFunctionBodyExpression, .checkForStrictMode, &facade) {
            return fail(
                bodyType == .standardFunctionBodyBlock ? "Cannot parse body of this function" : "Cannot parse body of this arrow function"
            )
        }
        let functionSuperBinding = adjustSuperBindingForBaseConstructor(
            constructorKind,
            superBinding,
            parseMode,
            needsSuperBinding: scopes[topScope].needsSuperBinding,
            usesEval: scopes[topScope].usesEval,
            scopes[topScope].innerArrowFunctionFeatures.rawValue
        )
        let needsPrivate = JSC.isAsyncFunctionWrapperParseMode(parseMode) && scopes[topScope].usesAwait
        let implementationVisibility: JSC.ImplementationVisibility =
            needsPrivate && currentImplementationVisibility.rawValue < JSC.ImplementationVisibility.Private.rawValue
            ? .Private : currentImplementationVisibility
        if needsPrivate {
            scopes[topScope].implementationVisibility = implementationVisibility
        }
        return context.createFunctionMetadata(
            &facade,
            startLocation,
            tokenLocation,
            functionStart,
            Int32(truncatingIfNeeded: functionNameStart),
            Int32(truncatingIfNeeded: parametersStart),
            implementationVisibility,
            currentLexicallyScopedFeatures,
            constructorKind,
            functionSuperBinding,
            parameterCount,
            parseMode,
            isArrowFunctionBodyExpression
        )
    }

    // MARK: Function parameters

    mutating func parseFunctionParameters<B: TreeBuilder>(
        _ context: inout B,
        _ parameterCount: inout UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> B.FormalParameterList {
        let mode = parseMode
        precondition(mode != .ProgramMode && mode != .ModuleAnalyzeMode && mode != .ModuleEvaluateMode)
        let parameterList = context.createFormalParameterList(&facade)
        if mode == .ClassStaticBlockMode {
            return parameterList
        }
        let savedPhase = parserState.functionParsePhase
        parserState.functionParsePhase = .parameters
        defer { parserState.functionParsePhase = savedPhase }

        if mode == .ArrowFunctionMode || mode == .AsyncArrowFunctionMode {
            if !matchSpecIdentifier(&facade) && !match(.openParen) {
                if failDueToKeyword(token, "\(mode.functionKindName) name", &facade) {
                    return .null
                }
                return fail("Expected an arrow function input parameter")
            }

            if consume(.openParen, [], &facade) {
                if match(.closeParen) {
                    parameterCount = 0
                } else {
                    if !parseFormalParameters(
                        &context,
                        parameterList,
                        isArrowFunction: true,
                        isMethod: false,
                        &parameterCount,
                        &facade
                    ) {
                        if failsBeforeMessage {
                            return failDueToUnexpectedToken()
                        }
                        return fail(ErrorMessage(.text("Cannot parse parameters for this "), .text(mode.functionKindName)))
                    }
                }
                if !consumeOrFail(.closeParen, "Expected a ')' or a ',' after a parameter declaration", &facade) {
                    return .null
                }
            } else {
                parameterCount = 1
                var duplicateParameter = JSC.JSParseIdentifier()
                var hasDestructuringPattern = false
                let parameter = parseDestructuringPattern(
                    &context,
                    .parameters,
                    .notExported,
                    &duplicateParameter,
                    &hasDestructuringPattern,
                    .DeclarationStatement,
                    depth: 0,
                    &facade
                )
                if parameter.isNull {
                    return fail("Cannot parse parameter pattern")
                }
                context.appendParameter(&facade, parameterList, parameter, .null)
            }
            return parameterList
        }

        if !consume(.openParen, [], &facade) {
            if failDueToKeyword(token, "\(mode.functionKindName) name", &facade) {
                return .null
            }
            if failsBeforeMessage {
                return failDueToUnexpectedToken()
            }
            return fail(
                ErrorMessage(.text("Expected an opening '(' before a "), .text(mode.functionKindName), .text("'s parameter list"))
            )
        }

        if mode == .GetterMode {
            if !consumeOrFail(.closeParen, "getter functions must have no parameters", &facade) {
                return .null
            }
            parameterCount = 0
        } else if mode == .SetterMode {
            if match(.closeParen) {
                return fail("setter functions must have one parameter")
            }
            var duplicateParameter = JSC.JSParseIdentifier()
            var hasDestructuringPattern = false
            let parameter = parseDestructuringPattern(
                &context,
                .parameters,
                .notExported,
                &duplicateParameter,
                &hasDestructuringPattern,
                .DeclarationStatement,
                depth: 0,
                &facade
            )
            if parameter.isNull {
                return fail("setter functions must have one parameter")
            }
            let defaultValue = parseDefaultValueForDestructuringPattern(&context, &facade)
            if hasError {
                return .null
            }
            if !defaultValue.isNull || hasDestructuringPattern {
                if !duplicateParameter.isNull {
                    return semanticFail(
                        ErrorMessage(
                            .text("Duplicate parameter '"),
                            .identifier(duplicateParameter),
                            .text("' not allowed in function with non-simple parameter list")
                        )
                    )
                }
                scopes[topScope].setHasNonSimpleParameterList()
            }
            context.appendParameter(&facade, parameterList, parameter, defaultValue)
            parameterCount = defaultValue.isNull ? 1 : 0
            if match(.comma) {
                return fail("setter functions must have one parameter")
            }
            if !consumeOrFail(.closeParen, "Expected a ')' after a parameter declaration", &facade) {
                return .null
            }
        } else {
            if match(.closeParen) {
                parameterCount = 0
            } else {
                if !parseFormalParameters(
                    &context,
                    parameterList,
                    isArrowFunction: false,
                    isMethod: JSC.isMethodParseMode(mode),
                    &parameterCount,
                    &facade
                ) {
                    if failsBeforeMessage {
                        return failDueToUnexpectedToken()
                    }
                    return fail(ErrorMessage(.text("Cannot parse parameters for this "), .text(mode.functionKindName)))
                }
            }
            if !consumeOrFail(.closeParen, "Expected a ')' or a ',' after a parameter declaration", &facade) {
                return .null
            }
        }

        return parameterList
    }

    // MARK: Generator parameters

    mutating func createGeneratorParameters<B: TreeBuilder>(
        _ context: inout B,
        _ parameterCount: inout UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> B.FormalParameterList {
        let parameters = context.createFormalParameterList(&facade)

        let location = tokenLocation
        let position = tokenStartPosition

        // @generator, @generatorState, @generatorValue, @generatorResumeMode and @generatorFrame.
        let names: [JSC.JSParseWellKnownName] = [
            .generatorPrivateName, .generatorStatePrivateName, .generatorValuePrivateName, .generatorResumeModePrivateName,
            .generatorFramePrivateName,
        ]
        for name in names {
            let ident = facade.wellKnownIdentifier(name)
            _ = declareParameter(ident, &facade)
            let binding = context.createBindingLocation(&facade, location, ident, position, position, .DeclarationStatement)
            context.appendParameter(&facade, parameters, binding, .null)
            parameterCount += 1
        }

        return parameters
    }

    // MARK: Function info

    // Builds the function from the source provider cache and skips the parser past it. Returns false, having popped
    // nothing, when the cache does not know the function.
    private mutating func tryLoadCachedFunction<B: TreeBuilder>(
        _ context: inout B,
        _ mode: JSC.SourceParseMode,
        _ functionScope: ScopeRef,
        _ functionStart: UInt32,
        _ functionNameStart: Int,
        _ parametersStart: Int,
        _ startLocation: JSC.JSTokenLocation,
        _ functionInfo: inout FunctionInfo<B>,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        if !modes.useSourceProviderCache {
            return false
        }
        if hasDebuggerParseData {
            return false
        }
        assert(parametersStart != -1)

        // If we know about this function already, we can use the cached info and skip the parser to the end of the function.
        guard let cachedInfo = findCachedFunctionInfo(functionScope, Int32(truncatingIfNeeded: parametersStart), &facade)
        else {
            return false
        }
        // If we're in a strict context, the cached function info must say it was strict too.
        assert(!strictMode || cachedInfo.lexicallyScopedFeatures & JSC.StrictModeLexicallyScopedFeature != 0)
        var endLocation = JSC.JSTokenLocation()

        let cachedConstructorKind = cachedInfo.constructorKind
        let cachedExpectedSuperBinding = cachedInfo.expectedSuperBinding

        endLocation.startOffset = cachedInfo.lastTokenStartOffset
        let functionBodyType: FunctionBodyType
        if mode == .ArrowFunctionMode || mode == .AsyncArrowFunctionMode {
            functionBodyType = cachedInfo.isBodyArrowExpression ? .arrowFunctionBodyExpression : .arrowFunctionBodyBlock
        } else {
            functionBodyType = .standardFunctionBodyBlock
        }

        let functionSuperBinding = adjustSuperBindingForBaseConstructor(
            cachedConstructorKind,
            cachedExpectedSuperBinding,
            mode,
            needsSuperBinding: cachedInfo.needsSuperBinding,
            usesEval: cachedInfo.usesEval,
            cachedInfo.innerArrowFunctionFeatures
        )

        functionInfo.body = context.createFunctionMetadata(
            &facade,
            startLocation,
            endLocation,
            functionStart,
            Int32(truncatingIfNeeded: functionNameStart),
            Int32(truncatingIfNeeded: parametersStart),
            cachedInfo.implementationVisibility,
            cachedInfo.lexicallyScopedFeatures,
            cachedConstructorKind,
            functionSuperBinding,
            cachedInfo.parameterCount,
            mode,
            functionBodyType == .arrowFunctionBodyExpression
        )
        functionInfo.endOffset = cachedInfo.endFunctionOffset
        functionInfo.parameterCount = cachedInfo.parameterCount

        withScope(functionScope) { $0.restoreFromSourceProviderCache(cachedInfo) }
        // The function scope is the current one and its features were replaced.
        assert(functionScope.index == topScope)
        topStrictMode = scopes[topScope].strictMode
        popScope(functionScope, shouldTrackClosedVariables: B.needsFreeVariableInfo, takeContainers: false, &facade)

        // The cached function's last token.
        token = Token()
        token.type = JSC.JSTokenType(rawValue: cachedInfo.tokenType.rawValue)
        token.startPosition.offset = Int32(bitPattern: cachedInfo.lastTokenStartOffset)
        token.endPosition.offset = Int32(bitPattern: cachedInfo.lastTokenEndOffset)

        lexer.setOffset(Int(token.endPosition.offset))

        switch functionBodyType {
        case .arrowFunctionBodyExpression:
            next([], &facade)
            context.setEndOffset(&facade, functionInfo.body, Int32(truncatingIfNeeded: lexer.currentOffset))
        case .arrowFunctionBodyBlock, .standardFunctionBodyBlock:
            context.setEndOffset(&facade, functionInfo.body, Int32(truncatingIfNeeded: lexer.currentOffset))
            next([], &facade)
        }
        return true
    }

    mutating func parseFunctionInfo<B: TreeBuilder>(
        _ context: inout B,
        _ requirements: FunctionNameRequirements,
        nameIsInContainingScope: Bool,
        _ constructorKind: JSC.ConstructorKind,
        _ expectedSuperBinding: JSC.SuperBinding,
        _ functionStart: UInt32,
        _ functionInfo: inout FunctionInfo<B>,
        _ functionDefinitionType: FunctionDefinitionType,
        functionConstructorParametersEndPosition: Int? = nil,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        let mode = parseMode
        precondition(JSC.isFunctionParseMode(mode))

        let parentScope = current

        let functionNameIsAwait = isPossiblyEscapedAwait(token, &facade)
        let disallowedAwaitFunctionNameReason: Swift.String? =
            functionNameIsAwait && !canUseIdentifierAwait ? disallowedIdentifierAwaitReason() : nil

        let functionScope = pushScope(&facade)
        var functionScopePopped = false
        defer {
            if !functionScopePopped {
                popScope(functionScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }

        withScope(functionScope) {
            $0.setSourceParseMode(mode)
        }
        resetImplementationVisibilityIfNeeded()

        withScope(functionScope) {
            $0.expectedSuperBinding = expectedSuperBinding
            $0.constructorKind = constructorKind
        }

        let savedFunctionParsePhase = parserState.functionParsePhase
        parserState.functionParsePhase = .body
        defer { parserState.functionParsePhase = savedFunctionParsePhase }
        let functionNameStart = Int(token.startPosition.offset)
        let lastFunctionName = parserState.lastFunctionName
        parserState.lastFunctionName = JSC.JSParseIdentifier()
        let parametersStart: Int
        let startLocation: JSC.JSTokenLocation
        let functionBodyType: FunctionBodyType

        var syntaxChecker = SyntaxChecker()

        let oldState: (parserState: ParserState, unaryTokenStackDepth: Int32)
        if mode == .ArrowFunctionMode || mode == .AsyncArrowFunctionMode {
            startLocation = tokenLocation

            parametersStart = Int(token.startPosition.offset)
            functionInfo.startOffset = UInt32(truncatingIfNeeded: parametersStart)

            if tryLoadCachedFunction(
                &context,
                mode,
                functionScope,
                functionStart,
                functionNameStart,
                parametersStart,
                startLocation,
                &functionInfo,
                &facade
            ) {
                functionScopePopped = true
                return true
            }

            parserState.lastFunctionName = lastFunctionName
            oldState = saveParserStateForFunction(&context, &facade)
            do {
                // Parse formal parameters with [+Yield] parameterization, in order to ban YieldExpressions
                // in ArrowFormalParameters, per ES6 #sec-arrow-function-definitions-static-semantics-early-errors.
                let parentIsGeneratorFunction = scopes[parentScope.index].isGeneratorFunction
                let savedIsGeneratorFunction = withScope(functionScope) { $0.exchangeIsGeneratorFunction(parentIsGeneratorFunction) }
                defer { withScope(functionScope) { _ = $0.exchangeIsGeneratorFunction(savedIsGeneratorFunction) } }
                let savedAllowAwait = parserState.allowAwait
                parserState.allowAwait = !scopes[parentScope.index].isAsyncFunction && !JSC.isAsyncFunctionParseMode(mode)
                defer { parserState.allowAwait = savedAllowAwait }
                _ = parseFunctionParameters(&syntaxChecker, &functionInfo.parameterCount, &facade)
                if hasError {
                    return false
                }
            }

            if !match(.arrowFunction) {
                return fail("Expected a '=>' after arrow function parameter declaration")
            }

            if lexer.hasLineTerminatorBeforeToken {
                return failDueToUnexpectedToken()
            }

            assert(constructorKind == .None)

            // Check if arrow body start with {. If it true it mean that arrow function is Fat arrow function
            // and we need use common approach to parse function body
            next([], &facade)
            functionBodyType = match(.openBrace) ? .arrowFunctionBodyBlock : .arrowFunctionBodyExpression
        } else {
            // http://ecma-international.org/ecma-262/6.0/#sec-function-definitions
            // The name of FunctionExpression and AsyncFunctionExpression can accept "yield" even in the context of generator.
            var canUseYield = !strictMode
            if !(functionDefinitionType == .expression && (mode == .NormalFunctionMode || mode == .AsyncFunctionMode)) {
                canUseYield = canUseYield && !scopes[parentScope.index].isGeneratorFunction
            }

            if requirements != .unnamed {
                assert(
                    !(requirements == .none && functionInfo.name.isNull),
                    "When specifying FunctionNameRequirements::None, we need to initialize functionInfo.name with the default value in the caller side."
                )
                if matchSpecIdentifier(canUseYield: canUseYield, isAwait: functionNameIsAwait, &facade) {
                    functionInfo.name = token.data.ident
                    parserState.lastFunctionName = functionInfo.name
                    if let reason = disallowedAwaitFunctionNameReason {
                        if functionDefinitionType == .declaration || JSC.isAsyncFunctionOrAsyncGeneratorWrapperParseMode(mode) {
                            return semanticFail(ErrorMessage(.text("Cannot declare function named 'await' "), .text(reason)))
                        }
                    } else if JSC.isAsyncFunctionOrAsyncGeneratorWrapperParseMode(mode) && match(.awaitKeyword)
                        && functionDefinitionType == .expression
                    {
                        return semanticFail(
                            ErrorMessage(.text("Cannot declare "), .text(mode.functionKindName), .text(" named 'await'"))
                        )
                    } else if JSC.isGeneratorOrAsyncGeneratorWrapperParseMode(mode) && match(.yieldKeyword)
                        && functionDefinitionType == .expression
                    {
                        return semanticFail(
                            ErrorMessage(.text("Cannot declare "), .text(mode.functionKindName), .text(" named 'yield'"))
                        )
                    }
                    next([], &facade)
                    if !nameIsInContainingScope {
                        let declarationResult = scopes[functionScope.index].declareCallee(functionInfo.name, &facade)
                        if declarationResult.contains(.invalidStrictMode) && strictMode {
                            return semanticFail(
                                ErrorMessage(
                                    .text("'"),
                                    .identifier(functionInfo.name),
                                    .text("' is not a valid "),
                                    .text(mode.functionKindName),
                                    .text(" name in strict mode")
                                )
                            )
                        }
                    }
                } else if requirements == .named {
                    if match(.openParen) {
                        if mode == .NormalFunctionMode {
                            return semanticFail("Function statements must have a name")
                        }
                        if mode == .AsyncFunctionMode {
                            return semanticFail("Async function statements must have a name")
                        }
                    }
                    if failDueToKeyword(token, "\(mode.functionKindName) name", &facade) {
                        return false
                    }
                    return failDueToUnexpectedToken()
                }
                assert(!functionInfo.name.isNull)
            }

            startLocation = tokenLocation

            parametersStart = Int(token.startPosition.offset)
            functionInfo.startOffset = UInt32(truncatingIfNeeded: parametersStart)

            if tryLoadCachedFunction(
                &context,
                mode,
                functionScope,
                functionStart,
                functionNameStart,
                parametersStart,
                startLocation,
                &functionInfo,
                &facade
            ) {
                functionScopePopped = true
                return true
            }

            parserState.lastFunctionName = lastFunctionName
            oldState = saveParserStateForFunction(&context, &facade)
            do {
                let savedAllowAwait = parserState.allowAwait
                parserState.allowAwait = !JSC.isAsyncFunctionParseMode(mode)
                defer { parserState.allowAwait = savedAllowAwait }
                _ = parseFunctionParameters(&syntaxChecker, &functionInfo.parameterCount, &facade)
                if hasError {
                    return false
                }
            }

            if !match(.openBrace) {
                // The error, end or error token is reported as is: a static block's mode has no functionKindName.
                if failsBeforeMessage {
                    return failDueToUnexpectedToken()
                }
                return fail(
                    ErrorMessage(.text("Expected an opening '{' at the start of a "), .text(mode.functionKindName), .text(" body"))
                )
            }

            // If the code is invoked from function constructor, we need to ensure that parameters are only composed by the string offered as parameters.
            if let endPosition = functionConstructorParametersEndPosition {
                if Int(lastTokenEndPosition.offset) != endPosition {
                    return semanticFail("Parameters should match arguments offered as parameters in Function constructor")
                }
            }

            // BytecodeGenerator emits code to throw TypeError when a class constructor is "call"ed.
            // Set ConstructorKind to None for non-constructor methods of classes.

            functionBodyType = .standardFunctionBodyBlock
        }

        // Parameter expressions cannot see the body's declarations, which live in a separate environment
        // (https://tc39.es/ecma262/#sec-functiondeclarationinstantiation). The parameters and the body
        // share this Scope, so the parameter list's free variables must reach the parent before the
        // body's declarations hide them, as they would hide x in `function f(a = x) { var x; }`.
        // FIXME: Give the parameters their own Scope. Until then, a closure in a parameter expression
        // makes a same-named body declaration look captured. https://bugs.webkit.org/show_bug.cgi?id=156962
        let functionStorage = withScope(functionScope) { $0.storage }
        facade.collectNonLocalCapturesFromParameterExpressions(functionStorage)
        if facade.hasNonLocalCapturesFromParameterExpressions(functionStorage) {
            collectFreeVariablesFromNestedScope(into: parentScope, from: functionScope, B.needsFreeVariableInfo, &facade)
        }

        var implementationVisibility = currentImplementationVisibility
        if JSC.isGeneratorOrAsyncFunctionWrapperParseMode(mode) {
            let generatorBodyScope = pushScope(&facade)
            var generatorBodyScopePopped = false
            defer {
                if !generatorBodyScopePopped {
                    popScope(generatorBodyScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
                }
            }
            let innerParseMode =
                JSC.isAsyncFunctionOrAsyncGeneratorWrapperParseMode(mode) ? mode.asyncFunctionBodyMode : .GeneratorBodyMode

            withScope(generatorBodyScope) {
                $0.setSourceParseMode(innerParseMode)
            }
            resetImplementationVisibilityIfNeeded()

            withScope(generatorBodyScope) {
                $0.constructorKind = .None
                $0.expectedSuperBinding = expectedSuperBinding
            }

            // Disallow 'use strict' directives in the implicit inner function if
            // needed.
            if scopes[functionScope.index].hasNonSimpleParameterList {
                withScope(generatorBodyScope) { $0.setHasNonSimpleParameterList() }
            }

            functionInfo.body = parseFunctionBody(
                &context,
                &syntaxChecker,
                startLocation,
                functionStart,
                functionNameStart,
                parametersStart,
                constructorKind,
                expectedSuperBinding,
                functionBodyType,
                functionInfo.parameterCount,
                &facade
            )

            // When a generator has a "use strict" directive, a generator function wrapping it should be strict mode.
            // The function scope is below the generator body's, which is the current one: topStrictMode is not its.
            if scopes[generatorBodyScope.index].strictMode {
                assert(functionScope.index != topScope)
                withScope(functionScope) { $0.setStrictMode() }
            }

            implementationVisibility = scopes[generatorBodyScope.index].implementationVisibility
            popScope(generatorBodyScope, shouldTrackClosedVariables: B.needsFreeVariableInfo, takeContainers: false, &facade)
            generatorBodyScopePopped = true
        } else {
            functionInfo.body = parseFunctionBody(
                &context,
                &syntaxChecker,
                startLocation,
                functionStart,
                functionNameStart,
                parametersStart,
                constructorKind,
                expectedSuperBinding,
                functionBodyType,
                functionInfo.parameterCount,
                &facade
            )
        }

        restoreParserStateForFunction(&context, oldState, &facade)
        if functionInfo.body.isNull {
            if failsBeforeMessage {
                return failDueToUnexpectedToken()
            }
            return fail(ErrorMessage(.text("Cannot parse the body of this "), .text(mode.functionKindName)))
        }
        context.setEndOffset(&facade, functionInfo.body, Int32(truncatingIfNeeded: lexer.currentOffset))
        if scopes[functionScope.index].strictMode && requirements != .unnamed {
            assert(!functionInfo.name.isNull)
            precondition(
                mode == .NormalFunctionMode || mode == .MethodMode || mode == .ArrowFunctionMode || mode == .GeneratorBodyMode
                    || mode == .GeneratorWrapperFunctionMode || mode == .ClassStaticBlockMode
                    || JSC.isAsyncFunctionOrAsyncGeneratorWrapperParseMode(mode)
            )
            if functionInfo.name.matches(.arguments, &facade) || functionInfo.name.matches(.eval, &facade)
                || functionInfo.name.isStrictModeReservedWord(&facade)
            {
                return failNotValidStrictFunctionName(functionInfo.name)
            }
        }

        var location = token.location
        functionInfo.endOffset = UInt32(bitPattern: token.startPosition.offset)

        if functionBodyType == .arrowFunctionBodyExpression {
            location = lastTokenLocation
            functionInfo.endOffset = location.endOffset
        } else {
            recordFunctionEntryLocation(JSC.JSTextPosition(offset: Int(startLocation.startOffset)), &facade)
            recordFunctionLeaveLocation(JSC.JSTextPosition(offset: Int(location.startOffset)), &facade)
        }

        // Cache the tokenizer state and the function scope the first time the function is parsed.
        // Any future reparsing can then skip the function.
        // For arrow function is 8 = x=>x + 4 symbols;
        // For ordinary function is 16  = function(){} + 4 symbols
        let minimumSourceLengthToCache = functionBodyType == .standardFunctionBodyBlock ? 16 : 8
        var hasPrecomputedFreeVariables = false
        let sourceLength = Int(functionInfo.endOffset) - Int(functionInfo.startOffset)
        var parameters = JSC.JSParseCachedFunction()
        if hasFunctionCache && sourceLength > minimumSourceLengthToCache {
            parameters.endFunctionOffset = functionInfo.endOffset
            parameters.lastTokenStartOffset = location.startOffset
            parameters.lastTokenEndOffset = location.endOffset
            parameters.parameterCount = functionInfo.parameterCount
            parameters.constructorKind = constructorKind
            parameters.expectedSuperBinding = expectedSuperBinding
            parameters.implementationVisibility = implementationVisibility
            if functionBodyType == .arrowFunctionBodyExpression {
                parameters.isBodyArrowExpression = true
                parameters.tokenType = token.type
            }
            withScope(functionScope) { $0.fillParametersForSourceProviderCache(&parameters) }
            facade.recordCachedFunction(withScope(functionScope) { $0.storage }, parameters)
            // The facade takes the free variables from the cache item just recorded when the scope is popped.
            assert(facade.hasRecordedCacheParameters(withScope(functionScope) { $0.storage }))
            hasPrecomputedFreeVariables = true
        }

        let functionScopeWasStrictMode = scopes[functionScope.index].strictMode

        popScope(
            functionScope,
            shouldTrackClosedVariables: B.needsFreeVariableInfo,
            takeContainers: false,
            &facade
        )
        functionScopePopped = true

        if functionBodyType != .arrowFunctionBodyExpression {
            // The message is made only when failsBeforeMessage is false: a static block's mode has no functionKindName.
            if !consume(.closeBrace, [], &facade) {
                if failsBeforeMessage {
                    return failDueToUnexpectedToken()
                }
                logTokenError(ErrorMessage(.text("Expected a closing '}' after a "), .text(mode.functionKindName), .text(" body")))
                return false
            }
        } else {
            // We need to lex the last token again because the last token is lexed under the different context because of the following possibilities.
            // 1. which may have different strict mode.
            // 2. which may not build strings for tokens.
            // But (1) is not possible because we do not recognize the string literal in ArrowFunctionBodyExpression as directive and this is correct in terms of the spec (`value => "use strict"`).
            // So we only check TreeBuilder's type here.
            assert(functionScopeWasStrictMode == strictMode)
            if B.createsAST {
                lexCurrentTokenAgainUnderCurrentContext(&context, &facade)
            }
        }

        if hasPrecomputedFreeVariables {
            facade.addRecordedCachedFunction(Int32(truncatingIfNeeded: functionInfo.startOffset))
        }

        return true
    }

    // MARK: Function and class declarations

    mutating func parseFunctionDeclaration<B: TreeBuilder>(
        _ context: inout B,
        _ declarationType: FunctionDeclarationType = .declaration,
        exportType: ExportType = .notExported,
        defaultContext declarationDefaultContext: DeclarationDefaultContext = .standard,
        functionConstructorParametersEndPosition: Int? = nil,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        assert(match(.functionKeyword))
        let location = tokenLocation
        let functionStart = tokenStart
        next([], &facade)
        var newParseMode = JSC.SourceParseMode.NormalFunctionMode
        if match(.times) {
            if declarationType == .statement {
                return fail("Cannot use generator function declaration in single-statement context")
            }
            next([], &facade)
            newParseMode = .GeneratorWrapperFunctionMode
        }
        let savedParseMode = parseMode
        parseMode = newParseMode
        defer { parseMode = savedParseMode }

        var functionInfo = FunctionInfo<B>()
        let requirements: FunctionNameRequirements = declarationDefaultContext == .exportDefault ? .none : .named
        if declarationDefaultContext == .exportDefault {
            // Under the "export default" context, function declaration does not require the function name. In this case,
            // we use "*default*" as this function declaration's name.
            functionInfo.name = facade.wellKnownIdentifier(.starDefaultPrivateName)
        }

        if !parseFunctionInfo(
            &context,
            requirements,
            nameIsInContainingScope: true,
            .None,
            .NotNeeded,
            functionStart,
            &functionInfo,
            .declaration,
            functionConstructorParametersEndPosition: functionConstructorParametersEndPosition,
            &facade
        ) {
            return fail("Cannot parse this function")
        }
        assert(!functionInfo.name.isNull)

        let functionDeclaration = declareFunction(functionInfo.name, &facade)
        let declarationResult = functionDeclaration.result
        if declarationResult.contains(.invalidStrictMode) && strictMode {
            return semanticFail(
                ErrorMessage(.text("Cannot declare a function named '"), .identifier(functionInfo.name), .text("' in strict mode"))
            )
        }
        if declarationResult.contains(.invalidDuplicateDeclaration) {
            return semanticFail(
                ErrorMessage(
                    .text("Cannot declare a function that shadows a let/const/class/function variable '"),
                    .identifier(functionInfo.name),
                    .text("'")
                )
            )
        }
        if exportType == .exported {
            assert(declarationDefaultContext != .exportDefault, "Export default case will export the name and binding in the caller.")
            if !exportName(functionInfo.name, &facade) {
                return semanticFail(
                    ErrorMessage(.text("Cannot export a duplicate function name: '"), .identifier(functionInfo.name), .text("'"))
                )
            }
            facade.moduleExportBinding(functionInfo.name)
        }

        let result = context.createFuncDeclStatement(&facade, location, functionInfo)
        if B.createsAST, let metadata = functionInfo.body.parseNode {
            scopes[functionDeclaration.scope.index].appendFunction(metadata, &facade)
            let isSloppyModeHoistingCandidate = statementDepth != 1 && !strictMode && parseMode == .NormalFunctionMode
            if isSloppyModeHoistingCandidate {
                // Functions declared inside a function inside a nested block scope in sloppy mode are subject to this
                // rule defined inside Annex B.3.2 in the ECMA-262 spec: the function is created as a local block scoped
                // variable, and assigned to a "var" variable when the block is evaluated, only if declaring such a "var"
                // would not be a syntax error and there is no parameter with the same name.
                scopes[functionDeclaration.scope.index]
                    .addSloppyModeFunctionHoistingCandidate(
                        metadata,
                        needsDuplicateDeclarationCheck: false,
                        &facade
                    )
            }
        }
        return result
    }

    /// Out of line: inlined, its locals sit in parseStatementListItem's frame on every statement.
    @inline(never)
    mutating func parseAsyncFunctionDeclaration<B: TreeBuilder>(
        _ context: inout B,
        _ functionStart: UInt32,
        exportType: ExportType = .notExported,
        defaultContext declarationDefaultContext: DeclarationDefaultContext = .standard,
        functionConstructorParametersEndPosition: Int? = nil,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        assert(match(.functionKeyword))
        let location = tokenLocation
        next([], &facade)
        var functionInfo = FunctionInfo<B>()
        var newParseMode = JSC.SourceParseMode.AsyncFunctionMode
        if consume(.times, [], &facade) {
            newParseMode = .AsyncGeneratorWrapperFunctionMode
        }
        let savedParseMode = parseMode
        parseMode = newParseMode
        defer { parseMode = savedParseMode }

        let requirements: FunctionNameRequirements = declarationDefaultContext == .exportDefault ? .none : .named
        if declarationDefaultContext == .exportDefault {
            // Under the "export default" context, function declaration does not require the function name. In this case,
            // we use "*default*" as this function declaration's name.
            functionInfo.name = facade.wellKnownIdentifier(.starDefaultPrivateName)
        }

        if !parseFunctionInfo(
            &context,
            requirements,
            nameIsInContainingScope: true,
            .None,
            .NotNeeded,
            functionStart,
            &functionInfo,
            .declaration,
            functionConstructorParametersEndPosition: functionConstructorParametersEndPosition,
            &facade
        ) {
            return fail("Cannot parse this async function")
        }
        if functionInfo.name.isNull {
            return fail("Async function statements must have a name")
        }

        let functionDeclaration = declareFunction(functionInfo.name, &facade)
        let declarationResult = functionDeclaration.result
        if declarationResult.contains(.invalidStrictMode) && strictMode {
            return semanticFail(
                ErrorMessage(.text("Cannot declare an async function named '"), .identifier(functionInfo.name), .text("' in strict mode"))
            )
        }
        if declarationResult.contains(.invalidDuplicateDeclaration) {
            return semanticFail(
                ErrorMessage(
                    .text("Cannot declare an async function that shadows a let/const/class/function variable '"),
                    .identifier(functionInfo.name),
                    .text("'")
                )
            )
        }
        if exportType == .exported {
            if !exportName(functionInfo.name, &facade) {
                return semanticFail(
                    ErrorMessage(.text("Cannot export a duplicate function name: '"), .identifier(functionInfo.name), .text("'"))
                )
            }
            facade.moduleExportBinding(functionInfo.name)
        }

        let result = context.createFuncDeclStatement(&facade, location, functionInfo)
        if B.createsAST, let metadata = functionInfo.body.parseNode {
            scopes[functionDeclaration.scope.index].appendFunction(metadata, &facade)
        }
        return result
    }
}
