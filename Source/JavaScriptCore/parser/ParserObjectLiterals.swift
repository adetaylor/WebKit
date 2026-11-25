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

typealias PropertyType = JSC.PropertyNode.`Type`

extension PropertyType {
    static var constant: Self { JSC.PropertyNode.Constant }
    static var shorthand: Self { JSC.PropertyNode.Shorthand }
    static var computed: Self { JSC.PropertyNode.Computed }
    static var getter: Self { JSC.PropertyNode.Getter }
    static var setter: Self { JSC.PropertyNode.Setter }
    static var privateSetter: Self { JSC.PropertyNode.PrivateSetter }
    static var privateGetter: Self { JSC.PropertyNode.PrivateGetter }
    static var spread: Self { JSC.PropertyNode.Spread }

    static func | (a: Self, b: Self) -> Self {
        Self(rawValue: a.rawValue | b.rawValue)
    }

    func contains(_ other: Self) -> Bool {
        rawValue & other.rawValue != 0
    }
}

extension Parser {
    mutating func parseProperty<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Property {
        var parseModeForProperty = JSC.SourceParseMode.MethodMode
        var wasIdent = false
        var timesPosition: UInt32? = nil
        var asyncPosition: UInt32? = nil

        if match(.times) {
            timesPosition = tokenStart
            next([], &facade)
            parseModeForProperty = .GeneratorWrapperMethodMode
        }

        // Restarts after `async` and `async *`.
        parseLoop: while true {
            var named = false
            switch token.type {
            case .escapedKeyword, .identifier:
                if token.data.ident.matches(.async, &facade) && !token.data.escaped {
                    asyncPosition = tokenStart
                    if parseModeForProperty == .MethodMode {
                        let savePoint = createSavePoint(&context, &facade)
                        next([], &facade)

                        if match(.colon) || match(.openParen) || match(.comma) || match(.closeBrace) {
                            restoreSavePoint(&context, savePoint, &facade)
                            wasIdent = true
                            named = true
                            break
                        }

                        if lexer.hasLineTerminatorBeforeToken {
                            return fail("Expected a property name following keyword 'async'")
                        }
                        if consume(.times, [], &facade) {
                            parseModeForProperty = .AsyncGeneratorWrapperMethodMode
                        } else {
                            parseModeForProperty = .AsyncMethodMode
                        }
                        continue parseLoop
                    }
                }
                wasIdent = true
                named = true
            case .yieldKeyword, .awaitKeyword:
                wasIdent = true
                named = true
            case .string:
                named = true
            case .double, .integer, .bigInt, .openBracket, .dotDotDot:
                break
            default:
                if !token.type.isKeyword {
                    return fail("Expected a property name")
                }
                wasIdent = true // Treat keyword token as an identifier
                named = true
            }

            if named {
                let ident = token.data.ident
                let wasUnescapedIdent = wasIdent && !token.data.escaped
                let getterOrSetterStartOffset = tokenStart
                let functionStart = timesPosition ?? asyncPosition ?? tokenStart
                let identToken = token

                if wasUnescapedIdent && !JSC.isGeneratorMethodParseMode(parseModeForProperty)
                    && (ident.matches(.get, &facade) || ident.matches(.set, &facade))
                {
                    next(.ignoreReservedWords, &facade)
                } else {
                    next(B.dontBuildKeywords.union(.ignoreReservedWords), &facade)
                }

                if !JSC.isGeneratorMethodParseMode(parseModeForProperty) && !JSC.isAsyncMethodParseMode(parseModeForProperty)
                    && match(.colon)
                {
                    next([], &facade)
                    let node = parseAssignmentExpression(&context, &facade)
                    if node.isNull {
                        return fail("Cannot parse expression for property declaration")
                    }
                    context.setEndOffset(&facade, node, Int32(truncatingIfNeeded: lexer.currentOffset))
                    let inferName: JSC.InferName = !ident.isNull && ident.matches(.underscoreProto, &facade) ? .Disallowed : .Allowed
                    return context.createProperty(&facade, ident, node, .constant, .NotNeeded, inferName, .No)
                }

                if match(.openParen) {
                    let savedParseMode = parseMode
                    parseMode = parseModeForProperty
                    defer { parseMode = savedParseMode }
                    let method = parsePropertyMethod(&context, ident, functionStart, &facade)
                    if hasError {
                        return .null
                    }
                    return context.createProperty(&facade, ident, method, .constant, .Needed, .Allowed, .No)
                }
                if parseModeForProperty != .MethodMode {
                    return fail("Expected a parenthesis for argument list")
                }

                if !wasIdent {
                    return fail("Expected an identifier as property name")
                }

                if match(.comma) || match(.closeBrace) {
                    if failDueToKeyword(identToken, "shorthand property name", &facade) {
                        return .null
                    }
                    let start = tokenStartPosition
                    let location = tokenLocation
                    scopes[topScope].useVariable(ident, isEval: ident.matches(.eval, &facade), &facade)
                    let node = context.createResolve(&facade, location, ident, start, lastTokenEndPosition, true)
                    return context.createProperty(
                        &facade,
                        ident,
                        node,
                        .constant | .shorthand,
                        .NotNeeded,
                        .Allowed,
                        .No
                    )
                }

                var type: PropertyType? = nil
                if wasUnescapedIdent {
                    if ident.matches(.get, &facade) {
                        type = .getter
                    } else if ident.matches(.set, &facade) {
                        type = .setter
                    }
                }
                guard let accessorType = type else {
                    return fail(ErrorMessage(.text("Expected a ':' following the property name '"), .identifier(ident), .text("'")))
                }
                return parseGetterSetter(&context, accessorType, getterOrSetterStartOffset, .None, .No, &facade)
            }

            switch token.type {
            case .double, .integer:
                let functionStart = timesPosition ?? asyncPosition ?? tokenStart
                let ident = facade.makeNumericIdentifier(token.data.doubleValue)
                next([], &facade)

                guard let (value, isMethod) = parsePropertyValue(&context, ident, functionStart, parseModeForProperty, &facade) else {
                    return .null
                }
                return context.createProperty(&facade, ident, value, .constant, isMethod ? .Needed : .NotNeeded, .Allowed, .No)
            case .bigInt:
                let ident = facade.makeBigIntDecimalIdentifier(token.data.bigIntString, token.data.radix)
                if ident.isNull {
                    return fail("Cannot parse big int property name")
                }
                let functionStart = timesPosition ?? asyncPosition ?? tokenStart
                next([], &facade)

                guard let (value, isMethod) = parsePropertyValue(&context, ident, functionStart, parseModeForProperty, &facade) else {
                    return .null
                }
                return context.createProperty(&facade, ident, value, .constant, isMethod ? .Needed : .NotNeeded, .Allowed, .No)
            case .openBracket:
                let functionStart = timesPosition ?? asyncPosition ?? tokenStart
                next([], &facade)
                let propertyName = parseAssignmentExpression(&context, &facade)
                if propertyName.isNull {
                    return fail("Cannot parse computed property name")
                }
                if !handleProductionOrFail(.closeBracket, "]", "end", "a computed property name", &facade) {
                    return .null
                }

                guard
                    let (value, isMethod) = parsePropertyValue(
                        &context,
                        facade.wellKnownIdentifier(.nullIdentifier),
                        functionStart,
                        parseModeForProperty,
                        &facade
                    )
                else {
                    return .null
                }
                return context.createProperty(
                    &facade,
                    propertyName,
                    value,
                    .constant | .computed,
                    isMethod ? .Needed : .NotNeeded,
                    .No
                )
            case .dotDotDot:
                let spreadLocation = token.location
                let start = token.startPosition
                let divot = token.endPosition
                next([], &facade)
                let elem = parseAssignmentExpression(&context, &facade)
                if elem.isNull {
                    return fail("Cannot parse subject of a spread operation")
                }
                let node = context.createObjectSpreadExpression(&facade, spreadLocation, elem, start, divot, lastTokenEndPosition)
                return context.createProperty(&facade, node, .spread, .NotNeeded, .No)
            default:
                preconditionFailure()
            }
        }
    }

    /// Parses what follows a property's name that is not a getter, setter, spread or shorthand.
    ///
    /// That is a method's parameter list and body, or ':' and the value. Returns nil with the error set on failure.
    @inline(always)
    private mutating func parsePropertyValue<B: TreeBuilder>(
        _ context: inout B,
        _ methodName: JSC.JSParseIdentifier,
        _ functionStart: UInt32,
        _ parseModeForProperty: JSC.SourceParseMode,
        _ facade: inout JSC.JSParseFacade
    ) -> (value: B.Expression, isMethod: Bool)? {
        if match(.openParen) {
            let savedParseMode = parseMode
            parseMode = parseModeForProperty
            defer { parseMode = savedParseMode }
            let method = parsePropertyMethod(&context, methodName, functionStart, &facade)
            if hasError {
                return nil
            }
            return (method, true)
        }
        if parseModeForProperty != .MethodMode {
            logTokenError("Expected a parenthesis for argument list")
            return nil
        }
        if !consumeOrFail(.colon, "Expected ':' after property name", &facade) {
            return nil
        }
        let node = parseAssignmentExpression(&context, &facade)
        if node.isNull {
            logTokenError("Cannot parse expression for property declaration")
            return nil
        }
        context.setEndOffset(&facade, node, Int32(truncatingIfNeeded: lexer.currentOffset))
        return (node, false)
    }

    mutating func parsePropertyMethod<B: TreeBuilder>(
        _ context: inout B,
        _ methodName: JSC.JSParseIdentifier,
        _ functionStart: UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        assert(JSC.isMethodParseMode(parseMode))
        let methodLocation = tokenLocation
        var methodInfo = FunctionInfo<B>()
        methodInfo.name = methodName
        if !parseFunctionInfo(
            &context,
            .unnamed,
            nameIsInContainingScope: false,
            .None,
            .Needed,
            functionStart,
            &methodInfo,
            .method,
            functionConstructorParametersEndPosition: nil,
            &facade
        ) {
            return fail("Cannot parse this method")
        }
        return context.createMethodDefinition(&facade, methodLocation, methodInfo)
    }

    mutating func parseGetterSetter<B: TreeBuilder>(
        _ context: inout B,
        _ type: JSC.PropertyNode.`Type`,
        _ getterOrSetterStartOffset: UInt32,
        _ constructorKind: JSC.ConstructorKind,
        _ tag: JSC.ClassElementTag,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Property {
        var stringPropertyName = JSC.JSParseIdentifier()
        var numericPropertyName = 0.0
        var computedPropertyName = B.Expression.null

        let location = tokenLocation

        let matchesPrivateName = match(.privateName)
        if matchSpecIdentifier(&facade) || match(.string) || matchesPrivateName || token.type.isKeyword {
            stringPropertyName = token.data.ident
            if tag == .Static && stringPropertyName.matches(.prototype, &facade) {
                return semanticFail("Cannot declare a static method named 'prototype'")
            }
            if tag == .Instance && stringPropertyName.matches(.constructor, &facade) {
                return semanticFail("Cannot declare a getter or setter named 'constructor'")
            }
            if stringPropertyName.matches(.constructorPrivateField, &facade) {
                return semanticFail("Cannot declare a private accessor named '#constructor'")
            }

            if match(.privateName) {
                if tag == .No {
                    return semanticFail("Cannot declare a private setter or getter outside a class")
                }
            }
            next([], &facade)
        } else if match(.double) || match(.integer) {
            numericPropertyName = token.data.doubleValue
            next([], &facade)
        } else if match(.bigInt) {
            stringPropertyName = facade.makeBigIntDecimalIdentifier(token.data.bigIntString, token.data.radix)
            if stringPropertyName.isNull {
                return fail("Cannot parse big int property name")
            }
            next([], &facade)
        } else if consume(.openBracket, [], &facade) {
            computedPropertyName = parseAssignmentExpression(&context, &facade)
            if computedPropertyName.isNull {
                return fail("Cannot parse computed property name")
            }
            if !handleProductionOrFail(.closeBracket, "]", "end", "a computed property name", &facade) {
                return .null
            }
        } else {
            return failDueToUnexpectedToken()
        }

        var info = FunctionInfo<B>()
        let accessorMode: JSC.SourceParseMode?
        let kind: Swift.String
        if type.contains(.getter) {
            accessorMode = .GetterMode
            kind = "getter"
        } else if type.contains(.setter) {
            accessorMode = .SetterMode
            kind = "setter"
        } else if type.contains(.privateSetter) {
            accessorMode = .SetterMode
            kind = "private setter"
        } else if type.contains(.privateGetter) {
            accessorMode = .GetterMode
            kind = "private getter"
        } else {
            accessorMode = nil
            kind = ""
        }
        if let accessorMode {
            if !match(.openParen) {
                return fail(ErrorMessage.text("Expected a parameter list for \(kind) definition"))
            }
            let savedParseMode = parseMode
            parseMode = accessorMode
            defer { parseMode = savedParseMode }
            if !parseFunctionInfo(
                &context,
                .unnamed,
                nameIsInContainingScope: false,
                constructorKind,
                .Needed,
                getterOrSetterStartOffset,
                &info,
                .method,
                functionConstructorParametersEndPosition: nil,
                &facade
            ) {
                return fail(ErrorMessage.text("Cannot parse \(kind) definition"))
            }
        }

        if !stringPropertyName.isNull {
            return context.createGetterOrSetterProperty(&facade, location, type, stringPropertyName, info, tag)
        }

        if !computedPropertyName.isNull {
            return context.createGetterOrSetterProperty(&facade, location, type | .computed, computedPropertyName, info, tag)
        }

        return context.createGetterOrSetterProperty(&facade, location, type, numericPropertyName, info, tag)
    }

    // MARK: Object and array literals

    mutating func parseObjectLiteral<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        let location = tokenLocation
        if !consume(.openBrace, [], &facade) {
            return fail("Expected opening '{' at the start of an object literal")
        }

        let savedNonLHSCount = parserState.nonLHSCount
        defer { parserState.nonLHSCount = savedNonLHSCount }
        if consume(.closeBrace, [], &facade) {
            return context.createObjectLiteral(&facade, location)
        }

        var property = parseProperty(&context, &facade)
        if property.isNull {
            return fail("Cannot parse object literal property")
        }

        var seenProtoSetter = context.isUnderscoreProtoSetter(&facade, property)

        let propertyList = context.createPropertyList(&facade, location, property)
        var tail = propertyList
        while consume(.comma, [], &facade) {
            if match(.closeBrace) {
                break
            }
            let propertyLocation = tokenLocation
            property = parseProperty(&context, &facade)
            if property.isNull {
                return fail("Cannot parse object literal property")
            }
            if context.isUnderscoreProtoSetter(&facade, property) {
                // https://tc39.es/ecma262/#sec-__proto__-property-names-in-object-initializers
                if seenProtoSetter {
                    return semanticFail("Attempted to redefine __proto__ property")
                }
                seenProtoSetter = true
            }
            tail = context.createPropertyList(&facade, propertyLocation, property, tail)
        }

        if !consume(.closeBrace, [], &facade) {
            return fail("Expected '}' to end an object literal")
        }

        return context.createObjectLiteral(&facade, location, propertyList)
    }

    mutating func parseArrayElement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        // Large data tables are mostly literals separated by commas, and a literal directly followed by ',' or ']'
        // is already a complete AssignmentExpression.
        if lexer.nextCharacterIsCommaOrCloseBracket {
            let location = tokenLocation
            switch token.type {
            case .integer:
                let d = token.data.doubleValue
                next([], &facade)
                return context.createIntegerExpr(&facade, location, d)
            case .double:
                let d = token.data.doubleValue
                next([], &facade)
                return context.createDoubleExpr(&facade, location, d)
            case .string:
                let ident = token.data.ident
                next([], &facade)
                return context.createString(&facade, location, ident)
            case .nullKeyword:
                next([], &facade)
                return context.createNull(&facade, location)
            case .trueKeyword:
                next([], &facade)
                return context.createBoolean(&facade, location, true)
            case .falseKeyword:
                next([], &facade)
                return context.createBoolean(&facade, location, false)
            default:
                break
            }
        }
        return parseAssignmentExpression(&context, &facade)
    }

    mutating func parseSimpleArrayElementsAfterComma<B: TreeBuilder>(
        _ context: inout B,
        _ tail: inout B.ElementList,
        _ facade: inout JSC.JSParseFacade
    ) {
        // Leaves the parser in exactly the state that lexing each element and its trailing ',' as tokens would.
        assert(match(.comma))
        var location = JSC.JSTokenLocation()
        var type = JSC.JSTokenType.error
        while true {
            var value = 0.0
            let start = lexer.currentOffset
            let elementType = lexer.scanSimpleArrayElementFollowedByComma(&value, &facade)
            if elementType == .error {
                break
            }
            type = elementType
            location.startOffset = UInt32(truncatingIfNeeded: start)
            location.endOffset = UInt32(truncatingIfNeeded: lexer.currentOffset - 1)
            let element: B.Expression
            switch type {
            case .integer:
                element = context.createIntegerExpr(&facade, location, value)
            case .double:
                element = context.createDoubleExpr(&facade, location, value)
            default:
                assert(type == .nullKeyword)
                element = context.createNull(&facade, location)
            }
            tail = context.createElementList(&facade, tail, 0, element)
        }
        if type == .error {
            return
        }
        lastTokenLocation = location
        lastTokenType = type
        token.startPosition = JSC.JSTextPosition(offset: Int(location.endOffset))
        token.endPosition = JSC.JSTextPosition(offset: Int(location.endOffset) + 1)
    }

    mutating func parseArrayLiteral<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        let location = tokenLocation
        if !consume(.openBracket, B.dontBuildStrings, &facade) {
            return fail("Expected an opening '[' at the beginning of an array literal")
        }

        let savedNonLHSCount = parserState.nonLHSCount
        defer { parserState.nonLHSCount = savedNonLHSCount }

        var elisions: Int32 = 0
        while match(.comma) {
            next(B.dontBuildStrings, &facade)
            elisions += 1
        }
        if consume(.closeBracket, [], &facade) {
            return context.createArray(&facade, location, elisions)
        }

        var elem: B.Expression
        if match(.dotDotDot) {
            let spreadLocation = token.location
            let start = token.startPosition
            let divot = token.endPosition
            next([], &facade)
            let spreadExpr = parseAssignmentExpression(&context, &facade)
            if spreadExpr.isNull {
                return fail("Cannot parse subject of a spread operation")
            }
            elem = context.createSpreadExpression(&facade, spreadLocation, spreadExpr, start, divot, lastTokenEndPosition)
        } else {
            elem = parseArrayElement(&context, &facade)
        }
        if elem.isNull {
            return fail("Cannot parse array literal element")
        }
        let elementList = context.createElementList(&facade, elisions, elem)
        var tail = elementList
        elisions = 0
        while match(.comma) {
            parseSimpleArrayElementsAfterComma(&context, &tail, &facade)
            next(B.dontBuildStrings, &facade)
            elisions = 0

            while consume(.comma, [], &facade) {
                elisions += 1
            }

            if consume(.closeBracket, [], &facade) {
                return context.createArray(&facade, location, elisions, elementList)
            }

            if match(.dotDotDot) {
                let spreadLocation = token.location
                let start = token.startPosition
                let divot = token.endPosition
                next([], &facade)
                let spreadSubject = parseAssignmentExpression(&context, &facade)
                if spreadSubject.isNull {
                    return fail("Cannot parse subject of a spread operation")
                }
                let spread = context.createSpreadExpression(&facade, spreadLocation, spreadSubject, start, divot, lastTokenEndPosition)
                tail = context.createElementList(&facade, tail, elisions, spread)
                continue
            }
            elem = parseArrayElement(&context, &facade)
            if elem.isNull {
                return fail("Cannot parse array literal element")
            }
            tail = context.createElementList(&facade, tail, elisions, elem)
        }

        if !consume(.closeBracket, [], &facade) {
            if !match(.dotDotDot) {
                return fail("Expected either a closing ']' or a ',' following an array element")
            }
            return semanticFail("The '...' operator should come before a target expression")
        }

        return context.createArray(&facade, location, elementList)
    }
}
