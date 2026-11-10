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

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.CacheValidation
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.Markable
internal import wtf.Core.Seconds
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch

/// `parseCacheControlDirectives()`: the directives of a `Cache-Control` value with its control characters and spaces
/// removed. The Pragma fallback for `noCache` is the caller's.
///
/// `value` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseCacheControlHeader8(_ value: WebCore.HTTPHeaderLatin1Span) -> WebCore.CacheControlDirectives {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return parseCacheControlHeaderBody(characters)
}

/// parseCacheControlHeader8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseCacheControlHeader16(_ value: WebCore.HTTPHeaderUTF16Span) -> WebCore.CacheControlDirectives {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return parseCacheControlHeaderBody(characters)
}

@inline(always)
private func parseCacheControlHeaderBody<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>
) -> WebCore.CacheControlDirectives {
    let directives = httpCacheControlDirectiveValues(characters)
    var result = WebCore.CacheControlDirectives()
    result.noCache = directives.noCache
    result.noStore = directives.noStore
    result.isPublic = directives.isPublic
    result.mustRevalidate = directives.mustRevalidate
    result.immutable = directives.immutable
    if let maxAge = directives.maxAge {
        result.maxAge = .init(WTF.Seconds(maxAge))
    }
    switch directives.maxStale {
    case .none:
        break
    case .infinity:
        result.maxStale = .init(WTF.Seconds.infinity())
    case .value(let maxStale):
        result.maxStale = .init(WTF.Seconds(maxStale))
    }
    if let minFresh = directives.minFresh {
        result.minFresh = .init(WTF.Seconds(minFresh))
    }
    if let staleWhileRevalidate = directives.staleWhileRevalidate {
        result.staleWhileRevalidate = .init(WTF.Seconds(staleWhileRevalidate))
    }
    return result
}

// Cache-Control: the header's directives and their values, for parseCacheControlDirectives.

enum HTTPCacheControlMaxStale: Equatable {
    case none
    /// max-stale without a value: Seconds::infinity().
    case infinity
    /// The first max-stale value that `StringView::toDouble` parses.
    case value(Double)
}

/// The directives, over the Cache-Control value once its control characters and spaces are removed. Each number is the
/// first value of its directive that `StringView::toDouble` parses, nil when none does. The Pragma fallback for
/// `noCache` is the caller's.
struct HTTPCacheControlDirectiveValues: Equatable {
    var noCache = false
    var noStore = false
    var isPublic = false
    var mustRevalidate = false
    var immutable = false
    var maxAge: Double?
    var maxStale = HTTPCacheControlMaxStale.none
    var minFresh: Double?
    var staleWhileRevalidate: Double?
}

func httpCacheControlDirectiveValues<CodeUnit: HTTPHeaderStringCodeUnit>(_ safeHeader: Span<CodeUnit>) -> HTTPCacheControlDirectiveValues {
    // Positions here are at most `max`: wrapping arithmetic cannot wrap.
    var result = HTTPCacheControlDirectiveValues()
    let max = safeHeader.count
    var position = 0
    let noValue = HTTPHeaderSubstringExtent(start: max, length: 0)
    while position < max {
        // The directive ends at its first separator. ',' and '=' are separators, so the first ',' or '=' is there or
        // after it.
        let directive = trimToNextCacheHeaderSeparator(safeHeader, HTTPHeaderSubstringExtent(start: position, length: max &- position))
        let next = findCacheHeaderCommaOrEqualSign(safeHeader, from: directive.end)
        if next == max {
            // The last directive, with an empty value.
            applyCacheControlDirective(&result, safeHeader, directive, noValue)
            return result
        }
        position = next &+ 1
        if HTTPHeaderCodeUnits.value(safeHeader[next]) == 0x2C {
            // A directive with an empty value.
            applyCacheControlDirective(&result, safeHeader, directive, noValue)
            continue
        }
        if position < max && HTTPHeaderCodeUnits.value(safeHeader[position]) == 0x22 {
            // A quoted string.
            guard let nextDoubleQuote = findCacheHeaderCharacter(safeHeader, 0x22, from: position + 1) else {
                // Unterminated: the rest, to the next separator.
                applyCacheControlDirective(
                    &result,
                    safeHeader,
                    directive,
                    trimToNextCacheHeaderSeparator(safeHeader, HTTPHeaderSubstringExtent(start: position + 1, length: max - (position + 1)))
                )
                return result
            }
            // Without its quotes.
            applyCacheControlDirective(
                &result,
                safeHeader,
                directive,
                HTTPHeaderSubstringExtent(start: position + 1, length: nextDoubleQuote - (position + 1))
            )
            position = nextDoubleQuote + 1
            // Past the next comma; anything left with no comma is ignored.
            guard let nextComma = findCacheHeaderCharacter(safeHeader, 0x2C, from: position) else {
                return result
            }
            position = nextComma + 1
            continue
        }
        // A token, up to the next comma, which is at its first separator or after it.
        let value = trimToNextCacheHeaderSeparator(safeHeader, HTTPHeaderSubstringExtent(start: position, length: max &- position))
        applyCacheControlDirective(&result, safeHeader, directive, value)
        guard let nextComma = findCacheHeaderCharacter(safeHeader, 0x2C, from: value.end) else {
            return result
        }
        position = nextComma + 1
    }
    return result
}

private func applyCacheControlDirective<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ result: inout HTTPCacheControlDirectiveValues,
    _ header: Span<CodeUnit>,
    _ directive: HTTPHeaderSubstringExtent,
    _ value: HTTPHeaderSubstringExtent
) {
    guard directive.length > 0 else {
        return
    }
    // The directives with this length and first letter, in either case: no-cache and no-store share both, as do
    // max-stale and min-fresh.
    switch directive.length << 8 | Int(HTTPHeaderCodeUnits.value(header[directive.start]) | 0x20) {
    case 6 << 8 | 0x70: // 'p'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "public") {
            result.isPublic = true
        }
    case 7 << 8 | 0x6D: // 'm'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "max-age") && result.maxAge == nil {
            result.maxAge = wholeDouble(header, value)
        }
    case 8 << 8 | 0x6E: // 'n'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "no-cache") {
            // A no-cache directive with a value is only meaningful for proxy caches.
            if value.length == 0 {
                result.noCache = true
            }
        } else if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "no-store") {
            result.noStore = true
        }
    case 9 << 8 | 0x69: // 'i'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "immutable") {
            result.immutable = true
        }
    case 9 << 8 | 0x6D: // 'm'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "max-stale") {
            if result.maxStale != .none {
                return
            }
            if value.length == 0 {
                result.maxStale = .infinity
            } else if let maxStale = wholeDouble(header, value) {
                result.maxStale = .value(maxStale)
            }
        } else if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "min-fresh") && result.minFresh == nil {
            result.minFresh = wholeDouble(header, value)
        }
    case 15 << 8 | 0x6D: // 'm'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "must-revalidate") {
            result.mustRevalidate = true
        }
    case 22 << 8 | 0x73: // 's'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "stale-while-revalidate")
            && result.staleWhileRevalidate == nil
        {
            result.staleWhileRevalidate = wholeDouble(header, value)
        }
    default:
        break
    }
}

/// `StringView::toDouble(bool&)` of the value: the number when it takes every character after the leading whitespace.
private func wholeDouble<CodeUnit: HTTPHeaderStringCodeUnit>(_ header: Span<CodeUnit>, _ value: HTTPHeaderSubstringExtent) -> Double? {
    guard let number = httpHeaderToDouble(header.extracting(value.start..<value.end)), number.isWhole else {
        return nil
    }
    return number.value
}

private func findCacheHeaderCharacter<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ header: Span<CodeUnit>,
    _ character: UInt32,
    from start: Int
) -> Int? {
    var index = start
    while index < header.count {
        if HTTPHeaderCodeUnits.value(header[index]) == character {
            return index
        }
        index += 1
    }
    return nil
}

/// The index of the first ',' or '=' at or after `start`, or the count when there is none.
private func findCacheHeaderCommaOrEqualSign<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ header: Span<CodeUnit>,
    from start: Int
) -> Int {
    var index = start
    while index < header.count {
        let c = HTTPHeaderCodeUnits.value(header[index])
        if c == 0x2C || c == 0x3D {
            return index
        }
        index += 1
    }
    return index
}

/// The view up to its first separator.
private func trimToNextCacheHeaderSeparator<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ header: Span<CodeUnit>,
    _ view: HTTPHeaderSubstringExtent
) -> HTTPHeaderSubstringExtent {
    HTTPHeaderCodeUnits.extent(upToFirstOf: HTTPCacheHeaderSeparators.self, in: header, from: view.start, to: view.end)
}

/// RFC 7230's separators (section 3.2.6): the delimiters, space and tab.
private enum HTTPCacheHeaderSeparators: HTTPHeaderCharacterClass {
    /// Bit `c` of a 128-bit mask of tab, space and `"(),/:;<=>?@[\]{}`, whose first word holds 0x00 to 0x3F and second
    /// 0x40 to 0x7F.
    @inline(always)
    static func contains(_ c: UInt32) -> Bool {
        let word: UInt64 = c < 0x40 ? 0xFC00_9305_0000_0200 : 0x2800_0000_3800_0001
        return c < 0x80 && (word &>> UInt64(c & 0x3F)) & 1 != 0
    }

    @inline(always)
    static func lanes(in codeUnits: SIMD16<UInt8>) -> SIMD16<UInt8> {
        HTTPHeaderLanes.delimiters(codeUnits) | HTTPHeaderLanes.equal(codeUnits, 0x20) | HTTPHeaderLanes.equal(codeUnits, 0x09)
    }
}
