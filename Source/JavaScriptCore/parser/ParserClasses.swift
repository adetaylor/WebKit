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

private typealias DefineFieldType = JSC.DefineFieldNode.`Type`

extension Parser {
    mutating func parseClassDeclaration<B: TreeBuilder>(
        _ context: inout B,
        exportType: ExportType = .notExported,
        defaultContext declarationDefaultContext: DeclarationDefaultContext = .standard,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        assert(match(.classKeyword))
        let location = tokenLocation
        let classStart = tokenStartPosition

        var info = ClassInfo()
        let requirements: FunctionNameRequirements = declarationDefaultContext == .exportDefault ? .none : .named
        if declarationDefaultContext == .exportDefault {
            // Under the "export default" context, class declaration does not require the class name. In this case,
            // we use "*default*" as this class declaration's name.
            info.className = facade.wellKnownIdentifier(.starDefaultPrivateName)
        }

        let classExpr = parseClass(&context, requirements, &info, &facade)
        if classExpr.isNull {
            return fail("Failed to parse class")
        }
        assert(!info.className.isNull)

        let declarationResult = declareVariable(info.className, .let, .notImported, &facade)
        if declarationResult.contains(.invalidDuplicateDeclaration) {
            return semanticFail(ErrorMessage(.text("Cannot declare a class twice: '"), .identifier(info.className), .text("'")))
        }
        if exportType == .exported {
            assert(declarationDefaultContext != .exportDefault, "Export default case will export the name and binding in the caller.")
            if !exportName(info.className, &facade) {
                return semanticFail(ErrorMessage(.text("Cannot export a duplicate class name: '"), .identifier(info.className), .text("'")))
            }
            facade.moduleExportBinding(info.className)
        }

        let classEnd = lastTokenEndPosition

        return context.createClassDeclStatement(&facade, location, classExpr, classStart, classEnd)
    }

    // MARK: Class

    mutating func parseClass<B: TreeBuilder>(
        _ context: inout B,
        _ requirements: FunctionNameRequirements,
        _ info: inout ClassInfo,
        _ facade: inout JSC.JSParseFacade
    ) -> B.ClassExpression {
        assert(match(.classKeyword))
        let start = tokenStartPosition
        let location = tokenLocation
        info.startOffset = location.startOffset

        // We have a subtle problem here. Class heritage evaluation should find class declaration's constructor name, but
        // should not find private name evaluation. We need to create two scopes here since private name lookup will
        // traverse scope at linking time in CodeBlock. This classHeadScope is similar to functionScope in
        // FunctionExpression with name.
        let classHeadScope = pushScope(&facade)
        var classHeadScopePopped = false
        defer {
            if !classHeadScopePopped {
                popScope(classHeadScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }
        withScope(classHeadScope) {
            $0.setIsLexicalScope()
            $0.preventVarDeclarations()
            $0.setStrictMode()
        }
        next([], &facade)
        if scopes[topScope].isStaticBlock && match(.awaitKeyword) {
            return semanticFail("Cannot use 'await' as a class name within static block")
        }

        assert(requirements != .unnamed, "Currently, there is no caller that uses FunctionNameRequirements::Unnamed for class syntax.")
        assert(
            !(requirements == .none && info.className.isNull),
            "When specifying FunctionNameRequirements::None, we need to initialize info.className with the default value in the caller side."
        )
        if match(.identifier) || isAllowedIdentifierAwait(token, &facade) {
            info.className = token.data.ident
            next([], &facade)
            let className = info.className
            let declarationResult = withScope(classHeadScope) { $0.declareLexicalVariable(className, isConstant: true, &facade) }
            if declarationResult.contains(.invalidStrictMode) {
                return fail(ErrorMessage(.text("'"), .identifier(info.className), .text("' is not a valid class name")))
            }
        } else if requirements == .named {
            if match(.openBrace) {
                return semanticFail("Class statements must have a name")
            }
            if failDueToKeyword(token, "class name", &facade) {
                return .null
            }
            return failDueToUnexpectedToken()
        }
        assert(!info.className.isNull)

        var divot = start
        var parentClass = B.Expression.null
        if consume(.extendsKeyword, [], &facade) {
            divot = tokenStartPosition
            parentClass = parseMemberExpression(&context, &facade)
            if parentClass.isNull {
                return fail("Cannot parse the parent class name")
            }
        }
        let constructorKind: JSC.ConstructorKind = parentClass.isNull ? .Base : .Extends

        let classHeadEnd = lastTokenEndPosition
        if !consumeOrFail(.openBrace, "Expected opening '{' at the start of a class body", &facade) {
            return .null
        }

        let classScope = pushScope(&facade)
        var classScopePopped = false
        defer {
            if !classScopePopped {
                popScope(classScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }
        withScope(classScope) {
            $0.setIsLexicalScope()
            $0.preventVarDeclarations()
            $0.setStrictMode()
            $0.setIsClassScope()
        }

        var declaresPrivateMethod = false
        var declaresPrivateAccessor = false
        var declaresStaticPrivateMethod = false
        var declaresStaticPrivateAccessor = false

        var constructor = B.Expression.null
        var classElements = B.PropertyList.null
        var classElementsTail = B.PropertyList.null
        var nextInstanceComputedFieldID: UInt32 = 0
        var nextStaticComputedFieldID: UInt32 = 0
        while !match(.closeBrace) {
            if consume(.semicolon, [], &facade) {
                continue
            }

            let methodLocation = tokenLocation
            var functionStart = tokenStart

            // For backwards compatibility, "static" is a non-reserved keyword in non-strict mode.
            var tag = JSC.ClassElementTag.Instance
            var newParseMode = JSC.SourceParseMode.MethodMode
            var type = PropertyType(rawValue: JSC.PropertyNode.Constant.rawValue)
            if match(.reservedIfStrict) && token.data.ident.matches(.staticKeyword, &facade) {
                let savePoint = createSavePoint(&context, &facade)
                next([], &facade)
                if match(.openParen) || match(.semicolon) || match(.equal) {
                    // Reparse "static()" as a method or "static" as a class field.
                    restoreSavePoint(&context, savePoint, &facade)
                } else {
                    tag = .Static
                    functionStart = tokenStart
                    if match(.openBrace) {
                        newParseMode = .ClassStaticBlockMode
                    }
                }
            }

            // FIXME: Figure out a way to share more code with parseProperty.
            var ident = facade.wellKnownIdentifier(.nullIdentifier)
            var computedPropertyName = B.Expression.null
            var isGetter = false
            var isSetter = false
            if consume(.times, [], &facade) {
                newParseMode = .GeneratorWrapperMethodMode
            }

            parseMethod: while true {
                switch token.type {
                case .string:
                    ident = token.data.ident
                    next([], &facade)
                case .bigInt:
                    ident = facade.makeBigIntDecimalIdentifier(token.data.ident, token.data.radix)
                    if ident.isNull {
                        return fail("Cannot parse big int property name")
                    }
                    next([], &facade)
                case .escapedKeyword, .identifier, .awaitKeyword:
                    if token.type != .awaitKeyword, token.data.ident.matches(.async, &facade), !token.data.escaped {
                        if !JSC.isGeneratorMethodParseMode(newParseMode) && !JSC.isAsyncMethodParseMode(newParseMode) {
                            next([], &facade)
                            // We match SEMICOLON as a special case for a field called 'async' without initializer.
                            if match(.openParen) || match(.colon) || match(.semicolon) || match(.equal)
                                || lexer.hasLineTerminatorBeforeToken
                            {
                                ident = facade.wellKnownIdentifier(.async)
                                break
                            }
                            if consume(.times, [], &facade) {
                                newParseMode = .AsyncGeneratorWrapperMethodMode
                            } else {
                                newParseMode = .AsyncMethodMode
                            }
                            continue parseMethod
                        }
                    }
                    ident = token.data.ident
                    let escaped = token.data.escaped
                    next([], &facade)
                    if newParseMode == .MethodMode && !escaped
                        && (matchIdentifierOrKeyword() || match(.string) || match(.double) || match(.integer) || match(.bigInt)
                            || match(.openBracket) || match(.privateName))
                    {
                        isGetter = ident.matches(.get, &facade)
                        isSetter = ident.matches(.set, &facade)
                    }
                case .double, .integer:
                    ident = facade.makeNumericIdentifier(token.data.doubleValue)
                    next([], &facade)
                case .openBracket:
                    next([], &facade)
                    if scopes[topScope].isStaticBlock && match(.identifier) && isArgumentsIdentifier(&facade) {
                        return semanticFail("Cannot use 'arguments' as an identifier in static block")
                    }
                    computedPropertyName = parseAssignmentExpression(&context, &facade)
                    type = type | JSC.PropertyNode.Computed
                    if computedPropertyName.isNull {
                        return fail("Cannot parse computed property name")
                    }
                    if !handleProductionOrFail(.closeBracket, "]", "end", "a computed property name", &facade) {
                        return .null
                    }
                case .privateName:
                    ident = token.data.ident
                    if isGetter || isSetter {
                        return fail("Cannot parse class method with private name")
                    }
                    next([], &facade)
                    if match(.openParen) {
                        if scopes[classScope.index].declarePrivateMethod(ident, tag, &facade).contains(.invalidDuplicateDeclaration) {
                            return semanticFail("Cannot declare private method twice")
                        }
                        if ident.matches(.constructorPrivateField, &facade) {
                            return semanticFail("Cannot declare a private method named '#constructor'")
                        }

                        if tag == .Static {
                            declaresStaticPrivateMethod = true
                        } else {
                            declaresPrivateMethod = true
                        }

                        type = type | JSC.PropertyNode.PrivateMethod
                        break
                    }

                    if scopes[classScope.index].declarePrivateField(ident, &facade).contains(.invalidDuplicateDeclaration) {
                        return semanticFail("Cannot declare private field twice")
                    }
                    type = type | JSC.PropertyNode.PrivateField
                case .openBrace:
                    if newParseMode != .ClassStaticBlockMode {
                        return fail("Cannot parse static block without 'static'")
                    }
                    type = type | JSC.PropertyNode.Block
                default:
                    if token.type.isKeyword {
                        ident = token.data.ident
                        next([], &facade)
                        break
                    }
                    return failDueToUnexpectedToken()
                }
                break
            }

            var property = B.Property.null
            if isGetter || isSetter {
                if match(.privateName) {
                    ident = token.data.ident

                    let declarationResult =
                        isSetter
                        ? scopes[classScope.index].declarePrivateSetter(ident, tag, &facade)
                        : scopes[classScope.index].declarePrivateGetter(ident, tag, &facade)
                    if declarationResult.contains(.invalidDuplicateDeclaration) {
                        return semanticFail("Declared private setter with an already used name")
                    }
                    if tag == .Static {
                        if declarationResult.contains(.invalidPrivateStaticNonStatic) {
                            return semanticFail(
                                ErrorMessage(
                                    .text("Cannot declare a private static "),
                                    .text(isSetter ? "setter" : "getter"),
                                    .text(" if there is a non-static private "),
                                    .text(isSetter ? "getter" : "setter"),
                                    .text(" with used name")
                                )
                            )
                        }
                        declaresStaticPrivateAccessor = true
                    } else {
                        if declarationResult.contains(.invalidPrivateStaticNonStatic) {
                            return semanticFail(
                                ErrorMessage(
                                    .text("Cannot declare a private non-static "),
                                    .text(isSetter ? "setter" : "getter"),
                                    .text(" if there is a static private "),
                                    .text(isSetter ? "getter" : "setter"),
                                    .text(" with used name")
                                )
                            )
                        }
                        declaresPrivateAccessor = true
                    }

                    if isSetter {
                        type = type | JSC.PropertyNode.PrivateSetter
                    } else {
                        type = type | JSC.PropertyNode.PrivateGetter
                    }
                } else {
                    type = PropertyType(rawValue: type.rawValue & ~JSC.PropertyNode.Constant.rawValue)
                    type = type | (isGetter ? JSC.PropertyNode.Getter : JSC.PropertyNode.Setter)
                }
                property = parseGetterSetter(&context, type, functionStart, .None, tag, &facade)
                if property.isNull {
                    return fail("Cannot parse this method")
                }
            } else if !match(.openParen) && newParseMode == .MethodMode {
                assert(!isGetter && !isSetter)
                if ident.matches(.constructor, &facade) {
                    return semanticFail("Cannot declare class field named 'constructor'")
                }
                if ident.matches(.constructorPrivateField, &facade) {
                    return semanticFail("Cannot declare private class field named '#constructor'")
                }
                if tag == .Static {
                    if ident.matches(.prototype, &facade) {
                        return semanticFail("Cannot declare a static field named 'prototype'")
                    }
                }

                if !computedPropertyName.isNull {
                    if tag == .Instance {
                        ident = facade.makeComputedFieldPrivateIdentifier(.Instance, nextInstanceComputedFieldID)
                        nextInstanceComputedFieldID &+= 1
                    } else {
                        ident = facade.makeComputedFieldPrivateIdentifier(.Static, nextStaticComputedFieldID)
                        nextStaticComputedFieldID &+= 1
                    }
                    let fieldIdent = ident
                    let declarationResult = withScope(classScope) { $0.declareLexicalVariable(fieldIdent, isConstant: true, &facade) }
                    assert(declarationResult == .valid)
                    withScope(classScope) { $0.useVariable(fieldIdent, isEval: false, &facade) }
                    scopes[classScope.index].addClosedVariableCandidateUnconditionally(ident, &facade)
                }

                var initializer = B.Expression.null
                if consume(.equal, [], &facade) {
                    let usedVariablesSize = scopes[topScope].currentUsedVariablesSize(&facade)
                    scopes[topScope].pushUsedVariableSet(&facade)
                    let savedParsingClassFieldInitializer = parserState.isParsingClassFieldInitializer
                    parserState.isParsingClassFieldInitializer = true
                    defer { parserState.isParsingClassFieldInitializer = savedParsingClassFieldInitializer }
                    let savedMaskAsync = parserState.classFieldInitMasksAsync
                    parserState.classFieldInitMasksAsync = true
                    defer { parserState.classFieldInitMasksAsync = savedMaskAsync }
                    withScope(classScope) { $0.expectedSuperBinding = .Needed }
                    initializer = parseAssignmentExpression(&context, &facade)
                    withScope(classScope) { $0.expectedSuperBinding = .NotNeeded }
                    if initializer.isNull {
                        return fail("Cannot parse initializer for class field")
                    }
                    scopes[classScope.index].markLastUsedVariablesSetAsCaptured(usedVariablesSize, &facade)
                }
                if !autoSemiColon(&facade) {
                    return fail("Expected a ';' following a class field")
                }
                let inferName: JSC.InferName = initializer.isNull ? .Disallowed : .Allowed
                if !computedPropertyName.isNull {
                    property = context.createProperty(&facade, ident, computedPropertyName, initializer, type, .NotNeeded, tag)
                } else {
                    property = context.createProperty(&facade, ident, initializer, type, .NotNeeded, inferName, tag)
                }
            } else if newParseMode == .ClassStaticBlockMode {
                if !match(.openBrace) {
                    return fail("Expected block statement for class static block")
                }
                let usedVariablesSize = scopes[topScope].currentUsedVariablesSize(&facade)
                scopes[topScope].pushUsedVariableSet(&facade)
                let savedStatementDepth = statementDepth
                statementDepth = 0
                defer { statementDepth = savedStatementDepth }
                if parseBlockStatement(&context, .staticBlock, &facade).isNull {
                    return fail("Cannot parse class static block")
                }
                ident = facade.makeClassBuiltinPrivateName(.StaticInitializerBlock)
                property = context.createProperty(&facade, ident, type, .Needed, tag)
                scopes[classScope.index].markLastUsedVariablesSetAsCaptured(usedVariablesSize, &facade)
            } else {
                var methodInfo = FunctionInfo<B>()
                let isConstructor = tag == .Instance && ident.matches(.constructor, &facade)
                if isConstructor && newParseMode != .MethodMode {
                    return semanticFail(
                        ErrorMessage(
                            .text("Cannot declare "),
                            .text(newParseMode.functionKindArticle),
                            .text(newParseMode.functionKindName),
                            .text(" named 'constructor'")
                        )
                    )
                }

                methodInfo.name = isConstructor ? info.className : ident
                let savedParseMode = parseMode
                parseMode = newParseMode
                defer { parseMode = savedParseMode }
                if !parseFunctionInfo(
                    &context,
                    .unnamed,
                    nameIsInContainingScope: false,
                    isConstructor ? constructorKind : .None,
                    .Needed,
                    functionStart,
                    &methodInfo,
                    .method,
                    functionConstructorParametersEndPosition: nil,
                    &facade
                ) {
                    return fail("Cannot parse this method")
                }

                let method = context.createMethodDefinition(&facade, methodLocation, methodInfo)
                if isConstructor {
                    if !constructor.isNull {
                        return semanticFail("Cannot declare multiple constructors in a single class")
                    }
                    constructor = method
                    continue
                }

                if tag == .Static && !methodInfo.name.isNull && methodInfo.name.matches(.prototype, &facade) {
                    return semanticFail("Cannot declare a static method named 'prototype'")
                }

                if !computedPropertyName.isNull {
                    property = context.createProperty(&facade, computedPropertyName, method, type, .Needed, tag)
                } else {
                    property = context.createProperty(&facade, methodInfo.name, method, type, .Needed, .Allowed, tag)
                }
            }

            if !classElementsTail.isNull {
                classElementsTail = context.createPropertyList(&facade, methodLocation, property, classElementsTail)
            } else {
                classElementsTail = context.createPropertyList(&facade, methodLocation, property)
                classElements = classElementsTail
            }
        }

        info.endOffset = tokenLocation.endOffset - 1
        if !consumeOrFail(.closeBrace, "Expected a closing '}' after a class body", &facade) {
            return .null
        }

        if declaresPrivateMethod || declaresPrivateAccessor || declaresStaticPrivateMethod || declaresStaticPrivateAccessor {
            for which in [JSC.JSParseClassBuiltinName.PrivateBrand, JSC.JSParseClassBuiltinName.PrivateClassBrand] {
                let brandIdentifier = facade.makeClassBuiltinPrivateName(which)
                let declarationResult = withScope(classScope) { $0.declareLexicalVariable(brandIdentifier, isConstant: true, &facade) }
                assert(declarationResult == .valid)
                withScope(classScope) { $0.useVariable(brandIdentifier, isEval: false, &facade) }
                scopes[classScope.index].addClosedVariableCandidateUnconditionally(brandIdentifier, &facade)
            }
        }

        if B.createsAST {
            if !classElements.isNull, let node = classElements.parseNode {
                facade.setClassElementsHasPrivateAccessors(node, declaresPrivateAccessor || declaresStaticPrivateAccessor)
            }
        }

        let lexicalEnvironment = popScope(
            classScope,
            shouldTrackClosedVariables: B.needsFreeVariableInfo,
            takeContainers: B.createsAST,
            &facade
        )
        .lexicalVariables
        classScopePopped = true
        let classHeadEnvironment = popScope(
            classHeadScope,
            shouldTrackClosedVariables: B.needsFreeVariableInfo,
            takeContainers: B.createsAST,
            &facade
        )
        .lexicalVariables
        classHeadScopePopped = true
        return context.createClassExpr(
            &facade,
            location,
            info,
            classHeadEnvironment,
            lexicalEnvironment,
            constructor,
            parentClass,
            classElements,
            start,
            divot,
            classHeadEnd
        )
    }

    // MARK: Class field initializers

    mutating func parseClassFieldInitializerSourceElements<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> B.SourceElements {
        let sourceElements = context.createSourceElements(&facade)
        scopes[topScope].setIsClassScope()

        // Clear errors from parsing anything before the initializer expressions.
        lexer.clearErrorCodeAndBuffers()

        let definitionCount = facade.classElementDefinitionCount()
        for index in 0..<definitionCount {
            let position = facade.classElementDefinitionPosition(index)
            let kind = facade.classElementDefinitionKind(index)
            let ident = facade.classElementDefinitionIdentifier(index)

            let statement: B.Statement
            if kind == .StaticInitializationBlock {
                restoreLexerStateForClassFieldInitializer(position, &facade)
                let startLocation = tokenLocation
                let startPosition = tokenStartPosition
                let expressionStart = tokenStart

                assert(match(.reservedIfStrict) && token.data.ident.matches(.staticKeyword, &facade))
                next([], &facade)

                var functionInfo = FunctionInfo<B>()
                functionInfo.name = facade.wellKnownIdentifier(.nullIdentifier)
                let savedParseMode = parseMode
                parseMode = .ClassStaticBlockMode
                defer { parseMode = savedParseMode }
                if !parseFunctionInfo(
                    &context,
                    .none,
                    nameIsInContainingScope: false,
                    .None,
                    .Needed,
                    expressionStart,
                    &functionInfo,
                    .expression,
                    functionConstructorParametersEndPosition: nil,
                    &facade
                ) {
                    return fail("Cannot parse static block function")
                }
                var expression = context.createFunctionExpr(&facade, startLocation, functionInfo)

                expression = context.makeStaticBlockFunctionCallNode(
                    &facade,
                    startLocation,
                    expression,
                    lastTokenEndPosition,
                    startPosition,
                    lastTokenEndPosition
                )
                statement = context.createExprStatement(&facade, startLocation, expression, startPosition)
            } else {
                var location = JSC.JSTokenLocation()
                location.startOffset = UInt32(bitPattern: position)

                var initializer = B.Expression.null
                if let initializerPosition = Optional(fromCxx: facade.classElementDefinitionInitializerPosition(index)) {
                    restoreLexerStateForClassFieldInitializer(initializerPosition, &facade)
                    // parseExpression() is more permissive way to parse AssignmentExpression than parseAssignmentExpression() that is used in parseClass().
                    // This is very intentional: we need to fail for `foo = 1, 2` but support reparsing `foo = (1, 2)`, which is tricky because open paren
                    // is skipped (meaning start offset points to `1`) by parsePrimaryExpression().
                    initializer = parseExpression(&context, &facade)
                    if initializer.isNull {
                        return fail("Cannot parse expression statement")
                    }
                }

                var type = DefineFieldType.Name
                if kind == .FieldWithComputedPropertyKey {
                    type = .ComputedName
                } else if kind == .FieldWithPrivatePropertyKey {
                    type = .PrivateName
                    scopes[topScope].useVariable(ident, isEval: false, &facade)
                }

                statement = context.createDefineField(&facade, location, ident, initializer, type)
            }

            context.appendStatement(&facade, sourceElements, statement)
        }

        assert(!hasError)
        // Trick parseInner() into believing we've parsed the entire SourceCode, in order to prevent it from producing an error.
        token.type = .eof
        return sourceElements
    }

    /// Puts the lexer at offset, with no line terminator before the token, and reads the token there.
    private mutating func restoreLexerStateForClassFieldInitializer(_ offset: Int32, _ facade: inout JSC.JSParseFacade) {
        // setOffset clears lexer errors.
        lexer.setOffset(Int(offset))
        lexer.hasLineTerminatorBeforeToken = false
        lastTokenType = .error
        token.type = .error
        token.startPosition.offset = offset
        token.endPosition.offset = offset
        nextWithoutClearingLineTerminator([], &facade)
    }
}
