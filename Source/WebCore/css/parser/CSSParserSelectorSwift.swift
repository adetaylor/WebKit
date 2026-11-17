// Copyright 2014-2017 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2020 Apple Inc. All rights reserved.
// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
// Copyright (C) 2003 Lars Knoll (knoll@kde.org)
// Copyright (C) 2004, 2005, 2006, 2008, 2014 Apple Inc. All rights reserved.
// Copyright (C) 1999-2003 Lars Knoll (knoll@kde.org)
//               1999 Waldo Bastian (bastian@kde.org)
//               2001 Andreas Schlapbach (schlpbch@iam.unibe.ch)
//               2001-2003 Dirk Mueller (mueller@kde.org)
// Copyright (C) 2002-2026 Apple Inc. All rights reserved.
// Copyright (C) 2008 David Smith (catfish.man@gmail.com)
// Copyright (C) 2010 Google Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.

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
internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSParserIdioms
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes
internal import WebCore_Private.Core.CSSParserSwiftState
internal import WebCore_Private.Core.CSSSelector

// The selector parser: selector lists (complex, compound, relative, forgiving, nested), simple selectors,
// pseudo-classes and pseudo-elements with their arguments, An+B, namespaces, the implicit :scope and &, and the
// implicit shadow-crossing combinators. It reads the tokens of a CSSParserSwiftState by index and parses into a
// CSSParserSelectorArena: simple selectors linked by index in the order a MutableCSSSelector chain links them, so
// every chain operation of MutableCSSSelector (prepending in a complex selector, appending the type selector, splitting
// a compound at a shadow-crossing combinator) is the same operation on indices. A finished list is written into a
// CSSSelectorListStorage, which becomes the parse's CSSSelectorList.

// MARK: - Imported constants

/// CSSParserTokenType values, as CSSParserSwiftTokenReader's type() returns them.
private enum CSSParserSelectorTokenType {
    static var ident: UInt8 { UInt8(WebCore.IdentToken.rawValue) }
    static var function: UInt8 { UInt8(WebCore.FunctionToken.rawValue) }
    static var hash: UInt8 { UInt8(WebCore.HashToken.rawValue) }
    static var delimiter: UInt8 { UInt8(WebCore.DelimiterToken.rawValue) }
    static var number: UInt8 { UInt8(WebCore.NumberToken.rawValue) }
    static var dimension: UInt8 { UInt8(WebCore.DimensionToken.rawValue) }
    static var includeMatch: UInt8 { UInt8(WebCore.IncludeMatchToken.rawValue) }
    static var dashMatch: UInt8 { UInt8(WebCore.DashMatchToken.rawValue) }
    static var prefixMatch: UInt8 { UInt8(WebCore.PrefixMatchToken.rawValue) }
    static var suffixMatch: UInt8 { UInt8(WebCore.SuffixMatchToken.rawValue) }
    static var substringMatch: UInt8 { UInt8(WebCore.SubstringMatchToken.rawValue) }
    static var colon: UInt8 { UInt8(WebCore.ColonToken.rawValue) }
    static var comma: UInt8 { UInt8(WebCore.CommaToken.rawValue) }
    static var leftBracket: UInt8 { UInt8(WebCore.LeftBracketToken.rawValue) }
    static var string: UInt8 { UInt8(WebCore.StringToken.rawValue) }
    static var eof: UInt8 { UInt8(WebCore.EOFToken.rawValue) }
    static var blockStart: UInt8 { UInt8(WebCore.CSSParserToken.BlockStart.rawValue) }
    static var blockEnd: UInt8 { UInt8(WebCore.CSSParserToken.BlockEnd.rawValue) }

    /// What CSSParserTokenCursor.peekKind returns for delimiter token `character`.
    static func delimiterKind(_ character: UInt16) -> UInt32 { UInt32(delimiter) | UInt32(character) &<< 8 }

    /// `CSSTokenizer::isWhitespace`.
    static func isWhitespace(_ type: UInt8) -> Bool {
        type == UInt8(WebCore.NonNewlineWhitespaceToken.rawValue) || type == UInt8(WebCore.NewlineToken.rawValue)
    }
}

typealias CSSParserSelectorMatch = WebCore.CSSSelector.Match
typealias CSSParserSelectorRelation = WebCore.CSSSelector.Relation
typealias CSSParserPseudoClass = WebCore.CSSSelectorPseudoClass
typealias CSSParserPseudoElement = WebCore.CSSSelectorPseudoElement

/// CSSSelector::pseudoElementRequiresArgument or pseudoClassRequiresArgument of a pseudo-element or pseudo-class the
/// parser's lookups found.
private func cssParserPseudoRequiresArgument(_ isPseudoElement: Bool, _ pseudo: UInt8) -> Bool {
    // An imported C++ enum's init(rawValue:) does not check its value; the lookups have a default case.
    if isPseudoElement {
        guard let pseudoElement = CSSParserPseudoElement(rawValue: pseudo) else { return false }
        return WebCore.CSSSelector.pseudoElementRequiresArgument(pseudoElement)
    }
    guard let pseudoClass = CSSParserPseudoClass(rawValue: pseudo) else { return false }
    return WebCore.CSSSelector.pseudoClassRequiresArgument(pseudoClass)
}

/// `NumericSign`, as `numericSign()` returns it.
private enum CSSParserNumericSign {
    static var none: UInt8 { UInt8(WebCore.NoSign.rawValue) }
    static var plus: UInt8 { UInt8(WebCore.PlusSign.rawValue) }
    static var minus: UInt8 { UInt8(WebCore.MinusSign.rawValue) }
}

// MARK: - The token cursor

/// A `CSSParserTokenRange` as indices into the state's tokens: the next token and the end of the range. A sub-range
/// (`consumeBlock`, `rangeUntil`) is a new cursor, never a copy of tokens.
struct CSSParserTokenCursor {
    var index: Int
    var end: Int

    init(_ index: Int, _ end: Int) {
        self.index = index
        self.end = end
    }

    var atEnd: Bool { index >= end }

    /// `peek(offset).type()`: past the end, an EOF token's.
    func peekType(_ state: inout WebCore.CSSParserSwiftState, _ offset: Int = 0) -> UInt8 {
        // index and end are at most the token count, which runOnTokens checks is below UInt32.max.
        let i = index &+ offset
        return i < end ? state.type(i) : CSSParserSelectorTokenType.eof
    }

    /// `peek(offset).type()`, and a delimiter token's character above it (CSSParserSwiftState::typeAndDelimiter): one
    /// read for a dispatch on both.
    func peekKind(_ state: inout WebCore.CSSParserSwiftState, _ offset: Int = 0) -> UInt32 {
        let i = index &+ offset
        return i < end ? state.typeAndDelimiter(i) : UInt32(CSSParserSelectorTokenType.eof)
    }

    /// `peek().delimiter()` of a delimiter token, else 0.
    func peekDelimiter(_ state: inout WebCore.CSSParserSwiftState, _ offset: Int = 0) -> UInt16 {
        let i = index &+ offset
        return i < end ? state.delimiter(i) : 0
    }

    /// `consume()`: the index of the token consumed, or nil at the end, where CSSParserTokenRange returns the EOF token
    /// and does not move.
    @discardableResult
    mutating func consume() -> Int? {
        guard index < end else { return nil }
        let token = index
        index &+= 1 // Below end.
        return token
    }

    /// `consumeIncludingWhitespace()`.
    @discardableResult
    mutating func consumeIncludingWhitespace(_ state: inout WebCore.CSSParserSwiftState) -> Int? {
        let token = consume()
        consumeWhitespace(&state)
        return token
    }

    /// `consumeWhitespace()`.
    mutating func consumeWhitespace(_ state: inout WebCore.CSSParserSwiftState) {
        while index < end && CSSParserSelectorTokenType.isWhitespace(state.type(index)) {
            index &+= 1 // Below end.
        }
    }

    /// `consumeBlock()` at a token that starts a block: the block's contents. A block left open runs to the end.
    mutating func consumeBlock(_ state: inout WebCore.CSSParserSwiftState) -> CSSParserTokenCursor {
        let start = index &+ 1 // index is below end, at the block's start.
        // CSSParserTokenRange::consumeBlock's counter is unsigned: an unmatched block end wraps it, as here.
        var nestingLevel: UInt32 = 0
        repeat {
            let token = consume()
            let blockType = token.map { state.blockType($0) } ?? 0
            if blockType == CSSParserSelectorTokenType.blockStart {
                nestingLevel &+= 1
            } else if blockType == CSSParserSelectorTokenType.blockEnd {
                nestingLevel &-= 1
            }
        } while nestingLevel != 0 && index < end
        return CSSParserTokenCursor(start, nestingLevel != 0 ? index : index &- 1)
    }

    /// `consumeComponentValue()`.
    mutating func consumeComponentValue(_ state: inout WebCore.CSSParserSwiftState) {
        var nestingLevel: UInt32 = 0 // Unsigned, as in CSSParserTokenRange: an unmatched block end wraps it.
        repeat {
            let token = consume()
            let blockType = token.map { state.blockType($0) } ?? 0
            if blockType == CSSParserSelectorTokenType.blockStart {
                nestingLevel &+= 1
            } else if blockType == CSSParserSelectorTokenType.blockEnd {
                nestingLevel &-= 1
            }
        } while nestingLevel != 0 && index < end
    }

    /// `atEndIgnoringWhitespace(range)`, on a copy.
    func atEndIgnoringWhitespace(_ state: inout WebCore.CSSParserSwiftState) -> Bool {
        var copy = self
        copy.consumeWhitespace(&state)
        return copy.atEnd
    }
}

// MARK: - Token text

/// Whether the value of token `token` (`CSSParserSwiftState::valueLength`'s text) equals `letters`, compared ASCII
/// case-insensitively: `equalLettersIgnoringASCIICase`, whose `letters` are lowercase.
@inline(always)
private func cssParserValueEqualsLetters(_ state: inout WebCore.CSSParserSwiftState, _ token: Int, _ letters: Swift.String) -> Bool {
    let length = state.valueLength(token)
    // The letters are a short ASCII literal; a token's value is shorter than UInt32.max.
    guard Int(length) == letters.utf8.count else { return false }
    var offset: UInt32 = 0
    for expected in letters.utf8 {
        // toASCIILower of the code unit: only A to Z change.
        var character = state.valueCharacter(token, offset)
        if character >= 0x41 && character <= 0x5A {
            character |= 0x20
        }
        guard character == UInt16(expected) else { return false }
        offset &+= 1 // Below length, a UInt32.
    }
    return true
}

/// Which of the user agent part names (UserAgentParts, from CSSPseudoSelectors.json) the selector parser compares a
/// pseudo-element's value with it is, ASCII case-insensitively (equalIgnoringASCIICase).
enum CSSParserUserAgentPart {
    case other, detailsContent, fileSelectorButton, placeholder, webkitMediaTextTrackDisplay
}

private func cssParserUserAgentPart(_ s: inout WebCore.CSSParserSwiftState, _ token: Int) -> CSSParserUserAgentPart {
    if cssParserValueEqualsLetters(&s, token, "details-content") { return .detailsContent }
    if cssParserValueEqualsLetters(&s, token, "file-selector-button") { return .fileSelectorButton }
    if cssParserValueEqualsLetters(&s, token, "placeholder") { return .placeholder }
    // UserAgentParts::webkitMediaTextTrackDisplay() exists under ENABLE(VIDEO), as ::cue does.
    if WebCore.CSSParserSwiftCuePseudoElement != WebCore.CSSParserSwiftNoPseudoElement
        && cssParserValueEqualsLetters(&s, token, "-webkit-media-text-track-display")
    {
        return .webkitMediaTextTrackDisplay
    }
    return .other
}

/// `clampTo<int>(double)`: `INT_MAX` at or above it, `INT_MIN` at or below it and for NaN, else truncated.
func cssParserClampToInt32(_ value: Double) -> Int32 {
    if value >= Double(Int32.max) {
        return Int32.max
    }
    if !(value > Double(Int32.min)) {
        return Int32.min
    }
    // Strictly between INT_MIN and INT_MAX, so the conversion is exact after truncation and never traps.
    return Int32(value)
}

// MARK: - The selector value

/// One simple selector: a MutableCSSSelector, with its link to the simple selector before it in its complex
/// selector, its argument selector list and its argument list of atoms, identifiers or integers.
struct CSSParserSelectorNode {
    /// The record's fields: match, relation, pseudo type, attribute match type, flags and argument list kind.
    var fields = WebCore.CSSSelectorFields()
    /// What the state makes its atoms and name from: tokens and atom kinds, a and b.
    var parts = CSSParserSelectorParts()
    /// MutableCSSSelector::precedingInComplexSelector(), or -1.
    var preceding: Int32 = -1
    /// The argument selector list (setSelectorList, adoptSelectorVector), an index into the arena's lists, or -1.
    var selectorList: Int32 = -1
    /// The argument atoms, identifiers or integers (setStringList, setLangList, setIntegerList): a range of the
    /// arena's list items.
    var itemsStart: Int32 = 0
    var itemsEnd: Int32 = 0
    /// For a UserAgentPart pseudo-element, which of the names the parser compares its value with it has.
    var userAgentPart = CSSParserUserAgentPart.other
    /// The next complex selector of the list this one heads, or -1.
    var nextInList: Int32 = -1

    var match: UInt8 { fields.match }
    var pseudo: UInt8 { fields.pseudoType }
    var relation: UInt8 {
        get { fields.relation }
        set { fields.relation = newValue }
    }
}

extension CSSParserSelectorNode {
    /// The arena's filler for its inline nodes past its count, which are never read: every field zero.
    static var zeroFiller: CSSParserSelectorNode {
        var node = CSSParserSelectorNode()
        node.fields.relation = 0
        node.parts.nameToken = 0
        node.parts.prefixToken = 0
        node.parts.valueToken = 0
        node.parts.argumentToken = 0
        node.preceding = 0
        node.selectorList = 0
        node.nextInList = 0
        return node
    }
}

/// A simple selector's tokens and atom kinds, from which the state makes its value, argument and name atoms.
struct CSSParserSelectorParts {
    var nameToken = UInt32.max // a type or attribute selector's local name
    var prefixToken = UInt32.max // its namespace prefix, for CSSParserSwiftNamespace.Prefix
    var valueToken = UInt32.max // the value (id, class, attribute value, pseudo-element name); a range start
    var valueEnd: UInt32 = 0 // the range end, for CSSParserSwiftAtom.SerializedRange
    var argumentToken = UInt32.max // setArgument's token
    var a: Int32 = 0 // setNth's a and b, clamped as consumeANPlusB clamps them
    var b: Int32 = 0
    var nameAtom = WebCore.CSSParserSwiftAtom.None
    var valueAtom = WebCore.CSSParserSwiftAtom.None
    var argumentAtom = WebCore.CSSParserSwiftAtom.None
    var namespaceKind = WebCore.CSSParserSwiftNamespace.Default
    /// m_ignoreDefaultNamespace when the name was parsed, and whether it resolves against the request's style sheet.
    var ignoreDefaultNamespace = false
    var withStyleSheet = false
}

/// CSSSelectorFields' flags.
enum CSSParserSelectorFlag {
    static var continuesComplexSelector: UInt16 { UInt16(WebCore.CSSSelectorFields.ContinuesComplexSelector.rawValue) }
    static var matchLowerCase: UInt16 { UInt16(WebCore.CSSSelectorFields.MatchLowerCase.rawValue) }
    static var implicit: UInt16 { UInt16(WebCore.CSSSelectorFields.Implicit.rawValue) }
    static var forPage: UInt16 { UInt16(WebCore.CSSSelectorFields.ForPage.rawValue) }
    static var tagIsForNamespaceRule: UInt16 { UInt16(WebCore.CSSSelectorFields.TagIsForNamespaceRule.rawValue) }
    static var equivalentToClass: UInt16 { UInt16(WebCore.CSSSelectorFields.EquivalentToClass.rawValue) }
}

/// What an argument list item is.
enum CSSParserSelectorListItemKind {
    case atom, identifier, quotedIdentifier, integer
}

/// An item of setStringList, setLangList or setIntegerList.
struct CSSParserSelectorListItem {
    var token: UInt32
    var atom: WebCore.CSSParserSwiftAtom
    var kind: CSSParserSelectorListItemKind
    var integer: Int32
}

/// A MutableCSSSelectorList: its first complex selector's head and its size.
struct CSSParserSelectorListRange {
    var first: Int32
    var count: Int32
}

/// A list whose first `inlineCapacity` elements are stored in the value, and the rest in a UniqueArray (the spill), so
/// that a small parse makes no heap allocation. Its readers are `mutating`: reading an InlineArray through a borrowed
/// value copies the whole array per access, through an inout one reads the element in place. Indices below
/// `inlineLimit` are inline: `inlineCapacity`, or 0 once every element is in the spill (moveToSpill).
struct CSSParserSelectorChunkedArray<let inlineCapacity: Int, Element>: ~Copyable {
    private var head: [inlineCapacity of Element]
    var spill = UniqueArray<Element>()
    private(set) var count = 0
    private var inlineLimit = inlineCapacity
    /// The capacity the spill reserves when it takes its first element.
    private var spillReserve = 0

    /// `filler` fills the inline elements past `count`, which are never read: an all-zero one makes the init wide zero
    /// stores.
    @inline(always)
    init(_ filler: Element) {
        head = .init(repeating: filler)
    }

    /// Reads only: a write goes through update, in place.
    subscript(_ index: Int) -> Element {
        mutating get {
            precondition(index >= 0 && index < count)
            return index < inlineLimit ? head[index] : spill[index &- inlineLimit] // index is at least inlineLimit.
        }
    }

    /// `body` on element `index` in place (the InlineArray's and the UniqueArray's subscripts are addressors), not on
    /// a copy written back whole.
    @inline(always)
    mutating func update<R>(_ index: Int, _ body: (inout Element) -> R) -> R {
        precondition(index >= 0 && index < count)
        if index < inlineLimit {
            return body(&head[index])
        }
        return body(&spill[index &- inlineLimit]) // index is at least inlineLimit.
    }

    @inline(always)
    mutating func append(_ element: Element) {
        if count < inlineLimit {
            head[count] = element
        } else {
            appendToSpill(element)
        }
        count &+= 1 // The arena's callers keep the count below Int32.max.
    }

    /// Appends `initial()` with `body` applied: on the inline path built in its slot, not on the stack and copied.
    @inline(always)
    mutating func append(_ initial: () -> Element, _ body: (inout Element) -> Void) {
        if count < inlineLimit {
            head[count] = initial()
            body(&head[count])
        } else {
            var element = initial()
            body(&element)
            appendToSpill(element)
        }
        count &+= 1 // The arena's callers keep the count below Int32.max.
    }

    @inline(never)
    private mutating func appendToSpill(_ element: Element) {
        if spill.isEmpty {
            spill.reserveCapacity(spillReserve)
        }
        spill.append(element)
    }

    /// Empties the list, keeping the spill's storage; `capacity` elements in all are reserved when the spill is first
    /// used.
    mutating func removeAll(reservingCapacity capacity: Int) {
        spill.removeAll()
        count = 0
        inlineLimit = inlineCapacity
        spillReserve = capacity > inlineCapacity ? capacity &- inlineCapacity : 0 // capacity is above inlineCapacity.
    }

    /// Moves the inline elements to the front of the spill, so the spill holds the list.
    mutating func moveToSpill() {
        guard inlineLimit != 0 else { return }
        var elements = UniqueArray<Element>()
        elements.reserveCapacity(count)
        var index = 0
        while index < count {
            elements.append(self[index])
            index &+= 1 // Below count.
        }
        spill = elements
        inlineLimit = 0
    }

    /// The list of the elements of `spill`, none inline.
    init(_ filler: Element, adopting spill: consuming UniqueArray<Element>) {
        head = .init(repeating: filler)
        count = spill.count
        self.spill = spill
        inlineLimit = 0
    }
}

/// The heap storage of a CSSParserSelectorArena, which a caller that parses many selector lists keeps between them
/// (the rule parser, for each style rule prelude), or which holds a parsed list whole (@scope's).
struct CSSParserSelectorArenaStorage: ~Copyable {
    var nodes = UniqueArray<CSSParserSelectorNode>()
    var lists = UniqueArray<CSSParserSelectorListRange>()
    var items = UniqueArray<CSSParserSelectorListItem>()
    /// For a storage that holds a list whole: CSSParserSelectorArena.mayHaveUnlinkedNodes.
    var mayHaveUnlinkedNodes = false

    init() {}
}

/// Every simple selector, list and list item of one parser's work, indexed by Int32 (a parse has far fewer than
/// 2^31 of each: at most a few per token, and the token count is below UInt32.max; see appendNode). The first 16
/// nodes, 4 lists and 4 items are inline, which most selector lists fit in.
struct CSSParserSelectorArena: ~Copyable {
    var nodes = CSSParserSelectorChunkedArray<16, CSSParserSelectorNode>(CSSParserSelectorNode.zeroFiller)
    var lists = CSSParserSelectorChunkedArray<4, CSSParserSelectorListRange>(CSSParserSelectorArena.zeroListFiller)
    var items = CSSParserSelectorChunkedArray<4, CSSParserSelectorListItem>(CSSParserSelectorArena.zeroItemFiller)
    /// Whether a node may be in no list: a forgiving list dropped a selector, or a nested complex selector that failed
    /// was parsed again as a relative one. Without it, and with one list, every node is one of the list's records.
    var mayHaveUnlinkedNodes = false

    /// The fillers of the inline lists and items past their counts, which are never read: every field zero.
    static var zeroListFiller: CSSParserSelectorListRange { CSSParserSelectorListRange(first: 0, count: 0) }
    static var zeroItemFiller: CSSParserSelectorListItem { CSSParserSelectorListItem(token: 0, atom: .None, kind: .atom, integer: 0) }

    /// Always inlined: the arena is built where its parser is, not copied there.
    @inline(always)
    init() {}

    /// The arena of the list held whole in `storage` (takeStorage).
    init(adopting storage: consuming CSSParserSelectorArenaStorage) {
        mayHaveUnlinkedNodes = storage.mayHaveUnlinkedNodes
        nodes = CSSParserSelectorChunkedArray(CSSParserSelectorNode.zeroFiller, adopting: storage.nodes)
        lists = CSSParserSelectorChunkedArray(CSSParserSelectorArena.zeroListFiller, adopting: storage.lists)
        items = CSSParserSelectorChunkedArray(CSSParserSelectorArena.zeroItemFiller, adopting: storage.items)
    }

    /// Exchanges the spills with `storage`'s, the storage a caller keeps between parses.
    mutating func swapSpills(_ storage: inout CSSParserSelectorArenaStorage) {
        swap(&nodes.spill, &storage.nodes)
        swap(&lists.spill, &storage.lists)
        swap(&items.spill, &storage.items)
    }

    /// The arena's lists whole, in a storage off the stack, for a list built later (@scope's, after its body).
    mutating func takeStorage() -> CSSParserSelectorArenaStorage {
        nodes.moveToSpill()
        lists.moveToSpill()
        items.moveToSpill()
        var storage = CSSParserSelectorArenaStorage()
        storage.mayHaveUnlinkedNodes = mayHaveUnlinkedNodes
        swapSpills(&storage)
        reset(forTokens: 0)
        return storage
    }

    /// Empties the arena for a parse of `tokens` tokens, keeping its storage, with room for a node per token and the
    /// implicit ones a list adds, and for a few lists.
    mutating func reset(forTokens tokens: Int) {
        nodes.removeAll(reservingCapacity: tokens &+ 4) // tokens is a count of a token span, far below Int.max.
        lists.removeAll(reservingCapacity: 4)
        items.removeAll(reservingCapacity: 0)
        mayHaveUnlinkedNodes = false
    }

    mutating func appendNode(_ node: CSSParserSelectorNode) -> Int32 {
        // A node is made per simple selector, at most a few per token, so this cannot be reached below 2^31 tokens.
        precondition(nodes.count < Int(Int32.max))
        nodes.append(node)
        return Int32(truncatingIfNeeded: nodes.count &- 1) // At least 1 after the append.
    }

    /// A new node, CSSParserSelectorNode() with `body` applied, built in place rather than on the stack and copied.
    @inline(always)
    mutating func appendNode(_ body: (inout CSSParserSelectorNode) -> Void) -> Int32 {
        precondition(nodes.count < Int(Int32.max)) // As appendNode(_:).
        nodes.append({ CSSParserSelectorNode() }, body)
        return Int32(truncatingIfNeeded: nodes.count &- 1) // At least 1 after the append.
    }

    mutating func appendItem(_ item: CSSParserSelectorListItem) {
        precondition(items.count < Int(Int32.max))
        items.append(item)
    }

    var itemCount: Int32 { Int32(truncatingIfNeeded: items.count) }

    mutating func appendList(_ list: CSSParserSelectorListRange) -> Int32 {
        precondition(lists.count < Int(Int32.max))
        lists.append(list)
        return Int32(truncatingIfNeeded: lists.count &- 1) // At least 1 after the append.
    }

    /// MutableCSSSelector::leftmostSimpleSelector().
    mutating func leftmost(_ selector: Int32) -> Int32 {
        var current = selector
        while nodes[Int(current)].preceding >= 0 {
            current = nodes[Int(current)].preceding
        }
        return current
    }

    /// MutableCSSSelector::prependInComplexSelector().
    mutating func prependInComplexSelector(_ selector: Int32, _ relation: CSSParserSelectorRelation, _ preceding: Int32) {
        let first = leftmost(selector)
        nodes.update(Int(first)) {
            $0.relation = relation.rawValue
            $0.preceding = preceding
        }
    }

    /// MutableCSSSelector::prependInComplexSelectorAsRelative().
    mutating func prependInComplexSelectorAsRelative(_ selector: Int32, _ preceding: Int32) {
        // Relation is Descendant by default.
        var relation = nodes[Int(leftmost(selector))].relation
        if relation == CSSParserSelectorRelation.Subselector.rawValue {
            relation = CSSParserSelectorRelation.DescendantSpace.rawValue
        }
        let first = leftmost(selector)
        nodes.update(Int(first)) {
            $0.relation = relation
            $0.preceding = preceding
        }
    }

    /// The simple selector at `selector` moves to a new node behind it, and `selector` becomes the tag selector `tag`,
    /// with the Subselector relation.
    mutating func appendTagInComplexSelector(_ selector: Int32, _ tag: CSSParserSelectorNode) {
        let currentLast = appendNode(nodes[Int(selector)])
        nodes.update(Int(currentLast)) { $0.nextInList = -1 }
        let nextInList = nodes[Int(selector)].nextInList
        nodes.update(Int(selector)) {
            $0 = tag
            $0.relation = CSSParserSelectorRelation.Subselector.rawValue
            $0.preceding = currentLast
            $0.nextInList = nextInList
        }
    }

    /// MutableCSSSelector::releaseFromComplexSelector().
    mutating func releaseFromComplexSelector(_ selector: Int32) -> Int32 {
        nodes.update(Int(selector)) {
            $0.relation = CSSParserSelectorRelation.Subselector.rawValue
            let preceding = $0.preceding
            $0.preceding = -1
            return preceding
        }
    }

    /// MutableCSSSelector::startsWithExplicitCombinator().
    mutating func startsWithExplicitCombinator(_ selector: Int32) -> Bool {
        let relation = nodes[Int(leftmost(selector))].relation
        return relation != CSSParserSelectorRelation.Subselector.rawValue && relation != CSSParserSelectorRelation.DescendantSpace.rawValue
    }

    /// MutableCSSSelector::hasExplicitNestingParent() (`nesting`) or hasExplicitPseudoClassScope(): each simple
    /// selector of the chain, CSSSelector::visitSimpleSelectors with its argument lists' complex selectors whole.
    mutating func visitsMatch(_ selector: Int32, nesting: Bool) -> Bool {
        var current = selector
        while current >= 0 {
            let match = nodes[Int(current)].match
            if nesting {
                if match == CSSParserSelectorMatch.NestingParent.rawValue
                    || match == CSSParserSelectorMatch.ForgivingUnknownNestContaining.rawValue
                {
                    return true
                }
            } else if match == CSSParserSelectorMatch.PseudoClass.rawValue
                && nodes[Int(current)].pseudo == CSSParserPseudoClass.Scope.rawValue
            {
                return true
            }
            let selectorList = nodes[Int(current)].selectorList
            if selectorList >= 0 {
                var complex = lists[Int(selectorList)].first
                while complex >= 0 {
                    if visitsMatch(complex, nesting: nesting) {
                        return true
                    }
                    complex = nodes[Int(complex)].nextInList
                }
            }
            current = nodes[Int(current)].preceding
        }
        return false
    }

    /// MutableCSSSelector::needsImplicitShadowCombinatorForMatching(), of the simple selector itself.
    mutating func needsImplicitShadowCombinatorForMatching(_ selector: Int32) -> Bool {
        guard nodes[Int(selector)].match == CSSParserSelectorMatch.PseudoElement.rawValue else { return false }
        let pseudo = nodes[Int(selector)].pseudo
        return pseudo == CSSParserPseudoElement.UserAgentPart.rawValue
            || pseudo == UInt8(WebCore.CSSParserSwiftCuePseudoElement) // never equal without ENABLE(VIDEO)
            || pseudo == CSSParserPseudoElement.Part.rawValue
            || pseudo == CSSParserPseudoElement.Picker.rawValue
            || pseudo == CSSParserPseudoElement.Slotted.rawValue
            || pseudo == CSSParserPseudoElement.UserAgentPartLegacyAlias.rawValue
            || pseudo == CSSParserPseudoElement.WebKitUnknown.rawValue
    }
}

/// A MutableCSSSelectorList being appended to.
private struct CSSParserSelectorListBuilder {
    var first: Int32 = -1
    var last: Int32 = -1
    var count: Int32 = 0

    mutating func append(_ selector: Int32, _ arena: inout CSSParserSelectorArena) {
        if last >= 0 {
            arena.nodes.update(Int(last)) { $0.nextInList = selector }
        } else {
            first = selector
        }
        arena.nodes.update(Int(selector)) { $0.nextInList = -1 }
        last = selector
        count &+= 1 // At most one per node.
    }

    /// The list, or -1 for an empty one (a MutableCSSSelectorList `{ }`).
    func finish(_ arena: inout CSSParserSelectorArena) -> Int32 {
        count == 0 ? -1 : arena.appendList(CSSParserSelectorListRange(first: first, count: count))
    }
}

// MARK: - The parser

/// What a selector list is made of: CSSSelectorParser's consumeSelectorList and consumeForgivingSelectorList take
/// one of these as their ConsumeSelector.
private enum CSSParserSelectorKind {
    case complex // consumeComplexSelector
    case relativeScope // consumeRelativeScopeSelector
    case nestedComplex // consumeNestedComplexSelector
}

/// CSSSelectorParser: one per selector list request, rule prelude or `selector()` condition.
struct CSSParserSelectorParser: ~Copyable {
    var arena = CSSParserSelectorArena()

    /// The CSSParserMode, and whether the class prefix selector is enabled (CSSSelectorParserContext).
    let mode: UInt8
    let classPrefixSelectorEnabled: Bool
    /// Whether namespaces resolve against the request's style sheet (false for `selector()` in
    /// @supports).
    let withStyleSheet: Bool
    /// Whether the style sheet's default namespace is `*` (always, with no style sheet). An @namespace rule, which
    /// alone changes it, is not parsed while a selector list is.
    let defaultNamespaceIsStar: Bool

    var failedParsing = false
    var disallowPseudoElements: Bool
    var disallowHasPseudoClass = false
    var resistDefaultNamespace = false
    var ignoreDefaultNamespace = false
    var disableForgivingParsing = false
    /// m_precedingPseudoElement, a node index or -1. Nodes are never freed during a parse, so it never dangles.
    var precedingPseudoElement: Int32 = -1

    /// Always inlined: the parser and its arena are built in the caller's frame, not copied there.
    @inline(always)
    init(_ state: inout WebCore.CSSParserSwiftState, withStyleSheet: Bool, disallowPseudoElements: Bool) {
        let flags = state.selectorContextFlags()
        mode = UInt8(truncatingIfNeeded: flags)
        classPrefixSelectorEnabled = flags & UInt32(WebCore.CSSParserSwiftSelectorContextClassPrefixSelectorEnabled) != 0
        self.withStyleSheet = withStyleSheet
        defaultNamespaceIsStar = !withStyleSheet || flags & UInt32(WebCore.CSSParserSwiftSelectorContextDefaultNamespaceIsStar) != 0
        self.disallowPseudoElements = disallowPseudoElements
    }

    private var isUASheetBehavior: Bool { mode == WebCore.UASheetMode.rawValue }

    // MARK: Lists

    private mutating func consumeSelector(
        _ kind: CSSParserSelectorKind,
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor
    ) -> Int32 {
        switch kind {
        case .complex: consumeComplexSelector(&s, &r)
        case .relativeScope: consumeRelativeScopeSelector(&s, &r)
        case .nestedComplex: consumeNestedComplexSelector(&s, &r)
        }
    }

    /// CSSSelectorParser::consumeSelectorList: a list index, or -1 for `{ }`.
    private mutating func consumeSelectorList(
        _ kind: CSSParserSelectorKind,
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor
    ) -> Int32 {
        var list = CSSParserSelectorListBuilder()
        var selector = consumeSelector(kind, &s, &r)
        guard selector >= 0 else { return -1 }
        list.append(selector, &arena)
        while !r.atEnd && r.peekType(&s) == CSSParserSelectorTokenType.comma {
            r.consumeIncludingWhitespace(&s)
            selector = consumeSelector(kind, &s, &r)
            guard selector >= 0 else { return -1 }
            list.append(selector, &arena)
        }
        if failedParsing {
            return -1
        }
        return list.finish(&arena)
    }

    /// consumeComplexSelectorList.
    mutating func consumeComplexSelectorList(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        consumeSelectorList(.complex, &s, &r)
    }

    /// consumeNestedSelectorList.
    mutating func consumeNestedSelectorList(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        consumeSelectorList(.nestedComplex, &s, &r)
    }

    /// CSSSelectorParser::consumeForgivingSelectorList.
    private mutating func consumeForgivingSelectorList(
        _ kind: CSSParserSelectorKind,
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor
    ) -> Int32 {
        if failedParsing {
            return -1
        }
        // A selector it drops leaves its nodes in no list.
        arena.mayHaveUnlinkedNodes = true
        var list = CSSParserSelectorListBuilder()

        func consumeForgiving(
            _ parser: inout CSSParserSelectorParser,
            _ list: inout CSSParserSelectorListBuilder,
            _ s: inout WebCore.CSSParserSwiftState,
            _ r: inout CSSParserTokenCursor
        ) {
            let initial = r.index
            var selector = parser.consumeSelector(kind, &s, &r)
            if parser.failedParsing && !parser.disableForgivingParsing {
                selector = -1
                parser.failedParsing = false
            }
            // Range is not over and next token is not a comma (means there is more to this selector) so this selector
            // is unknown. Consume until next comma and add the full range as an unknown selector to the selector list.
            if (!r.atEnd && r.peekType(&s) != CSSParserSelectorTokenType.comma) || selector < 0 {
                while !r.atEnd && r.peekType(&s) != CSSParserSelectorTokenType.comma {
                    r.consumeComponentValue(&s)
                }
                if !parser.disableForgivingParsing {
                    list.append(parser.unknownSelector(&s, initial, r.index), &parser.arena)
                }
                return
            }
            list.append(selector, &parser.arena)
        }

        consumeForgiving(&self, &list, &s, &r)
        while !r.atEnd && r.peekType(&s) == CSSParserSelectorTokenType.comma {
            r.consumeIncludingWhitespace(&s)
            consumeForgiving(&self, &list, &s, &r)
        }
        if list.count == 0 {
            if disableForgivingParsing {
                failedParsing = true
            }
            return -1
        }
        return list.finish(&arena)
    }

    /// The ForgivingUnknown selector of the tokens [start, end): its value is their serialization, and it is
    /// ForgivingUnknownNestContaining if one of them is the delimiter `&`.
    private mutating func unknownSelector(_ s: inout WebCore.CSSParserSwiftState, _ start: Int, _ end: Int) -> Int32 {
        var match = CSSParserSelectorMatch.ForgivingUnknown.rawValue
        var i = start
        while i < end {
            if s.delimiter(i) == 0x26 { // '&'
                match = CSSParserSelectorMatch.ForgivingUnknownNestContaining.rawValue
                break
            }
            i &+= 1 // Below end.
        }
        return arena.appendNode {
            $0.fields.match = match
            $0.parts.valueToken = UInt32(truncatingIfNeeded: start) // Token indices are below UInt32.max.
            $0.parts.valueEnd = UInt32(truncatingIfNeeded: end)
            $0.parts.valueAtom = .SerializedRange
        }
    }

    /// consumeComplexForgivingSelectorList.
    mutating func consumeComplexForgivingSelectorList(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        consumeForgivingSelectorList(.complex, &s, &r)
    }

    /// consumeNestedComplexForgivingSelectorList.
    mutating func consumeNestedComplexForgivingSelectorList(
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor
    ) -> Int32 {
        consumeForgivingSelectorList(.nestedComplex, &s, &r)
    }

    /// consumeRelativeSelectorList.
    private mutating func consumeRelativeSelectorList(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        consumeSelectorList(.relativeScope, &s, &r)
    }

    /// consumeCompoundSelectorList (::cue()).
    private mutating func consumeCompoundSelectorList(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        var list = CSSParserSelectorListBuilder()
        var selector = consumeCompoundSelector(&s, &r)
        r.consumeWhitespace(&s)
        guard selector >= 0 else { return -1 }
        list.append(selector, &arena)
        while !r.atEnd && r.peekType(&s) == CSSParserSelectorTokenType.comma {
            r.consumeIncludingWhitespace(&s)
            selector = consumeCompoundSelector(&s, &r)
            r.consumeWhitespace(&s)
            guard selector >= 0 else { return -1 }
            list.append(selector, &arena)
        }
        return list.finish(&arena)
    }

    /// A list of the one complex selector `selector` (MutableCSSSelectorList::from).
    private mutating func singleSelectorList(_ selector: Int32) -> Int32 {
        arena.nodes.update(Int(selector)) { $0.nextInList = -1 }
        return arena.appendList(CSSParserSelectorListRange(first: selector, count: 1))
    }

    // MARK: Complex selectors

    /// extractCompoundFlags: whether the simple selector is a pseudo-element that makes its compound the rightmost.
    private mutating func hasPseudoElementForRightmostCompound(_ selector: Int32) -> Bool {
        guard arena.nodes[Int(selector)].match == CSSParserSelectorMatch.PseudoElement.rawValue else { return false }
        // The UASheetMode check is a work-around to allow this selector in mediaControls(New).css:
        // input[type="range" i]::-webkit-media-slider-container > div {
        if isUASheetBehavior && arena.nodes[Int(selector)].pseudo == CSSParserPseudoElement.UserAgentPart.rawValue {
            return false
        }
        return true
    }

    /// consumeNestedComplexSelector.
    private mutating func consumeNestedComplexSelector(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        let selector = consumeComplexSelector(&s, &r)
        if selector >= 0 {
            return selector
        }
        // The range is where the failed complex selector left it. Its nodes are in no list.
        arena.mayHaveUnlinkedNodes = true
        return consumeRelativeNestedSelector(&s, &r)
    }

    /// consumeComplexSelector.
    mutating func consumeComplexSelector(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        var selector = consumeCompoundSelector(&s, &r)
        guard selector >= 0 else { return -1 }

        var previousHasPseudoElement = false
        var simple = selector
        while simple >= 0 && !previousHasPseudoElement {
            previousHasPseudoElement = hasPseudoElementForRightmostCompound(simple)
            simple = arena.nodes[Int(simple)].preceding
        }

        while true {
            let combinator = consumeCombinator(&s, &r)
            if combinator == .Subselector {
                break
            }
            let nextSelector = consumeCompoundSelector(&s, &r)
            guard nextSelector >= 0 else {
                return combinator == .DescendantSpace ? selector : -1
            }
            if previousHasPseudoElement {
                return -1
            }
            var end = nextSelector
            var compoundHasPseudoElement = hasPseudoElementForRightmostCompound(end)
            while arena.nodes[Int(end)].preceding >= 0 {
                end = arena.nodes[Int(end)].preceding
                compoundHasPseudoElement = hasPseudoElementForRightmostCompound(end) || compoundHasPseudoElement
            }
            arena.nodes.update(Int(end)) {
                $0.relation = combinator.rawValue
                $0.preceding = selector
            }
            previousHasPseudoElement = compoundHasPseudoElement
            selector = nextSelector
        }
        return selector
    }

    /// consumeRelativeScopeSelector (an argument of :has()).
    private mutating func consumeRelativeScopeSelector(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        var scopeCombinator = consumeCombinator(&s, &r)
        if scopeCombinator == .Subselector {
            scopeCombinator = .DescendantSpace
        }
        let selector = consumeComplexSelector(&s, &r)
        guard selector >= 0 else { return -1 }
        let end = arena.leftmost(selector)
        let scopeSelector = arena.appendNode { $0.fields.match = CSSParserSelectorMatch.HasScope.rawValue }
        arena.nodes.update(Int(end)) {
            $0.relation = scopeCombinator.rawValue
            $0.preceding = scopeSelector
        }
        return selector
    }

    /// consumeRelativeNestedSelector.
    private mutating func consumeRelativeNestedSelector(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        let scopeCombinator = consumeCombinator(&s, &r)
        // Nesting should only work with ~ > + combinators in this function.
        // The descendant combinator is handled in another code path.
        guard scopeCombinator == .DirectAdjacent || scopeCombinator == .IndirectAdjacent || scopeCombinator == .Child else {
            return -1
        }
        let selector = consumeComplexSelector(&s, &r)
        guard selector >= 0 else { return -1 }
        let end = arena.leftmost(selector)
        arena.nodes.update(Int(end)) { $0.relation = scopeCombinator.rawValue }
        return selector
    }

    /// consumeCombinator.
    private func consumeCombinator(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> CSSParserSelectorRelation {
        var fallbackResult = CSSParserSelectorRelation.Subselector
        while CSSParserSelectorTokenType.isWhitespace(r.peekType(&s)) {
            r.consume()
            fallbackResult = .DescendantSpace
        }
        let kind = r.peekKind(&s)
        if kind == CSSParserSelectorTokenType.delimiterKind(0x2B) || kind == CSSParserSelectorTokenType.delimiterKind(0x7E) // '+', '~'
            || kind == CSSParserSelectorTokenType.delimiterKind(0x3E) // '>'
        {
            r.consumeIncludingWhitespace(&s)
            if kind == CSSParserSelectorTokenType.delimiterKind(0x2B) {
                return .DirectAdjacent
            }
            if kind == CSSParserSelectorTokenType.delimiterKind(0x7E) {
                return .IndirectAdjacent
            }
            return .Child
        }
        return fallbackResult
    }

    // MARK: Compound selectors

    /// consumeCompoundSelector.
    mutating func consumeCompoundSelector(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        var compoundSelector: Int32 = -1
        let parsedName = cssParserConsumeQualifiedName(&s, &r)

        if parsedName == nil {
            compoundSelector = consumeSimpleSelector(&s, &r)
            guard compoundSelector >= 0 else { return -1 }
            if arena.nodes[Int(compoundSelector)].match == CSSParserSelectorMatch.PseudoElement.rawValue {
                precedingPseudoElement = compoundSelector
            }
        }

        while true {
            let simpleSelector = consumeSimpleSelector(&s, &r)
            guard simpleSelector >= 0 else { break }
            if arena.nodes[Int(simpleSelector)].match == CSSParserSelectorMatch.PseudoElement.rawValue {
                precedingPseudoElement = simpleSelector
            }
            if compoundSelector >= 0 {
                arena.prependInComplexSelector(compoundSelector, .Subselector, simpleSelector)
            } else {
                compoundSelector = simpleSelector
            }
        }

        if !disallowPseudoElements {
            precedingPseudoElement = -1
        }

        // While inside a nested selector like :is(), the default namespace shall be ignored when [1]:
        // * The compound selector represents the subject [2], and
        // * The compound selector does not contain a type/universal selector.
        //
        // [1] https://drafts.csswg.org/selectors/#matches
        // [2] https://drafts.csswg.org/selectors/#selector-subject
        let savedIgnoreDefaultNamespace = ignoreDefaultNamespace
        ignoreDefaultNamespace = resistDefaultNamespace && parsedName == nil && r.atEndIgnoringWhitespace(&s)
        defer { ignoreDefaultNamespace = savedIgnoreDefaultNamespace }

        guard compoundSelector >= 0 else {
            // parsedName is not nil here.
            let name = parsedName!
            let status = namespaceStatus(&s, name)
            guard status & UInt8(WebCore.CSSParserSwiftNamespaceResolves) != 0 else {
                failedParsing = true
                return -1
            }
            let ignoreDefaultNamespace = ignoreDefaultNamespace
            let withStyleSheet = withStyleSheet
            return arena.appendNode {
                CSSParserSelectorParser.makeTag(
                    &$0,
                    name,
                    forNamespaceRule: false,
                    ignoreDefaultNamespace: ignoreDefaultNamespace,
                    withStyleSheet: withStyleSheet
                )
            }
        }
        prependTypeSelectorIfNeeded(&s, parsedName, compoundSelector)
        return splitCompoundAtImplicitShadowCrossingCombinator(compoundSelector)
    }

    /// determineNamespace and defaultNamespace for `name`'s prefix, as CSSParserSwiftNamespaceStatus bits.
    private func namespaceStatus(_ s: inout WebCore.CSSParserSwiftState, _ name: CSSParserQualifiedName) -> UInt8 {
        s.namespaceStatus(name.prefixKind.rawValue, name.prefixToken, ignoreDefaultNamespace, withStyleSheet)
    }

    /// The tag selector of `name` (MutableCSSSelector(QualifiedName) or appendTagInComplexSelector's): the state
    /// resolves its namespace as determineNamespace does, with the same default namespace.
    private func tagNode(_ name: CSSParserQualifiedName, forNamespaceRule: Bool) -> CSSParserSelectorNode {
        var node = CSSParserSelectorNode()
        CSSParserSelectorParser.makeTag(
            &node,
            name,
            forNamespaceRule: forNamespaceRule,
            ignoreDefaultNamespace: ignoreDefaultNamespace,
            withStyleSheet: withStyleSheet
        )
        return node
    }

    /// tagNode's fields, written into `node`, a CSSParserSelectorNode().
    @inline(always)
    private static func makeTag(
        _ node: inout CSSParserSelectorNode,
        _ name: CSSParserQualifiedName,
        forNamespaceRule: Bool,
        ignoreDefaultNamespace: Bool,
        withStyleSheet: Bool
    ) {
        node.fields.match = CSSParserSelectorMatch.Tag.rawValue
        if forNamespaceRule {
            node.fields.flags = CSSParserSelectorFlag.tagIsForNamespaceRule
        }
        node.parts.nameToken = name.nameToken
        node.parts.nameAtom = name.nameAtom
        node.parts.prefixToken = name.prefixToken
        node.parts.namespaceKind = name.prefixKind
        node.parts.ignoreDefaultNamespace = ignoreDefaultNamespace
        node.parts.withStyleSheet = withStyleSheet
    }

    /// prependTypeSelectorIfNeeded.
    private mutating func prependTypeSelectorIfNeeded(
        _ s: inout WebCore.CSSParserSwiftState,
        _ parsedName: CSSParserQualifiedName?,
        _ compoundSelector: Int32
    ) {
        let isShadowDOM = arena.needsImplicitShadowCombinatorForMatching(compoundSelector)
        // The resolver's default namespace is `*` when it ignores the style sheet's.
        if parsedName == nil && (ignoreDefaultNamespace || defaultNamespaceIsStar) && !isShadowDOM {
            return
        }
        let name =
            parsedName ?? CSSParserQualifiedName(nameToken: UInt32.max, nameAtom: .None, prefixToken: UInt32.max, prefixKind: .Default)
        let status = namespaceStatus(&s, name)

        // determinedElementName: the name, or starAtom() for none.
        let elementNameIsStar = parsedName == nil || name.nameAtom == .Star
        guard status & UInt8(WebCore.CSSParserSwiftNamespaceResolves) != 0 else {
            failedParsing = true
            return
        }
        // determinedPrefix is null when the prefix is, or when the namespace is the default namespace.
        let determinedPrefixIsNull = name.prefixKind == .Default || status & UInt8(WebCore.CSSParserSwiftNamespaceIsDefault) != 0

        // *:host never matches, so we can't discard the *,
        // otherwise we can't tell the difference between *:host and just :host.
        //
        // Also, selectors where we use a ShadowPseudo combinator between the
        // element and the pseudo element for matching (custom pseudo elements,
        // ::cue), we need a universal selector to set the combinator
        // (relation) on in the cases where there are no simple selectors preceding
        // the pseudo element.
        let isHostPseudo =
            arena.nodes[Int(compoundSelector)].match == CSSParserSelectorMatch.PseudoClass.rawValue
            && arena.nodes[Int(compoundSelector)].pseudo == CSSParserPseudoClass.Host.rawValue
        if isHostPseudo && parsedName == nil && name.prefixKind == .Default {
            return
        }
        // tag != anyQName(): anyQName is (nullAtom, starAtom, starAtom).
        let tagIsAnyQName = determinedPrefixIsNull && elementNameIsStar && status & UInt8(WebCore.CSSParserSwiftNamespaceIsStar) != 0
        if !tagIsAnyQName || isHostPseudo || isShadowDOM {
            var tagName = name
            if parsedName == nil {
                tagName.nameAtom = .Star
            }
            arena.appendTagInComplexSelector(
                compoundSelector,
                tagNode(tagName, forNamespaceRule: determinedPrefixIsNull && elementNameIsStar && !isHostPseudo)
            )
        }
    }

    /// splitCompoundAtImplicitShadowCrossingCombinator.
    private mutating func splitCompoundAtImplicitShadowCrossingCombinator(_ compoundSelector: Int32) -> Int32 {
        // Complex selectors are represented as a linked list that stores combinator separated compound selectors
        // from right-to-left. Yet, within a single compound selector, stores the simple selectors
        // from left-to-right.
        //
        // ".a.b > div#id" is stored in a complex selector as [div, #id, .a, .b], each element in the
        // list stored with an associated relation (combinator or Subselector).
        //
        // ::cue, ::shadow, and custom pseudo elements have an implicit ShadowPseudo combinator
        // to their left, which really makes for a new compound selector, yet it's consumed by
        // the selector parser as a single compound selector.
        //
        // Example: input#x::-webkit-inner-spin-button -> [ ::-webkit-inner-spin-button, input, #x ]
        var splitAfter = compoundSelector
        while arena.nodes[Int(splitAfter)].preceding >= 0
            && !arena.needsImplicitShadowCombinatorForMatching(arena.nodes[Int(splitAfter)].preceding)
        {
            splitAfter = arena.nodes[Int(splitAfter)].preceding
        }
        let splitPoint = arena.nodes[Int(splitAfter)].preceding
        guard splitPoint >= 0 else { return compoundSelector }

        let isPseudoElement = arena.nodes[Int(splitPoint)].match == CSSParserSelectorMatch.PseudoElement.rawValue
        let pointPseudo = arena.nodes[Int(splitPoint)].pseudo
        // ::part() combines with other pseudo elements.
        let isPart = isPseudoElement && pointPseudo == CSSParserPseudoElement.Part.rawValue
        // ::slotted() combines with other pseudo elements.
        let isSlotted = isPseudoElement && pointPseudo == CSSParserPseudoElement.Slotted.rawValue

        let secondCompound: Int32
        if isUASheetBehavior || isPart || isSlotted {
            // We have to recur, since we have rules in media controls like video::a::b. This should not be allowed, and
            // we should remove this recursion once those rules are gone.
            secondCompound = splitCompoundAtImplicitShadowCrossingCombinator(arena.releaseFromComplexSelector(splitAfter))
        } else {
            secondCompound = arena.releaseFromComplexSelector(splitAfter)
        }
        let relation: CSSParserSelectorRelation = isSlotted ? .ShadowSlotted : isPart ? .ShadowPartDescendant : .ShadowDescendant
        arena.prependInComplexSelector(secondCompound, relation, compoundSelector)
        return secondCompound
    }

    // MARK: Simple selectors

    /// consumeSimpleSelector: a simple selector other than a type selector, or -1.
    private mutating func consumeSimpleSelector(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        let kind = r.peekKind(&s)
        let selector: Int32
        if kind == UInt32(CSSParserSelectorTokenType.hash) {
            selector = consumeId(&s, &r)
        } else if kind == CSSParserSelectorTokenType.delimiterKind(0x2E) { // '.'
            selector = consumeClass(&s, &r)
        } else if kind == CSSParserSelectorTokenType.delimiterKind(0x26) { // '&'
            selector = consumeNesting(&s, &r)
        } else if kind == UInt32(CSSParserSelectorTokenType.leftBracket) {
            selector = consumeAttribute(&s, &r)
        } else if kind == UInt32(CSSParserSelectorTokenType.colon) {
            selector = consumePseudo(&s, &r)
        } else {
            return -1
        }

        guard selector >= 0 else {
            failedParsing = true
            return -1
        }

        if precedingPseudoElement >= 0 {
            // The UASheetMode check is a work-around to allow this selector in mediaControls(New).css:
            // video::-webkit-media-text-track-region-container.scrolling
            if !isUASheetBehavior && !isSimpleSelectorValidAfterPseudoElement(&s, selector, precedingPseudoElement) {
                failedParsing = true
            }
        }
        return selector
    }

    /// consumeId.
    private mutating func consumeId(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        guard s.isHashTokenId(r.index) else { return -1 }
        let token = UInt32(truncatingIfNeeded: r.consume()!) // A hash token: not at the end.
        let isQuirks = mode == WebCore.HTMLQuirksMode.rawValue
        return arena.appendNode {
            $0.fields.match = CSSParserSelectorMatch.Id.rawValue
            $0.parts.valueToken = token
            $0.parts.valueAtom = .Value
            if isQuirks {
                $0.fields.flags = CSSParserSelectorFlag.matchLowerCase
            }
        }
    }

    /// consumeClass.
    private mutating func consumeClass(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        r.consume()
        guard r.peekType(&s) == CSSParserSelectorTokenType.ident else { return -1 }
        let token = r.consume()! // An ident token: not at the end.

        // The class prefix selector (.foo-*) is a dash-terminated identifier immediately followed by
        // an asterisk, with no intervening whitespace. https://drafts.csswg.org/selectors/#class-prefix
        let length = s.valueLength(token)
        let endsWithDash = length > 0 && s.valueCharacter(token, length &- 1) == 0x2D
        let match: UInt8
        var flags: UInt16 = 0
        if classPrefixSelectorEnabled && endsWithDash && r.peekType(&s) == CSSParserSelectorTokenType.delimiter
            && r.peekDelimiter(&s) == 0x2A
        {
            r.consume()
            match = CSSParserSelectorMatch.ClassPrefix.rawValue
        } else {
            match = CSSParserSelectorMatch.Class.rawValue
            if mode == WebCore.HTMLQuirksMode.rawValue {
                flags = CSSParserSelectorFlag.matchLowerCase
            }
        }
        return arena.appendNode {
            $0.fields.match = match
            $0.fields.flags = flags
            $0.parts.valueToken = UInt32(truncatingIfNeeded: token)
            $0.parts.valueAtom = .Value
        }
    }

    /// consumeNesting.
    private mutating func consumeNesting(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        r.consume()
        return arena.appendNode { $0.fields.match = CSSParserSelectorMatch.NestingParent.rawValue }
    }

    /// consumeAttribute.
    private mutating func consumeAttribute(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        var block = r.consumeBlock(&s)
        block.consumeWhitespace(&s)

        guard let parsedName = cssParserConsumeQualifiedName(&s, &block) else { return -1 }
        block.consumeWhitespace(&s)

        guard namespaceStatus(&s, parsedName) & UInt8(WebCore.CSSParserSwiftNamespaceResolves) != 0 else { return -1 }

        // The state makes QualifiedName(nullAtom(), name, nullAtom()) for a null prefix, else
        // QualifiedName(prefix, name, namespaceURI). The node is built in place once the attribute has parsed.
        let withStyleSheet = withStyleSheet
        let ignoreDefaultNamespace = ignoreDefaultNamespace
        func attributeNode(_ node: inout CSSParserSelectorNode) {
            node.parts.nameToken = parsedName.nameToken
            node.parts.nameAtom = parsedName.nameAtom
            node.parts.prefixToken = parsedName.prefixToken
            node.parts.namespaceKind = parsedName.prefixKind
            node.parts.withStyleSheet = withStyleSheet
            node.parts.ignoreDefaultNamespace = ignoreDefaultNamespace
        }

        if block.atEnd {
            return arena.appendNode {
                attributeNode(&$0)
                $0.fields.attributeMatchType = WebCore.CSSSelector.AttributeMatchType.Default.rawValue
                $0.fields.match = CSSParserSelectorMatch.Set.rawValue
            }
        }

        let match = consumeAttributeMatch(&s, &block)

        let valueType = block.peekType(&s)
        let value = block.consumeIncludingWhitespace(&s)
        guard let value, valueType == CSSParserSelectorTokenType.ident || valueType == CSSParserSelectorTokenType.string else { return -1 }

        let matchType = consumeAttributeFlags(&s, &block)

        guard block.atEnd else { return -1 }

        // isEquivalentToClassSelector: [class~="foo"] selects the same elements as .foo: both compare the
        // whitespace-separated tokens of the class attribute case-sensitively. Only HTMLStandardMode; quirks mode
        // ASCII-lowercases the class list while [class~=] stays case-sensitive, and UA sheets are parsed once and
        // shared with quirks mode documents. A prefixed attribute name is a different attribute; neither
        // [class~=""] nor a value with whitespace can match anything.
        let equivalentToClass =
            mode == WebCore.HTMLStandardMode.rawValue && match == .List && parsedName.prefixKind == .Default
            && matchType != .CaseInsensitive && parsedName.nameAtom == .Value
            && s.isClassSelectorEquivalent(Int(parsedName.nameToken), Int(value))
        return arena.appendNode {
            attributeNode(&$0)
            $0.fields.match = match.rawValue
            $0.parts.valueToken = UInt32(truncatingIfNeeded: value)
            $0.parts.valueAtom = .Value
            $0.fields.attributeMatchType = matchType.rawValue
            if equivalentToClass {
                $0.fields.flags |= CSSParserSelectorFlag.equivalentToClass
            }
        }
    }

    /// consumeAttributeMatch.
    private mutating func consumeAttributeMatch(
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor
    ) -> CSSParserSelectorMatch {
        let type = r.peekType(&s)
        let token = r.consumeIncludingWhitespace(&s)
        switch type {
        case CSSParserSelectorTokenType.includeMatch:
            return .List
        case CSSParserSelectorTokenType.dashMatch:
            return .Hyphen
        case CSSParserSelectorTokenType.prefixMatch:
            return .Begin
        case CSSParserSelectorTokenType.suffixMatch:
            return .End
        case CSSParserSelectorTokenType.substringMatch:
            return .Contain
        default:
            if type == CSSParserSelectorTokenType.delimiter, let token, s.delimiter(token) == 0x3D { // '='
                return .Exact
            }
            failedParsing = true
            return .Exact
        }
    }

    /// consumeAttributeFlags.
    private mutating func consumeAttributeFlags(
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor
    ) -> WebCore.CSSSelector.AttributeMatchType {
        guard r.peekType(&s) == CSSParserSelectorTokenType.ident else { return .Default }
        let flag = r.consumeIncludingWhitespace(&s)! // An ident token: not at the end.
        if cssParserValueEqualsLetters(&s, flag, "i") {
            return .CaseInsensitive
        }
        if cssParserValueEqualsLetters(&s, flag, "s") {
            return .CaseSensitive
        }
        failedParsing = true
        return .Default
    }

    // MARK: Pseudo-classes and pseudo-elements

    /// consumePseudo.
    private mutating func consumePseudo(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Int32 {
        r.consume()
        var colons = 1
        if r.peekType(&s) == CSSParserSelectorTokenType.colon {
            r.consume()
            colons = 2
        }

        let tokenType = r.peekType(&s)
        guard tokenType == CSSParserSelectorTokenType.ident || tokenType == CSSParserSelectorTokenType.function else { return -1 }
        let token = r.index // Not at the end: an ident or function token.

        var node = CSSParserSelectorNode()
        if colons == 1 {
            // MutableCSSSelector::parsePseudoClassSelector.
            let found = s.pseudoClass(token)
            let kind = found &>> 8
            if kind == UInt16(WebCore.CSSParserSwiftPseudoIsClass) {
                node.fields.match = CSSParserSelectorMatch.PseudoClass.rawValue
                node.fields.pseudoType = UInt8(truncatingIfNeeded: found)
            } else if kind == UInt16(WebCore.CSSParserSwiftPseudoIsCompatibilityElement) {
                node.fields.match = CSSParserSelectorMatch.PseudoElement.rawValue
                node.fields.pseudoType = UInt8(truncatingIfNeeded: found)
                node.parts.valueToken = UInt32(truncatingIfNeeded: token)
                node.parts.valueAtom = .ASCIILowercase
            } else {
                return -1
            }
        } else {
            // MutableCSSSelector::parsePseudoElementSelector.
            let found = s.pseudoElement(token)
            guard found != 0 else { return -1 }
            let pseudo = UInt8(truncatingIfNeeded: found &- 1) // 1 + the raw value.
            node.fields.match = CSSParserSelectorMatch.PseudoElement.rawValue
            node.fields.pseudoType = pseudo
            node.parts.valueToken = UInt32(truncatingIfNeeded: token)
            node.parts.valueAtom =
                pseudo == CSSParserPseudoElement.UserAgentPartLegacyAlias.rawValue ? .UserAgentPartLegacyAlias : .ASCIILowercase
            node.userAgentPart = cssParserUserAgentPart(&s, token)

            let cue = UInt8(WebCore.CSSParserSwiftCuePseudoElement)
            if cue != UInt8(WebCore.CSSParserSwiftNoPseudoElement) { // ENABLE(VIDEO)
                if tokenType == CSSParserSelectorTokenType.ident && pseudo == CSSParserPseudoElement.UserAgentPart.rawValue
                    && node.userAgentPart == .webkitMediaTextTrackDisplay
                {
                    // This will convert a `::-webkit-media-text-track-display` selector into a
                    // `::cue` selector, so that websites which were previously using that selector
                    // to move cues with transform:translateY() rules can continue to do so.
                    node.parts.valueAtom = .UserAgentPartCue
                    node.userAgentPart = .other
                }
                // Treat the ident version of cue as PseudoElement::UserAgentPart.
                if tokenType == CSSParserSelectorTokenType.ident && pseudo == cue {
                    node.fields.pseudoType = CSSParserPseudoElement.UserAgentPart.rawValue
                }
            }
        }

        let isPseudoElement = node.match == CSSParserSelectorMatch.PseudoElement.rawValue
        // Pseudo-elements are not allowed inside pseudo-classes or pseudo-elements.
        if isPseudoElement && disallowPseudoElements {
            return -1
        }
        let savedDisallowPseudoElements = disallowPseudoElements
        disallowPseudoElements = true
        defer { disallowPseudoElements = savedDisallowPseudoElements }

        if tokenType == CSSParserSelectorTokenType.ident {
            r.consume()
            if cssParserPseudoRequiresArgument(isPseudoElement, node.pseudo) {
                return -1
            }
            return arena.appendNode(node)
        }

        var block = r.consumeBlock(&s)
        block.consumeWhitespace(&s)

        if !isPseudoElement {
            return consumePseudoClassArguments(&s, &block, &node) ? arena.appendNode(node) : -1
        }
        return consumePseudoElementArguments(&s, &block, &node) ? arena.appendNode(node) : -1
    }

    /// The arguments of a functional pseudo-class, into `node`: consumePseudo's first switch.
    private mutating func consumePseudoClassArguments(
        _ s: inout WebCore.CSSParserSwiftState,
        _ block: inout CSSParserTokenCursor,
        _ node: inout CSSParserSelectorNode
    ) -> Bool {
        let pseudo = node.pseudo
        switch pseudo {
        case CSSParserPseudoClass.Not.rawValue:
            let saved = resistDefaultNamespace
            resistDefaultNamespace = true
            defer { resistDefaultNamespace = saved }
            let selectorList = consumeComplexSelectorList(&s, &block)
            guard selectorList >= 0 && block.atEnd else { return false }
            node.selectorList = selectorList
            return true
        case CSSParserPseudoClass.Heading.rawValue:
            return consumeCommaSeparatedIntegerList(&s, &block, &node)
        case CSSParserPseudoClass.NthChild.rawValue, CSSParserPseudoClass.NthLastChild.rawValue,
            CSSParserPseudoClass.NthOfType.rawValue, CSSParserPseudoClass.NthLastOfType.rawValue:
            guard let ab = cssParserConsumeANPlusB(&s, &block) else { return false }
            let (a, b) = ab
            block.consumeWhitespace(&s)
            // The argument is serializeANPlusB(a, b), made by the state from a and b.
            node.parts.argumentAtom = .ANPlusB
            if !block.atEnd {
                if pseudo == CSSParserPseudoClass.NthOfType.rawValue || pseudo == CSSParserPseudoClass.NthLastOfType.rawValue {
                    return false
                }
                guard block.peekType(&s) == CSSParserSelectorTokenType.ident else { return false }
                let ident = block.consume()! // An ident token: not at the end.
                guard cssParserValueEqualsLetters(&s, ident, "of") else { return false }
                block.consumeWhitespace(&s)
                let selectorList = consumeComplexSelectorList(&s, &block)
                guard selectorList >= 0 && block.atEnd else { return false }
                node.selectorList = selectorList
            }
            node.parts.a = a
            node.parts.b = b
            return true
        case CSSParserPseudoClass.Lang.rawValue:
            // consumeLangArgumentList.
            node.itemsStart = arena.itemCount
            guard consumePossiblyQuotedIdentifier(&s, &block) else { return false }
            while !block.atEnd && block.peekType(&s) == CSSParserSelectorTokenType.comma {
                block.consumeIncludingWhitespace(&s)
                guard consumePossiblyQuotedIdentifier(&s, &block) else { return false }
            }
            node.itemsEnd = arena.itemCount
            guard block.atEnd else { return false }
            node.fields.list = .Identifiers
            return true
        case CSSParserPseudoClass.Is.rawValue, CSSParserPseudoClass.Where.rawValue, CSSParserPseudoClass.WebKitAny.rawValue:
            let saved = resistDefaultNamespace
            resistDefaultNamespace = true
            defer { resistDefaultNamespace = saved }
            let consumedBlock = consumeComplexForgivingSelectorList(&s, &block)
            guard block.atEnd else { return false }
            // An empty list is an empty CSSSelectorList; it only happens with forgiving parsing disabled, where
            // failedParsing is set and nothing is built.
            node.selectorList = consumedBlock >= 0 ? consumedBlock : arena.appendList(CSSParserSelectorListRange(first: -1, count: 0))
            return true
        case CSSParserPseudoClass.Host.rawValue:
            let innerSelector = consumeCompoundSelector(&s, &block)
            block.consumeWhitespace(&s)
            guard innerSelector >= 0 && block.atEnd else { return false }
            node.selectorList = singleSelectorList(innerSelector)
            return true
        case CSSParserPseudoClass.Has.rawValue:
            guard !disallowHasPseudoClass else { return false }
            let savedResist = resistDefaultNamespace
            let savedDisallowHas = disallowHasPseudoClass
            resistDefaultNamespace = true
            disallowHasPseudoClass = true
            defer {
                resistDefaultNamespace = savedResist
                disallowHasPseudoClass = savedDisallowHas
            }
            let selectorList = consumeRelativeSelectorList(&s, &block)
            guard selectorList >= 0 && block.atEnd else { return false }
            node.selectorList = selectorList
            return true
        case CSSParserPseudoClass.Dir.rawValue, CSSParserPseudoClass.State.rawValue:
            let type = block.peekType(&s)
            let ident = block.consumeIncludingWhitespace(&s)
            guard let ident, type == CSSParserSelectorTokenType.ident && block.atEnd else { return false }
            node.parts.argumentToken = UInt32(truncatingIfNeeded: ident)
            node.parts.argumentAtom = .Value
            return true
        case CSSParserPseudoClass.ActiveViewTransitionType.rawValue:
            // consumeCommaSeparatedCustomIdentList.
            node.itemsStart = arena.itemCount
            repeat {
                // CSSPropertyParserHelpers::consumeEagerlyResolvableCustomIdentRaw.
                guard block.peekType(&s) == CSSParserSelectorTokenType.ident,
                    WebCore.isValidCustomIdentifier(WebCore.CSSValueID(rawValue: s.identifier(block.index)) ?? .Invalid)
                else {
                    return false
                }
                let ident = block.consumeIncludingWhitespace(&s)! // An ident token: not at the end.
                arena.appendItem(CSSParserSelectorListItem(token: UInt32(truncatingIfNeeded: ident), atom: .Value, kind: .atom, integer: 0))
            } while consumeCommaIncludingWhitespace(&s, &block)
            node.itemsEnd = arena.itemCount
            guard block.atEnd else { return false }
            node.fields.list = .Strings
            return true
        default:
            return false
        }
    }

    /// The arguments of a functional pseudo-element, into `node`: consumePseudo's second switch.
    private mutating func consumePseudoElementArguments(
        _ s: inout WebCore.CSSParserSwiftState,
        _ block: inout CSSParserTokenCursor,
        _ node: inout CSSParserSelectorNode
    ) -> Bool {
        let pseudo = node.pseudo
        let cue = UInt8(WebCore.CSSParserSwiftCuePseudoElement)
        if cue != UInt8(WebCore.CSSParserSwiftNoPseudoElement) && pseudo == cue { // ENABLE(VIDEO)
            let selectorList = consumeCompoundSelectorList(&s, &block)
            guard selectorList >= 0 && block.atEnd else { return false }
            node.selectorList = selectorList
            return true
        }
        switch pseudo {
        case CSSParserPseudoElement.Highlight.rawValue:
            let type = block.peekType(&s)
            let token = block.consumeIncludingWhitespace(&s)
            guard block.atEnd, let token else { return false }
            if type == CSSParserSelectorTokenType.ident {
                appendStringListItem(token, .Value, &node)
                return true
            }
            if type == CSSParserSelectorTokenType.delimiter && s.delimiter(token) == 0x2A { // '*'
                appendStringListItem(token, .UniversalPseudoElementName, &node)
                return true
            }
            return false
        case CSSParserPseudoElement.Picker.rawValue:
            guard let argument = cssParserConsumePickerArgument(&s, &block) else { return false }
            appendStringListItem(argument, .ASCIILowercase, &node)
            return true
        case CSSParserPseudoElement.ViewTransitionGroup.rawValue, CSSParserPseudoElement.ViewTransitionImagePair.rawValue,
            CSSParserPseudoElement.ViewTransitionOld.rawValue, CSSParserPseudoElement.ViewTransitionNew.rawValue:
            node.itemsStart = arena.itemCount
            var nameAndClasses = 0
            // Check for implicit universal selector.
            if block.peekType(&s) == CSSParserSelectorTokenType.delimiter && block.peekDelimiter(&s) == 0x2E { // '.'
                appendItem(UInt32.max, .UniversalPseudoElementName)
                nameAndClasses = 1
            }
            // Parse name or explicit universal selector.
            if nameAndClasses == 0 {
                let type = block.peekType(&s)
                let ident = block.consume()
                if let ident, type == CSSParserSelectorTokenType.ident,
                    WebCore.isValidCustomIdentifier(WebCore.CSSValueID(rawValue: s.identifier(ident)) ?? .Invalid)
                {
                    appendItem(UInt32(truncatingIfNeeded: ident), .Value)
                } else if let ident, type == CSSParserSelectorTokenType.delimiter && s.delimiter(ident) == 0x2A { // '*'
                    appendItem(UInt32.max, .UniversalPseudoElementName)
                } else {
                    return false
                }
            }
            // Parse classes.
            while !block.atEnd && !CSSParserSelectorTokenType.isWhitespace(block.peekType(&s)) {
                // `peek().type() != DelimiterToken || consume().delimiter() != '.'`: consumed only if a delimiter.
                guard block.peekType(&s) == CSSParserSelectorTokenType.delimiter else { return false }
                let delimiter = block.consume()! // A delimiter token: not at the end.
                guard s.delimiter(delimiter) == 0x2E else { return false }
                guard block.peekType(&s) == CSSParserSelectorTokenType.ident else { return false }
                appendItem(UInt32(truncatingIfNeeded: block.consume()!), .Value) // An ident token: not at the end.
            }
            block.consumeWhitespace(&s)
            guard block.atEnd else { return false }
            node.itemsEnd = arena.itemCount
            node.fields.list = .Strings
            return true
        case CSSParserPseudoElement.Part.rawValue:
            node.itemsStart = arena.itemCount
            repeat {
                let type = block.peekType(&s)
                let ident = block.consumeIncludingWhitespace(&s)
                guard let ident, type == CSSParserSelectorTokenType.ident else { return false }
                appendItem(UInt32(truncatingIfNeeded: ident), .Value)
            } while !block.atEnd
            node.itemsEnd = arena.itemCount
            node.fields.list = .Strings
            return true
        case CSSParserPseudoElement.Slotted.rawValue:
            let innerSelector = consumeCompoundSelector(&s, &block)
            block.consumeWhitespace(&s)
            guard innerSelector >= 0 && block.atEnd else { return false }
            node.selectorList = singleSelectorList(innerSelector)
            return true
        default:
            return false
        }
    }

    private mutating func appendItem(_ token: UInt32, _ atom: WebCore.CSSParserSwiftAtom) {
        arena.appendItem(CSSParserSelectorListItem(token: token, atom: atom, kind: .atom, integer: 0))
    }

    /// A string list of one atom.
    private mutating func appendStringListItem(_ token: Int, _ atom: WebCore.CSSParserSwiftAtom, _ node: inout CSSParserSelectorNode) {
        node.itemsStart = arena.itemCount
        appendItem(UInt32(truncatingIfNeeded: token), atom)
        node.itemsEnd = arena.itemCount
        node.fields.list = .Strings
    }

    /// consumePossiblyQuotedIdentifier, appended to the lang list; false for a null identifier.
    private mutating func consumePossiblyQuotedIdentifier(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Bool {
        let type = r.peekType(&s)
        let token = r.consumeIncludingWhitespace(&s)
        guard let token, type == CSSParserSelectorTokenType.ident || type == CSSParserSelectorTokenType.string else { return false }
        // string.startsWith("--"_s)
        if s.valueLength(token) >= 2 && s.valueCharacter(token, 0) == 0x2D && s.valueCharacter(token, 1) == 0x2D {
            return false
        }
        let kind: CSSParserSelectorListItemKind = type == CSSParserSelectorTokenType.string ? .quotedIdentifier : .identifier
        arena.appendItem(CSSParserSelectorListItem(token: UInt32(truncatingIfNeeded: token), atom: .Value, kind: kind, integer: 0))
        return true
    }

    /// consumeCommaSeparatedIntegerList, into `node`.
    private mutating func consumeCommaSeparatedIntegerList(
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor,
        _ node: inout CSSParserSelectorNode
    ) -> Bool {
        node.itemsStart = arena.itemCount
        repeat {
            r.consumeWhitespace(&s)
            guard !r.atEnd && s.isIntegerNumber(r.index) else { return false }
            // Saturated to int's range.
            let integer = cssParserClampToInt32(s.numericValue(r.index))
            arena.appendItem(CSSParserSelectorListItem(token: 0, atom: .None, kind: .integer, integer: integer))
            r.consumeIncludingWhitespace(&s)
        } while consumeCommaIncludingWhitespace(&s, &r)
        node.itemsEnd = arena.itemCount
        guard r.atEnd else { return false }
        node.fields.list = .Integers
        return true
    }

    /// CSSPropertyParserHelpers::consumeCommaIncludingWhitespace.
    private func consumeCommaIncludingWhitespace(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> Bool {
        guard r.peekType(&s) == CSSParserSelectorTokenType.comma else { return false }
        r.consumeIncludingWhitespace(&s)
        return true
    }

    // MARK: Validity after a pseudo-element

    /// isSimpleSelectorValidAfterPseudoElement.
    private mutating func isSimpleSelectorValidAfterPseudoElement(
        _ s: inout WebCore.CSSParserSwiftState,
        _ selector: Int32,
        _ compoundPseudoElement: Int32
    ) -> Bool {
        let simple = arena.nodes[Int(selector)]
        let compound = arena.nodes[Int(compoundPseudoElement)]
        let isSimplePseudoElement = simple.match == CSSParserSelectorMatch.PseudoElement.rawValue
        if compound.pseudo == CSSParserPseudoElement.Picker.rawValue
            || (compound.pseudo == CSSParserPseudoElement.UserAgentPart.rawValue && compound.userAgentPart == .detailsContent)
        {
            if isSimplePseudoElement {
                return true
            }
        }
        if compound.pseudo == CSSParserPseudoElement.Part.rawValue {
            if isSimplePseudoElement && simple.pseudo != CSSParserPseudoElement.Part.rawValue {
                return true
            }
        }
        if compound.pseudo == CSSParserPseudoElement.Slotted.rawValue {
            if isTreeAbidingPseudoElement(simple) {
                return true
            }
        }
        guard simple.match == CSSParserSelectorMatch.PseudoClass.rawValue else { return false }
        return isPseudoClassValidAfterPseudoElement(simple.pseudo, compound.pseudo)
    }

    /// isTreeAbidingPseudoElement.
    private func isTreeAbidingPseudoElement(_ node: CSSParserSelectorNode) -> Bool {
        guard node.match == CSSParserSelectorMatch.PseudoElement.rawValue else { return false }
        switch node.pseudo {
        case CSSParserPseudoElement.Before.rawValue, CSSParserPseudoElement.After.rawValue, CSSParserPseudoElement.Marker.rawValue,
            CSSParserPseudoElement.Backdrop.rawValue, CSSParserPseudoElement.Picker.rawValue, CSSParserPseudoElement.PickerIcon.rawValue:
            return true
        case CSSParserPseudoElement.UserAgentPart.rawValue:
            return node.userAgentPart == .detailsContent || node.userAgentPart == .fileSelectorButton
                || node.userAgentPart == .placeholder
        default:
            return false
        }
    }

    /// isPseudoClassValidAfterPseudoElement.
    private func isPseudoClassValidAfterPseudoElement(_ pseudoClassRaw: UInt8, _ compoundPseudoElement: UInt8) -> Bool {
        // Never nil: an imported C++ enum's init(rawValue:) does not check its value; the value is the C++ lookup's.
        let pseudoClass = CSSParserPseudoClass(rawValue: pseudoClassRaw) ?? .Active
        // FIXME: https://drafts.csswg.org/selectors-4/#pseudo-element-states states all pseudo-elements
        // can be followed by isUserActionPseudoClass().
        // Validity of these is determined by their content.
        if WebCore.isLogicalCombinationPseudoClass(pseudoClass) {
            return true
        }
        switch compoundPseudoElement {
        case CSSParserPseudoElement.Part.rawValue:
            return !WebCore.isTreeStructuralPseudoClass(pseudoClass)
        case CSSParserPseudoElement.WebKitResizer.rawValue, CSSParserPseudoElement.WebKitScrollbar.rawValue,
            CSSParserPseudoElement.WebKitScrollbarCorner.rawValue, CSSParserPseudoElement.WebKitScrollbarButton.rawValue,
            CSSParserPseudoElement.WebKitScrollbarThumb.rawValue, CSSParserPseudoElement.WebKitScrollbarTrack.rawValue,
            CSSParserPseudoElement.WebKitScrollbarTrackPiece.rawValue:
            return isScrollbarPseudoClass(pseudoClassRaw)
        case CSSParserPseudoElement.Selection.rawValue:
            return pseudoClassRaw == CSSParserPseudoClass.WindowInactive.rawValue
        case CSSParserPseudoElement.ViewTransitionGroup.rawValue, CSSParserPseudoElement.ViewTransitionImagePair.rawValue,
            CSSParserPseudoElement.ViewTransitionNew.rawValue, CSSParserPseudoElement.ViewTransitionOld.rawValue:
            return pseudoClassRaw == CSSParserPseudoClass.OnlyChild.rawValue
        case CSSParserPseudoElement.Picker.rawValue, CSSParserPseudoElement.UserAgentPart.rawValue,
            CSSParserPseudoElement.UserAgentPartLegacyAlias.rawValue, CSSParserPseudoElement.WebKitUnknown.rawValue:
            return isUserActionPseudoClass(pseudoClassRaw)
        default:
            return false
        }
    }

    /// isScrollbarPseudoClass.
    private func isScrollbarPseudoClass(_ pseudo: UInt8) -> Bool {
        switch pseudo {
        case CSSParserPseudoClass.Enabled.rawValue, CSSParserPseudoClass.Disabled.rawValue, CSSParserPseudoClass.Hover.rawValue,
            CSSParserPseudoClass.Active.rawValue, CSSParserPseudoClass.Horizontal.rawValue, CSSParserPseudoClass.Vertical.rawValue,
            CSSParserPseudoClass.Decrement.rawValue, CSSParserPseudoClass.Increment.rawValue, CSSParserPseudoClass.Start.rawValue,
            CSSParserPseudoClass.End.rawValue, CSSParserPseudoClass.DoubleButton.rawValue, CSSParserPseudoClass.SingleButton.rawValue,
            CSSParserPseudoClass.NoButton.rawValue, CSSParserPseudoClass.CornerPresent.rawValue,
            CSSParserPseudoClass.WindowInactive.rawValue:
            return true
        default:
            return false
        }
    }

    /// isUserActionPseudoClass.
    private func isUserActionPseudoClass(_ pseudo: UInt8) -> Bool {
        switch pseudo {
        case CSSParserPseudoClass.Hover.rawValue, CSSParserPseudoClass.Focus.rawValue, CSSParserPseudoClass.Active.rawValue,
            CSSParserPseudoClass.FocusVisible.rawValue, CSSParserPseudoClass.FocusWithin.rawValue:
            return true
        default:
            return false
        }
    }

    // MARK: Whole lists

    /// parseMutableCSSSelectorList: the list, or -1 for none; the implicit & or :scope of a nested context added.
    /// `nestedContext` is 0 for none, else 1 + a CSSParserEnum::NestedContextType.
    mutating func parseMutableSelectorList(
        _ s: inout WebCore.CSSParserSwiftState,
        _ r: inout CSSParserTokenCursor,
        nestedContext: UInt8,
        forgiving: Bool
    ) -> Int32 {
        r.consumeWhitespace(&s)
        let list: Int32
        if nestedContext != 0 && !forgiving {
            list = consumeNestedSelectorList(&s, &r)
        } else if nestedContext != 0 && forgiving {
            list = consumeNestedComplexForgivingSelectorList(&s, &r)
        } else if forgiving {
            list = consumeComplexForgivingSelectorList(&s, &r)
        } else {
            list = consumeComplexSelectorList(&s, &r)
        }
        guard list >= 0 && r.atEnd else { return -1 }

        // In nested context, add the implicit :scope or &
        if nestedContext != 0 {
            let last = nestedContext &- 1 // Not 0.
            var selector = arena.lists[Int(list)].first
            while selector >= 0 {
                appendImplicitSelectorIfNeeded(selector, last)
                selector = arena.nodes[Int(selector)].nextInList
            }
        }
        return list
    }

    /// appendImplicitSelectorIfNeeded.
    private mutating func appendImplicitSelectorIfNeeded(_ selector: Int32, _ last: UInt8) {
        if last == WebCore.CSSParserEnum.NestedContextType.Style.rawValue {
            // For a rule inside a style rule, we had the implicit & if it's not there already or if it starts with a
            // combinator > ~ +
            if !arena.visitsMatch(selector, nesting: true) || arena.startsWithExplicitCombinator(selector) {
                // https://drafts.csswg.org/css-nesting/#nesting
                // Spec: nested rules with relative selectors include the specificity of their implied nesting selector.
                let nestingParent = arena.appendNode { $0.fields.match = CSSParserSelectorMatch.NestingParent.rawValue }
                arena.prependInComplexSelectorAsRelative(selector, nestingParent)
            }
        } else if last == WebCore.CSSParserEnum.NestedContextType.Scope.rawValue {
            // For a rule inside a scope rule, we had the implicit ":scope" if there is no explicit & or :scope already
            if (!arena.visitsMatch(selector, nesting: true) && !arena.visitsMatch(selector, nesting: false))
                || arena.startsWithExplicitCombinator(selector)
            {
                let scope = arena.appendNode {
                    $0.fields.match = CSSParserSelectorMatch.PseudoClass.rawValue
                    $0.fields.pseudoType = CSSParserPseudoClass.Scope.rawValue
                    $0.fields.flags = CSSParserSelectorFlag.implicit
                }
                arena.prependInComplexSelectorAsRelative(selector, scope)
            }
        }
    }
}

// MARK: - The records

extension CSSParserSelectorArena {
    /// The number of records list `list` has: its simple selectors, its argument lists' not counted. With one list
    /// and no node left out of it, every node is one of its records.
    private mutating func recordCount(_ list: Int32) -> Int {
        if lists.count == 1 && !mayHaveUnlinkedNodes {
            return nodes.count
        }
        var count = 0
        var complex = lists[Int(list)].first
        while complex >= 0 {
            var current = complex
            while current >= 0 {
                count &+= 1 // At most one per node.
                current = nodes[Int(current)].preceding
            }
            complex = nodes[Int(complex)].nextInList
        }
        return count
    }

    /// Writes list `list` into a new storage, post-order: each argument list into its own storage before the record
    /// that takes it. Records go in the arena's order (a complex selector's subject compound first), which is the
    /// list's.
    mutating func write(_ s: inout WebCore.CSSParserSwiftState, _ list: Int32) -> WebCore.CSSSelectorListStorage {
        let records = recordCount(list)
        let storage = WebCore.CSSSelectorListStorage.createWithCapacity(records).get()
        var written = 0
        var complex = lists[Int(list)].first
        while complex >= 0 {
            var current = complex
            var continues: UInt16 = 0
            while current >= 0 {
                var fields = nodes[Int(current)].fields
                fields.flags |= continues
                let match = fields.match
                let selectorList = nodes[Int(current)].selectorList
                let itemsStart = nodes[Int(current)].itemsStart
                let itemsEnd = nodes[Int(current)].itemsEnd
                let isAttribute =
                    match == CSSParserSelectorMatch.Exact.rawValue || match == CSSParserSelectorMatch.Set.rawValue
                    || match == CSSParserSelectorMatch.List.rawValue || match == CSSParserSelectorMatch.Hyphen.rawValue
                    || match == CSSParserSelectorMatch.Contain.rawValue || match == CSSParserSelectorMatch.Begin.rawValue
                    || match == CSSParserSelectorMatch.End.rawValue
                if match != CSSParserSelectorMatch.Tag.rawValue && !isAttribute && selectorList < 0
                    && nodes[Int(current)].parts.argumentAtom == .None && itemsStart == itemsEnd
                {
                    let parts = nodes[Int(current)].parts
                    let value =
                        parts.valueAtom == .None
                        ? WTF.AtomString() : s.selectorAtom(parts.valueAtom, parts.valueToken, parts.valueEnd, parts.a, parts.b)
                    storage.appendSimpleSelector(fields, value)
                } else {
                    let parts = nodes[Int(current)].parts
                    let value =
                        parts.valueAtom == .None
                        ? WTF.AtomString() : s.selectorAtom(parts.valueAtom, parts.valueToken, parts.valueEnd, parts.a, parts.b)
                    let nested = selectorList >= 0 ? write(&s, selectorList) : nil
                    // nullQName() for a pseudo-class or pseudo-element, whose nameAtom is None.
                    let name = s.selectorQualifiedName(
                        parts.nameToken,
                        parts.nameAtom,
                        parts.namespaceKind,
                        parts.prefixToken,
                        parts.ignoreDefaultNamespace,
                        parts.withStyleSheet,
                        isAttribute
                    )
                    let argument =
                        parts.argumentAtom == .None
                        ? WTF.AtomString() : s.selectorAtom(parts.argumentAtom, parts.argumentToken, parts.argumentToken, parts.a, parts.b)
                    let itemCount = itemsEnd &- itemsStart // itemsStart <= itemsEnd.
                    storage.appendSelector(fields, value, name, argument, parts.a, parts.b, nested, UInt32(truncatingIfNeeded: itemCount))
                    var item = itemsStart
                    while item < itemsEnd {
                        let listItem = items[Int(item)]
                        let index = Int(item &- itemsStart) // Below itemCount.
                        switch listItem.kind {
                        case .integer:
                            storage.setListItem(index, WTF.AtomString(), listItem.integer)
                        case .atom, .identifier, .quotedIdentifier:
                            let atom = s.selectorAtom(listItem.atom, listItem.token, listItem.token, 0, 0)
                            storage.setListItem(index, atom, listItem.kind == .quotedIdentifier ? 1 : 0)
                        }
                        item &+= 1 // Below itemsEnd.
                    }
                }
                written &+= 1 // At most one per node.
                continues = CSSParserSelectorFlag.continuesComplexSelector
                current = nodes[Int(current)].preceding
            }
            complex = nodes[Int(complex)].nextInList
        }
        // The storage's capacity is exactly its records.
        precondition(written == records)
        return storage
    }
}

// MARK: - Qualified names

/// ParsedQualifiedName as token indices: the name (an ident token's value, `*`, or none) and the prefix.
struct CSSParserQualifiedName {
    var nameToken: UInt32
    var nameAtom: WebCore.CSSParserSwiftAtom
    var prefixToken: UInt32
    /// Default: no `|` (a null prefix); NoNamespace: `|name`; Any: `*|name`; Prefix: `prefix|name`.
    var prefixKind: WebCore.CSSParserSwiftNamespace
}

/// Whether ident token `token`'s value is `*` (an escaped `\*`), whose atom is starAtom().
private func cssParserIdentIsStar(_ s: inout WebCore.CSSParserSwiftState, _ token: Int) -> Bool {
    s.valueLength(token) == 1 && s.valueCharacter(token, 0) == 0x2A
}

/// consumeQualifiedName. It consumes tokens also when it fails (`ns|` followed by neither an ident nor `*`
/// consumes `ns`).
func cssParserConsumeQualifiedName(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> CSSParserQualifiedName? {
    let firstKind = r.peekKind(&s)
    var name: CSSParserQualifiedName
    if firstKind == UInt32(CSSParserSelectorTokenType.ident) {
        let token = r.consume()! // An ident token: not at the end.
        let isStar = cssParserIdentIsStar(&s, token)
        name = CSSParserQualifiedName(
            nameToken: UInt32(truncatingIfNeeded: token),
            nameAtom: isStar ? .Star : .Value,
            prefixToken: UInt32.max,
            prefixKind: .Default
        )
    } else if firstKind == CSSParserSelectorTokenType.delimiterKind(0x2A) { // '*'
        r.consume()
        name = CSSParserQualifiedName(nameToken: UInt32.max, nameAtom: .Star, prefixToken: UInt32.max, prefixKind: .Default)
    } else if firstKind == CSSParserSelectorTokenType.delimiterKind(0x7C) { // '|'
        // This is an empty namespace, which'll get assigned this value below.
        name = CSSParserQualifiedName(nameToken: UInt32.max, nameAtom: .Empty, prefixToken: UInt32.max, prefixKind: .Default)
    } else {
        return nil
    }

    guard r.peekKind(&s) == CSSParserSelectorTokenType.delimiterKind(0x7C) else { return name }

    // namespacePrefix = name: emptyAtom() is no namespace, starAtom() any namespace (an escaped `\*` ident too:
    // it is the same atom), else a prefix.
    let prefixKind: WebCore.CSSParserSwiftNamespace = name.nameAtom == .Empty ? .NoNamespace : name.nameAtom == .Star ? .Any : .Prefix
    let prefixToken = name.nameToken

    let nextKind = r.peekKind(&s, 1)
    if nextKind == UInt32(CSSParserSelectorTokenType.ident) {
        r.consume()
        let token = r.consume()! // An ident token: not at the end.
        let isStar = cssParserIdentIsStar(&s, token)
        return CSSParserQualifiedName(
            nameToken: UInt32(truncatingIfNeeded: token),
            nameAtom: isStar ? .Star : .Value,
            prefixToken: prefixToken,
            prefixKind: prefixKind
        )
    }
    if nextKind == CSSParserSelectorTokenType.delimiterKind(0x2A) {
        r.consume()
        r.consume()
        return CSSParserQualifiedName(nameToken: UInt32.max, nameAtom: .Star, prefixToken: prefixToken, prefixKind: prefixKind)
    }
    return nil
}

// MARK: - An+B

/// consumeANPlusB: (a, b), or nil. Numeric values are clamped with clampTo<int>; `n-123` in an ident
/// or a dimension's unit is read with parseInteger<int>.
func cssParserConsumeANPlusB(_ s: inout WebCore.CSSParserSwiftState, _ r: inout CSSParserTokenCursor) -> (Int32, Int32)? {
    let type = r.peekType(&s)
    let token = r.consume() // nil at the end: the EOF token, of no type below.
    if let token, type == CSSParserSelectorTokenType.number && s.isIntegerNumber(token) {
        return (0, cssParserClampToInt32(s.numericValue(token)))
    }
    if let token, type == CSSParserSelectorTokenType.ident {
        if cssParserValueEqualsLetters(&s, token, "odd") {
            return (2, 1)
        }
        if cssParserValueEqualsLetters(&s, token, "even") {
            return (2, 0)
        }
    }

    // The 'n' will end up as part of an ident or dimension. For a valid <an+b>,
    // this will store a string of the form 'n', 'n-', or 'n-123': the value of nToken from nOffset.
    var a: Int32 = 0
    var nToken = -1
    var nOffset: UInt32 = 0

    // 0x2B is '+'.
    if let token,
        type == CSSParserSelectorTokenType.delimiter && s.delimiter(token) == 0x2B && r.peekType(&s) == CSSParserSelectorTokenType.ident
    {
        a = 1
        nToken = r.consume()! // An ident token: not at the end.
    } else if let token, type == CSSParserSelectorTokenType.dimension && s.isIntegerNumeric(token) {
        a = cssParserClampToInt32(s.numericValue(token))
        nToken = token // valueLength/valueCharacter read a dimension token's unit.
    } else if let token, type == CSSParserSelectorTokenType.ident {
        if s.valueCharacter(token, 0) == 0x2D { // '-'
            a = -1
            nToken = token
            nOffset = 1
        } else {
            a = 1
            nToken = token
        }
    }

    r.consumeWhitespace(&s)

    // nString's length. nToken is an ident or dimension token, whose value (a dimension's unit) is at least
    // nOffset long: nOffset is 1 only for an ident that starts with '-'.
    var nLength: UInt32 = 0
    if nToken >= 0 {
        let valueLength = s.valueLength(nToken)
        guard valueLength != UInt32.max else { return nil }
        nLength = valueLength &- nOffset // At least 0, as above.
    }
    guard nLength != 0 else { return nil }
    // isASCIIAlphaCaselessEqual(nString[0], 'n')
    guard s.valueCharacter(nToken, nOffset) | 0x20 == 0x6E else { return nil }
    if nLength > 1 && s.valueCharacter(nToken, nOffset &+ 1) != 0x2D { // Below the value's length.
        return nil
    }

    if nLength > 2 {
        // parseInteger<int>(nString.substring(1)).
        let parsed = s.parseIntegerInValue(nToken, nOffset &+ 1)
        guard parsed != Int64.min else { return nil }
        return (a, Int32(truncatingIfNeeded: parsed)) // An int: parseInteger<int>'s.
    }

    var sign = nLength == 1 ? CSSParserNumericSign.none : CSSParserNumericSign.minus
    if sign == CSSParserNumericSign.none && r.peekType(&s) == CSSParserSelectorTokenType.delimiter {
        let delimiterToken = r.consumeIncludingWhitespace(&s)! // A delimiter token: not at the end.
        let delimiterSign = s.delimiter(delimiterToken)
        if delimiterSign == 0x2B {
            sign = CSSParserNumericSign.plus
        } else if delimiterSign == 0x2D {
            sign = CSSParserNumericSign.minus
        } else {
            return nil
        }
    }

    if sign == CSSParserNumericSign.none && r.peekType(&s) != CSSParserSelectorTokenType.number {
        return (a, 0)
    }

    let bType = r.peekType(&s)
    guard let b = r.consume(), bType == CSSParserSelectorTokenType.number && s.isIntegerNumber(b) else { return nil }
    if (s.numericSign(b) == CSSParserNumericSign.none) == (sign == CSSParserNumericSign.none) {
        return nil
    }
    var bValue = cssParserClampToInt32(s.numericValue(b))
    if sign == CSSParserNumericSign.minus {
        // A sign was written before b, so b's own token has none and its value, clamped, is at least 0: the
        // negation cannot overflow.
        bValue = 0 &- bValue
    }
    return (a, bValue)
}

/// consumePickerArgument: the `select` ident token, or nil.
private func cssParserConsumePickerArgument(_ s: inout WebCore.CSSParserSwiftState, _ block: inout CSSParserTokenCursor) -> Int? {
    let type = block.peekType(&s)
    let ident = block.consumeIncludingWhitespace(&s)
    guard let ident, type == CSSParserSelectorTokenType.ident && block.atEnd else { return nil }
    guard cssParserValueEqualsLetters(&s, ident, "select") else { return nil }
    return ident
}

// MARK: - Entries

/// The SelectorList request (CSSSelectorParser::parseSelectorList, parseCSSSelectorList, parseMutableCSSSelectorList):
/// the whole token span, with requestInputs' nested context (third byte). The list is left in the parse's selectorList,
/// none if it does not parse.
func cssParserParseSelectorListRequest(_ s: inout WebCore.CSSParserSwiftState) {
    let inputs = s.requestInputs()
    let nestedContext = UInt8(truncatingIfNeeded: inputs &>> 16)
    var r = CSSParserTokenCursor(0, s.count())
    var storage = CSSParserSelectorArenaStorage()
    _ = cssParserParseSelectorList(&s, &r, nestedContext: nestedContext, forgiving: false, disallowPseudoElements: false, storage: &storage)
}

/// parseMutableCSSSelectorList on `r` (also a rule's prelude, for the rule parser), built into the parse's
/// selectorList; false, and nothing built, if it does not parse. The parse uses `storage` past the arena's inline
/// nodes, which the rule parser keeps for every prelude of its request. Never inlined: the parser's inline nodes stay
/// out of the rule parser's recursive frames.
@inline(never)
func cssParserParseSelectorList(
    _ s: inout WebCore.CSSParserSwiftState,
    _ r: inout CSSParserTokenCursor,
    nestedContext: UInt8,
    forgiving: Bool,
    disallowPseudoElements: Bool,
    storage: inout CSSParserSelectorArenaStorage
) -> Bool {
    var parser = CSSParserSelectorParser(&s, withStyleSheet: true, disallowPseudoElements: disallowPseudoElements)
    parser.arena.swapSpills(&storage)
    defer { parser.arena.swapSpills(&storage) }
    parser.arena.reset(forTokens: r.end &- r.index) // index is at most end.
    let list = parser.parseMutableSelectorList(&s, &r, nestedContext: nestedContext, forgiving: forgiving)
    guard list >= 0 else { return false }
    let selectorList = parser.arena.write(&s, list)
    s.setSelectorList(selectorList)
    return true
}

/// Whether the tokens [start, end) are a complex selector that `selector()` in @supports supports. Never
/// inlined: the parser's inline nodes stay out of the @supports parser's recursive frames.
@inline(never)
func cssParserSupportsComplexSelector(_ s: inout WebCore.CSSParserSwiftState, _ start: Int, _ end: Int) -> Bool {
    var r = CSSParserTokenCursor(start, end)
    r.consumeWhitespace(&s)
    // CSSSelectorParser parser(context, nullptr): no style sheet.
    var parser = CSSParserSelectorParser(&s, withStyleSheet: false, disallowPseudoElements: false)
    parser.arena.reset(forTokens: r.end &- r.index) // index is at most end.
    // @supports requires that all arguments parse.
    parser.disableForgivingParsing = true
    let selector = parser.consumeComplexSelector(&s, &r)
    if parser.failedParsing || !r.atEnd || selector < 0 {
        return false
    }
    // containsUnknownWebKitPseudoElements(mutableSelector->selector()): the head's CSSSelector, whose
    // precedingInComplexSelector() is null in a MutableCSSSelector, so only the head simple selector is checked.
    return
        !(parser.arena.nodes[Int(selector)].match == CSSParserSelectorMatch.PseudoElement.rawValue
        && parser.arena.nodes[Int(selector)].pseudo == CSSParserPseudoElement.WebKitUnknown.rawValue)
}

/// The QualifiedName request (consumeQualifiedName, StyleSubstitutionResolver's): the tokens consumed in the low 31
/// bits and bit 31 set when there is a name; the prefix in result atom 0 and the name in result atom 1.
func cssParserQualifiedNameRequest(_ s: inout WebCore.CSSParserSwiftState) {
    var r = CSSParserTokenCursor(0, s.count())
    let name = cssParserConsumeQualifiedName(&s, &r)
    // r.index is at most the token count, which is below 2^31.
    var result = UInt32(truncatingIfNeeded: r.index) & 0x7FFF_FFFF
    if let name {
        result |= 0x8000_0000
        let prefixAtom: WebCore.CSSParserSwiftAtom
        switch name.prefixKind {
        case .Default: prefixAtom = .None
        case .NoNamespace: prefixAtom = .Empty
        case .Any: prefixAtom = .Star
        default: prefixAtom = .Value
        }
        s.setResultAtom(0, name.prefixToken, prefixAtom)
        s.setResultAtom(1, name.nameToken, name.nameAtom)
    }
    s.setResult(result)
}

/// The PseudoElement request (CSSSelectorParser::parsePseudoElement). The result: 0 for none; else 1 + the
/// PseudoElementType in the low byte, and bit 8 when result atom 0 is its name argument.
func cssParserParsePseudoElementRequest(_ s: inout WebCore.CSSParserSwiftState) {
    s.setResult(cssParserParsePseudoElement(&s))
}

/// CSSSelector::stylePseudoElementTypeFor of a CSSSelector::PseudoElement the parser's lookups found.
private func cssParserStylePseudoElementType(_ pseudo: UInt8) -> WebCore.PseudoElementType? {
    // Never nil: an imported C++ enum's init(rawValue:) does not check its value, so check it here.
    precondition(pseudo <= CSSParserPseudoElement.WebKitUnknown.rawValue)
    guard let pseudoElement = CSSParserPseudoElement(rawValue: pseudo) else { return nil }
    return cssSelectorStylePseudoElementType(pseudoElement)
}

/// The style type of a pseudo-element; nil for the element-backed ones and WebKitUnknown.
private func cssSelectorStylePseudoElementType(_ type: CSSParserPseudoElement) -> WebCore.PseudoElementType? {
    switch type {
    case .FirstLine: .FirstLine
    case .FirstLetter: .FirstLetter
    case .GrammarError: .GrammarError
    case .SpellingError: .SpellingError
    case .Selection: .Selection
    case .TargetText: .TargetText
    case .Highlight: .Highlight
    case .Marker: .Marker
    case .Backdrop: .Backdrop
    case .Before: .Before
    case .After: .After
    case .Checkmark: .Checkmark
    case .PickerIcon: .PickerIcon
    case .WebKitScrollbar: .WebKitScrollbar
    case .WebKitScrollbarButton: .WebKitScrollbarButton
    case .WebKitScrollbarCorner: .WebKitScrollbarCorner
    case .WebKitScrollbarThumb: .WebKitScrollbarThumb
    case .WebKitScrollbarTrack: .WebKitScrollbarTrack
    case .WebKitScrollbarTrackPiece: .WebKitScrollbarTrackPiece
    case .WebKitResizer: .WebKitResizer
    case .ViewTransition: .ViewTransition
    case .ViewTransitionGroup: .ViewTransitionGroup
    case .ViewTransitionImagePair: .ViewTransitionImagePair
    case .ViewTransitionOld: .ViewTransitionOld
    case .ViewTransitionNew: .ViewTransitionNew
    case .InternalWritingSuggestions: .InternalWritingSuggestions
    default: nil
    }
}

extension WebCore.CSSSelector {
    @cxx
    @implementation
    static func stylePseudoElementTypeFor(_ type: CSSParserPseudoElement) -> WebCore.CSSParserSwiftOptionalPseudoElementType {
        guard let styleType = cssSelectorStylePseudoElementType(type) else {
            return WebCore.CSSParserSwiftOptionalPseudoElementType()
        }
        return WebCore.CSSParserSwiftOptionalPseudoElementType(styleType)
    }
}

extension WebCore {
    @cxx
    @implementation
    static func isElementBackedPseudoElement(_ pseudoElement: CSSParserPseudoElement) -> Bool {
        switch pseudoElement {
        case .Part, .Picker, .Slotted, .UserAgentPart, .UserAgentPartLegacyAlias:
            true
        default:
            // Cue, where ENABLE(VIDEO).
            pseudoElement.rawValue == UInt8(WebCore.CSSParserSwiftCuePseudoElement)
                && WebCore.CSSParserSwiftCuePseudoElement != WebCore.CSSParserSwiftNoPseudoElement
        }
    }
}

private func cssParserPseudoElementResult(_ type: WebCore.PseudoElementType, hasName: Bool) -> UInt32 {
    // Below 0x100: the enum is a UInt8 below its highest value.
    (UInt32(type.rawValue) &+ 1) | (hasName ? 0x100 : 0)
}

private func cssParserParsePseudoElement(_ s: inout WebCore.CSSParserSwiftState) -> UInt32 {
    var r = CSSParserTokenCursor(0, s.count())
    guard r.peekType(&s) == CSSParserSelectorTokenType.colon else { return 0 }
    r.consume()
    let type = r.peekType(&s)
    let token = r.consume()
    if let token, type == CSSParserSelectorTokenType.ident {
        guard r.atEnd else { return 0 }
        let found = s.pseudoClass(token)
        // Only the compatibility pseudo-elements; isPseudoElementEnabled is only asserted.
        guard found &>> 8 == UInt16(WebCore.CSSParserSwiftPseudoIsCompatibilityElement) else { return 0 }
        let pseudo = UInt8(truncatingIfNeeded: found)
        // pseudoElementIdentifierFor.
        return cssParserStylePseudoElementType(pseudo).map { cssParserPseudoElementResult($0, hasName: false) } ?? 0
    }
    guard type == CSSParserSelectorTokenType.colon else { return 0 }
    let nameType = r.peekType(&s)
    guard nameType == CSSParserSelectorTokenType.ident || nameType == CSSParserSelectorTokenType.function else { return 0 }
    let nameToken = r.index // Not at the end.
    let found = s.pseudoElement(nameToken)
    guard found != 0 else { return 0 }
    let pseudo = UInt8(truncatingIfNeeded: found &- 1) // found is not 0.
    if nameType == CSSParserSelectorTokenType.ident {
        r.consume()
        if !r.atEnd || cssParserPseudoRequiresArgument(true, pseudo) {
            return 0
        }
        if let type = cssParserStylePseudoElementType(pseudo) {
            return cssParserPseudoElementResult(type, hasName: false)
        }
        // Reject non-standard user agent part pseudo-elements here as we never supported these in
        // getComputedStyle() and there's no reason to start now.
        if pseudo == CSSParserPseudoElement.UserAgentPart.rawValue && s.valueCharacter(nameToken, 0) != 0x2D {
            s.setResultAtom(0, UInt32(truncatingIfNeeded: nameToken), .Value)
            return cssParserPseudoElementResult(.UserAgentPartFallback, hasName: true)
        }
        return 0
    }
    var block = r.consumeBlock(&s)
    guard r.atEnd else { return 0 }
    block.consumeWhitespace(&s)
    switch pseudo {
    case CSSParserPseudoElement.Highlight.rawValue, CSSParserPseudoElement.ViewTransitionGroup.rawValue,
        CSSParserPseudoElement.ViewTransitionImagePair.rawValue, CSSParserPseudoElement.ViewTransitionOld.rawValue,
        CSSParserPseudoElement.ViewTransitionNew.rawValue:
        let argumentType = block.peekType(&s)
        let argument = block.consumeIncludingWhitespace(&s)
        guard block.atEnd else { return 0 }
        if let argument, argumentType == CSSParserSelectorTokenType.ident {
            if !WebCore.isValidCustomIdentifier(WebCore.CSSValueID(rawValue: s.identifier(argument)) ?? .Invalid)
                && pseudo != CSSParserPseudoElement.Highlight.rawValue
            {
                return 0
            }
            // These pseudo-elements have a style type.
            guard let type = cssParserStylePseudoElementType(pseudo) else { preconditionFailure() }
            s.setResultAtom(0, UInt32(truncatingIfNeeded: argument), .Value)
            return cssParserPseudoElementResult(type, hasName: true)
        }
        // Intentionally don't parse the universal selector here, because getComputedStyle() only supports returning
        // styles for unique identifiers.
        return 0
    case CSSParserPseudoElement.Picker.rawValue:
        guard cssParserConsumePickerArgument(&s, &block) != nil else { return 0 }
        s.setResultAtom(0, UInt32.max, .PickerSelectFunction)
        return cssParserPseudoElementResult(.UserAgentPartFallback, hasName: true)
    default:
        return 0
    }
}
