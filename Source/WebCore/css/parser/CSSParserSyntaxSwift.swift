// Copyright (C) 2022 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// CSSCustomPropertySyntax's parser: the <syntax> of @property and registerProperty(), and the <css-type> of @function.

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSCalcSwiftTypes
internal import WebCore_Private.Core.CSSCustomPropertySyntax
internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes
internal import WebCore_Private.Core.CSSParserSwiftState

enum CSSParserSyntax {
    // A type position: the nested enum `Type` cannot be named in an expression.
    typealias ComponentType = WebCore.CSSCustomPropertySyntax.`Type`
    typealias Multiplier = WebCore.CSSCustomPropertySyntax.Multiplier

    /// A parsed syntax: its components, how many, and whether one is of an unknown type.
    struct Parsed {
        var definition = WebCore.CSSCustomPropertySyntax.Definition()
        var count = 0
        var containsUnknownType = false
    }

    private static func character(_ state: inout WebCore.CSSParserSwiftState, _ offset: Int) -> UInt16 {
        // Below the text's length, a UInt32.
        state.syntaxTextCharacter(UInt32(truncatingIfNeeded: offset))
    }

    /// `isCSSSpace`.
    private static func isSpace(_ character: UInt16) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A
    }

    private static func skipSpaces(_ state: inout WebCore.CSSParserSwiftState, _ position: inout Int, _ end: Int) {
        while position < end && isSpace(character(&state, position)) {
            position &+= 1 // Below end.
        }
    }

    /// `skipExactly`.
    private static func skip(_ state: inout WebCore.CSSParserSwiftState, _ position: inout Int, _ end: Int, _ expected: UInt16) -> Bool {
        guard position < end && character(&state, position) == expected else {
            return false
        }
        position &+= 1 // Below end.
        return true
    }

    /// `CSSCustomPropertySyntax::parse` of the state's syntax text; nil if it does not parse. The universal syntax has
    /// no components.
    static func parse(_ state: inout WebCore.CSSParserSwiftState) -> Parsed? {
        let end = Int(state.syntaxTextLength())
        var position = 0
        skipSpaces(&state, &position, end)

        if skip(&state, &position, end, 0x2A) { // '*'
            skipSpaces(&state, &position, end)
            if position < end {
                return nil
            }
            return Parsed()
        }

        var parsed = Parsed()
        while position < end {
            let begin = position
            while position < end && character(&state, position) != 0x7C { // '|'
                position &+= 1 // Below end.
            }

            guard let component = parseComponent(&state, begin, position) else {
                return nil
            }
            if component.type.rawValue == ComponentType.Unknown.rawValue {
                parsed.containsUnknownType = true
            }
            parsed.definition.append(consuming: component)
            parsed.count &+= 1 // At most one per code unit.

            if skip(&state, &position, end, 0x7C) { // '|'
                skipSpaces(&state, &position, end)
                if position >= end {
                    return nil
                }
            }
        }

        if parsed.count == 0 {
            return nil
        }
        return parsed
    }

    /// `parseComponent` of the code units [begin, end).
    private static func parseComponent(
        _ state: inout WebCore.CSSParserSwiftState,
        _ begin: Int,
        _ end: Int
    ) -> WebCore.CSSCustomPropertySyntax.Component? {
        var position = begin

        if skip(&state, &position, end, 0x3C) { // '<'
            let nameStart = position
            while position < end && character(&state, position) != 0x3E { // '>'
                position &+= 1 // Below end.
            }
            if position == nameStart {
                return nil
            }
            let nameEnd = position
            if !skip(&state, &position, end, 0x3E) { // '>'
                return nil
            }

            let multiplier = consumeMultiplier(&state, &position, end)

            skipSpaces(&state, &position, end)
            if position < end {
                return nil
            }

            var type = typeForTypeName(&state, nameStart, nameEnd)

            // <transform-list> is a pre-multiplied data type.
            // https://drafts.css-houdini.org/css-properties-values-api/#multipliers
            if type.rawValue == ComponentType.TransformList.rawValue && multiplier.rawValue != Multiplier.Single.rawValue {
                type = .Unknown
            }
            return WebCore.CSSCustomPropertySyntax.Component(type: type, multiplier: multiplier, ident: WTF.AtomString())
        }

        while position < end {
            let character = character(&state, position)
            if character == 0x2B || character == 0x23 { // '+', '#'
                break
            }
            position &+= 1 // Below end.
        }

        // Both below the text's length, a UInt32.
        let ident = state.syntaxIdent(UInt32(truncatingIfNeeded: begin), UInt32(truncatingIfNeeded: position))
        if ident.isNull() {
            return nil
        }

        let multiplier = consumeMultiplier(&state, &position, end)
        return WebCore.CSSCustomPropertySyntax.Component(type: .Ident, multiplier: multiplier, ident: ident)
    }

    private static func consumeMultiplier(_ state: inout WebCore.CSSParserSwiftState, _ position: inout Int, _ end: Int) -> Multiplier {
        if skip(&state, &position, end, 0x2B) { // '+'
            return .SpaceList
        }
        if skip(&state, &position, end, 0x23) { // '#'
            return .CommaList
        }
        return .Single
    }

    /// `typeForTypeName`: the type a data type name names, compared case-sensitively; Unknown for any other.
    private static func typeForTypeName(_ state: inout WebCore.CSSParserSwiftState, _ start: Int, _ end: Int) -> ComponentType {
        if nameEquals(&state, start, end, "angle") { return .Angle }
        if nameEquals(&state, start, end, "color") { return .Color }
        if nameEquals(&state, start, end, "custom-ident") { return .CustomIdent }
        if nameEquals(&state, start, end, "image") { return .Image }
        if nameEquals(&state, start, end, "integer") { return .Integer }
        if nameEquals(&state, start, end, "length") { return .Length }
        if nameEquals(&state, start, end, "length-percentage") { return .LengthPercentage }
        if nameEquals(&state, start, end, "number") { return .Number }
        if nameEquals(&state, start, end, "percentage") { return .Percentage }
        if nameEquals(&state, start, end, "resolution") { return .Resolution }
        if nameEquals(&state, start, end, "string") { return .String }
        if nameEquals(&state, start, end, "time") { return .Time }
        if nameEquals(&state, start, end, "transform-function") { return .TransformFunction }
        if nameEquals(&state, start, end, "transform-list") { return .TransformList }
        if nameEquals(&state, start, end, "url") { return .URL }
        return .Unknown
    }

    private static func nameEquals(_ state: inout WebCore.CSSParserSwiftState, _ start: Int, _ end: Int, _ name: Swift.String) -> Bool {
        let characters = name.utf8
        guard characters.count == end &- start else { // Both at most the text's length.
            return false
        }
        var position = start
        for expected in characters {
            if character(&state, position) != UInt16(expected) {
                return false
            }
            position &+= 1 // Below end.
        }
        return true
    }

    /// Gives the state the syntax `parsed`.
    private static func setSyntax(_ state: inout WebCore.CSSParserSwiftState, _ parsed: consuming Parsed) {
        state.setSyntax(WebCore.CSSCustomPropertySyntax(definition: parsed.definition))
    }

    /// The Syntax request: `CSSCustomPropertySyntax::parse`.
    static func parseSyntax(_ state: inout WebCore.CSSParserSwiftState) {
        if let parsed = parse(&state) {
            setSyntax(&state, parsed)
        }
    }

    /// The SyntaxType request, `CSSCustomPropertySyntax::consumeType`: <css-type> = <syntax-component> | <type()>,
    /// and the number of tokens it took, whether it parsed or not.
    /// https://drafts.csswg.org/css-mixins/#typedef-css-type
    static func consumeType(_ state: inout WebCore.CSSParserSwiftState) {
        var range = CSSParserTokenSpan(index: 0, end: state.count())
        if let parsed = consumeType(&state, &range) {
            setSyntax(&state, parsed)
        }
        // At most the token count.
        state.setResult(UInt32(truncatingIfNeeded: range.index))
    }
}
