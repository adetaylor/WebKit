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

extension Parser {
    // MARK: Class, function and async function expressions

    mutating func parseClassExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.ClassExpression {
        assert(match(.classKeyword))
        let savedNonLHSCount = parserState.nonLHSCount
        defer { parserState.nonLHSCount = savedNonLHSCount }
        var info = ClassInfo()
        info.className = facade.wellKnownIdentifier(.nullIdentifier)
        return parseClass(&context, .none, &info, &facade)
    }

    mutating func parseFunctionExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        assert(match(.functionKeyword))
        let savedNonLHSCount = parserState.nonLHSCount
        defer { parserState.nonLHSCount = savedNonLHSCount }
        let location = tokenLocation
        let functionStart = tokenStart
        next([], &facade)
        var functionInfo = FunctionInfo<B>()
        functionInfo.name = facade.wellKnownIdentifier(.nullIdentifier)
        let newParseMode: JSC.SourceParseMode = consume(.times, [], &facade) ? .GeneratorWrapperFunctionMode : .NormalFunctionMode
        let savedParseMode = parseMode
        parseMode = newParseMode
        defer { parseMode = savedParseMode }

        let constructorKind =
            scopes[topScope].isGlobalCode ? constructorKindForTopLevelFunctionExpressions : JSC.ConstructorKind.None
        let expectedSuperBinding = constructorKind == .Extends ? JSC.SuperBinding.Needed : JSC.SuperBinding.NotNeeded

        if !parseFunctionInfo(
            &context,
            .none,
            nameIsInContainingScope: false,
            constructorKind,
            expectedSuperBinding,
            functionStart,
            &functionInfo,
            .expression,
            functionConstructorParametersEndPosition: nil,
            &facade
        ) {
            return fail("Cannot parse function expression")
        }
        return context.createFunctionExpr(&facade, location, functionInfo)
    }

    mutating func parseAsyncFunctionExpression<B: TreeBuilder>(
        _ context: inout B,
        _ location: JSC.JSTokenLocation,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        assert(match(.functionKeyword))
        next([], &facade)
        let newParseMode: JSC.SourceParseMode = consume(.times, [], &facade) ? .AsyncGeneratorWrapperFunctionMode : .AsyncFunctionMode
        let savedParseMode = parseMode
        parseMode = newParseMode
        defer { parseMode = savedParseMode }

        var functionInfo = FunctionInfo<B>()
        functionInfo.name = facade.wellKnownIdentifier(.nullIdentifier)
        if !parseFunctionInfo(
            &context,
            .none,
            nameIsInContainingScope: false,
            .None,
            .NotNeeded,
            location.startOffset,
            &functionInfo,
            .expression,
            functionConstructorParametersEndPosition: nil,
            &facade
        ) {
            return fail(
                newParseMode == .AsyncFunctionMode
                    ? "Cannot parse async function expression" : "Cannot parse async generator function expression"
            )
        }
        return context.createFunctionExpr(&facade, location, functionInfo)
    }

    // MARK: Template literals

    mutating func parseTemplateString<B: TreeBuilder>(
        _ context: inout B,
        isTemplateHead: Bool,
        _ rawStringsBuildMode: RawStringsBuildMode,
        _ elementIsTail: inout Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> B.TemplateString {
        if isTemplateHead {
            assert(match(.backQuote))
        } else if !match(.closeBrace) {
            return fail("Expected a closing '}' following an expression in template literal")
        }

        // Re-scan the token to recognize it as Template Element.
        token.type = lexer.scanTemplateString(&token, rawStringsBuildMode: rawStringsBuildMode, &facade)
        if !match(.template) {
            return fail("Expected an template element")
        }
        let cooked = token.data.cooked
        let raw = token.data.raw
        elementIsTail = token.data.isTail
        let location = tokenLocation
        next([], &facade)
        return context.createTemplateString(&facade, location, cooked, raw)
    }

    mutating func parseTemplateLiteral<B: TreeBuilder>(
        _ context: inout B,
        _ rawStringsBuildMode: RawStringsBuildMode,
        _ facade: inout JSC.JSParseFacade
    ) -> B.TemplateLiteral {
        assert(match(.backQuote))
        let savedNonLHSCount = parserState.nonLHSCount
        defer { parserState.nonLHSCount = savedNonLHSCount }
        let location = tokenLocation
        var elementIsTail = false

        let headTemplateString = parseTemplateString(&context, isTemplateHead: true, rawStringsBuildMode, &elementIsTail, &facade)
        if headTemplateString.isNull {
            return fail("Cannot parse head template element")
        }

        let templateStringList = context.createTemplateStringList(&facade, headTemplateString)
        var templateStringTail = templateStringList

        if elementIsTail {
            return context.createTemplateLiteral(&facade, location, templateStringList)
        }

        if match(.closeBrace) {
            return fail("Template literal expression cannot be empty")
        }
        let expression = parseExpression(&context, &facade)
        if expression.isNull {
            return fail("Cannot parse expression in template literal")
        }

        let templateExpressionList = context.createTemplateExpressionList(&facade, expression)
        var templateExpressionTail = templateExpressionList

        let templateString = parseTemplateString(&context, isTemplateHead: false, rawStringsBuildMode, &elementIsTail, &facade)
        if templateString.isNull {
            return fail("Cannot parse template element")
        }
        templateStringTail = context.createTemplateStringList(&facade, templateStringTail, templateString)

        while !elementIsTail {
            if match(.closeBrace) {
                return fail("Template literal expression cannot be empty")
            }
            let expression = parseExpression(&context, &facade)
            if expression.isNull {
                return fail("Cannot parse expression in template literal")
            }

            templateExpressionTail = context.createTemplateExpressionList(&facade, templateExpressionTail, expression)

            let templateString = parseTemplateString(&context, isTemplateHead: false, rawStringsBuildMode, &elementIsTail, &facade)
            if templateString.isNull {
                return fail("Cannot parse template element")
            }
            templateStringTail = context.createTemplateStringList(&facade, templateStringTail, templateString)
        }

        return context.createTemplateLiteral(&facade, location, templateStringList, templateExpressionList)
    }

    // MARK: Primary expression

    mutating func createResolveAndUseVariable<B: TreeBuilder>(
        _ context: inout B,
        _ ident: JSC.JSParseIdentifier,
        isEval: Bool,
        _ start: JSC.JSTextPosition,
        _ location: JSC.JSTokenLocation,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        scopes[topScope].useVariable(ident, isEval: isEval, &facade)
        parserState.lastIdentifier = ident
        return context.createResolve(&facade, location, ident, start, lastTokenEndPosition, true)
    }

    mutating func tryParseArgumentsDotLengthForFastPath<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        // There is a fast path for getting `arguments.length` by reading `argumentCountIncludingThis`
        // directly from CallFrame. In that case, no need to materialize `arguments` object. The fast
        // path for `arguments.length` is applied by excluding 'arguments.length` pattern for
        // ArgumentsFeature except for two cases:
        // 1. 'arguments.length` modifications.
        // 2. Function level global variable declaration with identifier `arguments`.
        if context.hasArgumentsFeature(&facade) || !match(.identifier) || !isArgumentsIdentifier(&facade) {
            return .null
        }

        // If semantic checks fail here, then let `parsePrimaryExpression` handle the error thrown.
        // Note that these checks must align to the checks in `parsePrimaryExpression` under
        // the `.identifier` case.
        if scopes[topScope].isStaticBlock || parserState.isParsingClassFieldInitializer
            || scopes[closestScopeOwningArguments().index].evalContextType == .InstanceFieldEvalContext
        {
            return .null
        }

        let argumentsSavePoint = createSavePoint(&context, &facade)
        let primaryStart = tokenStartPosition
        let primaryLocation = tokenLocation
        next([], &facade)
        if match(.dot) {
            let argumentsDotSavePoint = createSavePoint(&context, &facade)
            next([], &facade)
            if match(.identifier) && token.data.ident.matches(.length, &facade) {
                seenArgumentsDotLength = true

                let argumentsIdentifier = facade.wellKnownIdentifier(.arguments)
                scopes[topScope].useVariable(argumentsIdentifier, isEval: false, &facade)
                parserState.lastIdentifier = argumentsIdentifier

                let argumentsDotExpression = context.createResolve(
                    &facade,
                    primaryLocation,
                    argumentsIdentifier,
                    primaryStart,
                    lastTokenEndPosition,
                    false
                )
                restoreSavePoint(&context, argumentsDotSavePoint, &facade)
                return argumentsDotExpression
            }
        }
        restoreSavePoint(&context, argumentsSavePoint, &facade)
        return .null
    }

    private mutating func parseIdentifierExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        let start = tokenStartPosition
        let ident = token.data.ident
        if ident.matches(.arguments, &facade) {
            if scopes[closestScopeOwningArguments().index].evalContextType == .InstanceFieldEvalContext {
                return fail("arguments is not valid in this context")
            }
        }
        let location = tokenLocation
        next([], &facade)

        // Avoid using variable if it is an arrow function parameter
        if match(.arrowFunction) {
            return .null
        }

        return createResolveAndUseVariable(&context, ident, isEval: ident.matches(.eval, &facade), start, location, &facade)
    }

    mutating func parsePrimaryExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }
        switch token.type {
        case .functionKeyword:
            return parseFunctionExpression(&context, &facade)
        case .classKeyword:
            return parseClassExpression(&context, &facade)
        case .openBrace:
            return parseObjectLiteral(&context, &facade)
        case .openBracket:
            return parseArrayLiteral(&context, &facade)
        case .openParen:
            next([], &facade)
            let savedNonLHSCount = parserState.nonLHSCount
            defer { parserState.nonLHSCount = savedNonLHSCount }
            let result = parseExpression(&context, &facade)
            if !consume(.closeParen, [], &facade) {
                return fail("Expected ')' to end a compound expression")
            }
            if !result.isNull {
                context.setIsParenthesized(&facade, result)
            }
            return result
        case .thisKeyword:
            let location = tokenLocation
            next([], &facade)
            if scopes[topScope].isArrowFunction {
                scopes[topScope].setInnerArrowFunctionUsesThis()
            }
            return context.createThisExpr(&facade, location)
        case .awaitKeyword:
            if scopes[topScope].isStaticBlock {
                return semanticFail("The 'await' keyword is disallowed in the IdentifierReference position within static block")
            }
            if parserState.functionParsePhase == .parameters {
                if !parserState.allowAwait {
                    return semanticFail("Cannot use 'await' within a parameter default expression")
                }
            } else if !parserState.classFieldInitMasksAsync
                && (scopes[currentFunctionScope().index].isAsyncFunctionBoundary || isModuleParseMode)
            {
                return parseAwaitExpression(&context, &facade)
            }

            if scriptMode == .Module {
                return semanticFail("Cannot use 'await' as an identifier in a module")
            }
            return parseIdentifierExpression(&context, &facade)
        case .identifier:
            if scopes[topScope].isStaticBlock && isArgumentsIdentifier(&facade) {
                return semanticFail("Cannot use 'arguments' as an identifier in static block")
            }
            if token.data.ident.matches(.async, &facade) && !token.data.escaped {
                let functionStart = tokenStartPosition
                let ident = token.data.ident
                let location = tokenLocation
                next([], &facade)
                if match(.functionKeyword) && !lexer.hasLineTerminatorBeforeToken {
                    return parseAsyncFunctionExpression(&context, location, &facade)
                }

                // Avoid using variable if it is an arrow function parameter
                if match(.arrowFunction) {
                    return .null
                }

                return createResolveAndUseVariable(&context, ident, isEval: false, functionStart, location, &facade)
            }
            if parserState.isParsingClassFieldInitializer {
                if isArgumentsIdentifier(&facade) {
                    return fail("Cannot reference 'arguments' in class field initializer")
                }
            }
            return parseIdentifierExpression(&context, &facade)
        case .bigInt:
            let ident = token.data.bigIntString
            let radix = token.data.radix
            let location = tokenLocation
            next([], &facade)
            return context.createBigInt(&facade, location, ident, radix)
        case .string:
            let ident = token.data.ident
            let location = tokenLocation
            next([], &facade)
            return context.createString(&facade, location, ident)
        case .double:
            let d = token.data.doubleValue
            let location = tokenLocation
            next([], &facade)
            return context.createDoubleExpr(&facade, location, d)
        case .integer:
            let d = token.data.doubleValue
            let location = tokenLocation
            next([], &facade)
            return context.createIntegerExpr(&facade, location, d)
        case .nullKeyword:
            let location = tokenLocation
            next([], &facade)
            return context.createNull(&facade, location)
        case .trueKeyword:
            let location = tokenLocation
            next([], &facade)
            return context.createBoolean(&facade, location, true)
        case .falseKeyword:
            let location = tokenLocation
            next([], &facade)
            return context.createBoolean(&facade, location, false)
        case .divEqual, .divide:
            // regexp
            if match(.divEqual) {
                token.type = lexer.scanRegExp(&token, patternPrefix: UInt16(UInt8(ascii: "=")), &facade)
            } else {
                token.type = lexer.scanRegExp(&token, patternPrefix: 0, &facade)
            }
            if !match(.regExp) {
                return fail("Invalid regular expression")
            }

            let pattern = token.data.pattern
            let flags = token.data.flags
            let start = tokenStartPosition
            let location = tokenLocation
            next([], &facade)
            // RegExpCache only holds patterns that compiled successfully.
            let skipSyntaxCheck = lexer.isReparsingFunction || facade.isRegularExpressionCached(pattern, flags)
            let re = context.createRegExp(&facade, location, pattern, flags, start, skipSyntaxCheck)
            if re.isNull {
                let errorCode = facade.checkRegularExpressionSyntax(pattern, flags)
                setErrorMessage(ErrorMessage([.regularExpressionError(errorCode)]))
                return .null
            }
            return re
        case .backQuote:
            return parseTemplateLiteral(&context, .dontBuildRawStrings, &facade)
        case .yieldKeyword:
            if canUseIdentifierYield {
                return parseIdentifierExpression(&context, &facade)
            }
            return failDueToUnexpectedToken()
        case .letKeyword:
            if !strictMode {
                return parseIdentifierExpression(&context, &facade)
            }
            return failDueToUnexpectedToken()
        case .escapedKeyword:
            if matchAllowedEscapedContextualKeyword(&facade) {
                return parseIdentifierExpression(&context, &facade)
            }
            return failDueToUnexpectedToken()
        default:
            return failDueToUnexpectedToken()
        }
    }

    // MARK: Arguments

    mutating func parseArguments<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Arguments {
        if !consume(.openParen, B.dontBuildStrings, &facade) {
            return fail("Expected opening '(' at start of argument list")
        }
        let location = tokenLocation
        if match(.closeParen) {
            next([], &facade)
            return context.createArguments(&facade)
        }
        let argumentsStart = token.startPosition
        let argumentsDivot = token.endPosition

        let initialAssignments = parserState.assignmentCount
        let (firstArg, firstArgType) = parseArgument(&context, &facade)
        if firstArg.isNull {
            return fail("Cannot parse function argument")
        }
        if match(.dotDotDot) {
            return semanticFail("The '...' operator should come before the target expression")
        }

        var hasSpread = firstArgType == .spread
        let argList = context.createArgumentsList(&facade, location, firstArg)
        var tail = argList

        while match(.comma) {
            let argumentLocation = tokenLocation
            next(B.dontBuildStrings, &facade)

            if match(.closeParen) {
                break
            }

            let (arg, argType) = parseArgument(&context, &facade)
            if hasError {
                return .null
            }
            if match(.dotDotDot) {
                return semanticFail("The '...' operator should come before the target expression")
            }

            if argType == .spread {
                hasSpread = true
            }

            tail = context.createArgumentsList(&facade, argumentLocation, tail, arg)
        }

        if !consume(.closeParen, [], &facade) {
            return fail("Expected ')' to end an argument list")
        }
        if hasSpread {
            let elementList = context.createElementList(&facade, argList)
            let array = context.createArray(&facade, location, elementList)
            let spreadArray = context.createSpreadExpression(
                &facade,
                location,
                array,
                argumentsStart,
                argumentsDivot,
                lastTokenEndPosition
            )
            let spreadList = context.createArgumentsList(&facade, location, spreadArray)
            return context.createArguments(&facade, spreadList, initialAssignments != parserState.assignmentCount)
        }

        return context.createArguments(&facade, argList, initialAssignments != parserState.assignmentCount)
    }

    mutating func parseArgument<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> (expression: B.Expression, type: ArgumentType) {
        if match(.dotDotDot) {
            let spreadLocation = tokenLocation
            let start = token.startPosition
            let divot = token.endPosition
            next([], &facade)
            let spreadExpr = parseAssignmentExpression(&context, &facade)
            if hasError {
                return (.null, .spread)
            }
            let end = lastTokenEndPosition
            return (context.createSpreadExpression(&facade, spreadLocation, spreadExpr, start, divot, end), .spread)
        }

        return (parseAssignmentExpression(&context, &facade), .normal)
    }
}
