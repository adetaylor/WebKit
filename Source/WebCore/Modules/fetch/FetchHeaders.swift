// Copyright (C) 2016 Canon Inc.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted, provided that the following conditions
// are required to be met:
//
// 1.  Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
// 3.  Neither the name of Canon Inc. nor the names of
//     its contributors may be used to endorse or promote products derived
//     from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY CANON INC. AND ITS CONTRIBUTORS "AS IS" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL CANON INC. AND ITS CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.Exception
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.FetchHeadersGuard
internal import WebCore_Private.Core.HTTPHeaderMap
internal import WebCore_Private.Core.HTTPHeaderNames
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

// MARK: - Headers: append, delete, set, get, has

/// `FetchHeaders::append()` after its update counter is raised: appends `value`, trimmed of HTTP whitespace, to the
/// header named `name` (https://fetch.spec.whatwg.org/#concept-headers-append), or to the Set-Cookie values.
/// `FetchHeaders::fill(const Init&)` and `create()` apply each pair of their init with it.
///
/// `headers` and `setCookieValues` are the `FetchHeaders`' `m_headers` and `m_setCookieValues`, passed by its member,
/// or `create()`'s two locals before the object exists. Only this function changes them during the call, through
/// their own members (`HTTPHeaderMap`'s `set()` and `remove()`, `Vector`'s `append()`; it reads the map with
/// `valueForName()`); the other C++ it calls (`findHTTPHeaderName()`, String functions) does not reach the
/// `FetchHeaders` or the init being read.
@_expose(Cxx)
func appendToHeaderMap(
    _ name: consuming WTF.String,
    _ value: consuming WTF.String,
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if fetchHeadersIsSetCookie(name, nameCharacters) {
        let trimmedValue = fetchHeadersTrim(value)
        let decision = fetchHeadersSetCookieDecision(trimmedValue.isValid, headersGuard)
        guard case .write = decision else {
            return fetchHeadersSetCookieResult(decision, value, trimmedValue.range)
        }
        setCookieValues.append(consuming: fetchHeadersTrimmedString(value, trimmedValue))
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }

    // The value the header would have is the trimmed value itself when the map has no such header yet.
    let existingValue = headers.valueForName(name)
    if existingValue.isNull() {
        let trimmedValue: FetchHeadersTrimmedValue
        let decision: FetchHeadersDecision
        do {
            let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
            trimmedValue = fetchHeadersTrim(value, valueCharacters)
            decision = fetchHeadersCanWriteHeader(
                name,
                nameCharacters,
                value,
                valueCharacters,
                trimmedValue,
                value,
                trimmedValue.range,
                headersGuard
            )
        }
        guard case .write = decision else {
            return fetchHeadersResult(decision, name, value, trimmedValue.range)
        }
        headers.set(name, fetchHeadersTrimmedString(value, trimmedValue))
    } else {
        let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
        let trimmedValue = fetchHeadersTrim(value, valueCharacters)
        let combinedValue = fetchHeadersMakeString(
            fetchHeadersNoCharacters,
            existingValue,
            WebCore.securityPoliciesSpan8(existingValue),
            nil,
            fetchHeadersCommaSpace,
            value,
            valueCharacters,
            trimmedValue.range,
            fetchHeadersNoCharacters
        )
        let decision = fetchHeadersCanWriteHeader(
            name,
            nameCharacters,
            value,
            valueCharacters,
            trimmedValue,
            combinedValue,
            nil,
            headersGuard
        )
        guard case .write = decision else {
            return fetchHeadersResult(decision, name, value, trimmedValue.range)
        }
        headers.set(name, combinedValue)
    }

    if headersGuard == .RequestNoCors {
        // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
        headers.remove(WebCore.HTTPHeaderName.Range)
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::remove()`: https://fetch.spec.whatwg.org/#dom-headers-delete. `updateCounter` is raised once the
/// checks pass.
///
/// `headers`, `setCookieValues` and `updateCounter` are the `FetchHeaders`' `m_headers`, `m_setCookieValues` and
/// `m_updateCounter`, passed by its member. Only this function changes them during the call, through their own
/// members (`HTTPHeaderMap`'s `remove()`, `Vector`'s `clear()`); the other C++ it calls (`findHTTPHeaderName()`)
/// does not reach the `FetchHeaders`.
@_expose(Cxx)
func fetchHeadersRemove(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard,
    _ updateCounter: inout UInt64,
    _ name: consuming WTF.String
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    }
    if headersGuard == .Immutable {
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersImmutableMessage()))
    }
    if headersGuard == .Request, fetchHeadersIsForbiddenHeaderName(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }
    if headersGuard == .RequestNoCors, !fetchHeadersIsNoCORSSafelistedRequestHeaderName(name),
        !fetchHeadersIsPriviledgedNoCORSRequestHeaderName(name, nameCharacters)
    {
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }
    if headersGuard == .Response, fetchHeadersIsForbiddenResponseHeaderName(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }

    // A uint64_t counter, which wraps as the C++'s would; it cannot reach 2^64 in practice.
    updateCounter &+= 1
    if fetchHeadersIsSetCookie(name, nameCharacters) {
        setCookieValues.clear()
    } else {
        headers.remove(name)
    }

    if headersGuard == .RequestNoCors {
        // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
        headers.remove(WebCore.HTTPHeaderName.Range)
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::set()`: sets the header named `name` to `value`, trimmed of HTTP whitespace, or makes it the only
/// Set-Cookie value. `updateCounter` is raised once the checks pass.
///
/// `headers`, `setCookieValues` and `updateCounter` are the `FetchHeaders`' `m_headers`, `m_setCookieValues` and
/// `m_updateCounter`, passed by its member. Only this function changes them during the call, through their own
/// members (`HTTPHeaderMap`'s `set()` and `remove()`, `Vector`'s `clear()` and `append()`); the other C++ it calls
/// (`findHTTPHeaderName()`, String functions) does not reach the `FetchHeaders`.
@_expose(Cxx)
func fetchHeadersSet(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard,
    _ updateCounter: inout UInt64,
    _ name: consuming WTF.String,
    _ value: consuming WTF.String
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    let trimmedValue: FetchHeadersTrimmedValue
    let decision: FetchHeadersDecision
    do {
        let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
        trimmedValue = fetchHeadersTrim(value, valueCharacters)
        decision = fetchHeadersCanWriteHeader(
            name,
            nameCharacters,
            value,
            valueCharacters,
            trimmedValue,
            value,
            trimmedValue.range,
            headersGuard
        )
    }
    guard case .write = decision else {
        return fetchHeadersResult(decision, name, value, trimmedValue.range)
    }

    // A uint64_t counter, which wraps as the C++'s would; it cannot reach 2^64 in practice.
    updateCounter &+= 1
    if fetchHeadersIsSetCookie(name, nameCharacters) {
        setCookieValues.clear()
        setCookieValues.append(consuming: fetchHeadersTrimmedString(value, trimmedValue))
    } else {
        headers.set(name, fetchHeadersTrimmedString(value, trimmedValue))
    }

    if headersGuard == .RequestNoCors {
        // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
        headers.remove(WebCore.HTTPHeaderName.Range)
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::get()` and `has()` of `name` read the map only when this is true: when `name` is a valid header name
/// other than `set-cookie`.
///
/// Otherwise fetchHeadersGet() and fetchHeadersHas() decide.
@_expose(Cxx)
func fetchHeadersNeedsLookup(_ name: consuming WTF.String) -> Bool {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return false
    }
    return !fetchHeadersIsSetCookie(name, nameCharacters)
}

/// `FetchHeaders::get()` of a `name` for which fetchHeadersNeedsLookup() is false: the `TypeError` for an invalid name,
/// else the Set-Cookie values joined with `", "` (the null String when there are none).
///
/// `setCookieValues` is the `FetchHeaders`' `m_setCookieValues`, passed by its `const` member, which this function only
/// reads (`isEmpty()`, `size()`, the subscript). Nothing changes it during the call: the other C++ this function calls
/// (String functions, `Exception`'s constructor) does not reach the `FetchHeaders`.
@_expose(Cxx)
func fetchHeadersGet(
    _ name: consuming WTF.String,
    _ setCookieValues: borrowing WebCore.SecurityPoliciesStringVector
) -> WebCore.SecurityPoliciesExceptionOrString {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrString(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    }

    if setCookieValues.isEmpty() {
        return WebCore.SecurityPoliciesExceptionOrString(consuming: WTF.String())
    }
    return WebCore.SecurityPoliciesExceptionOrString(consuming: fetchHeadersJoinedSetCookieValues(setCookieValues))
}

/// `FetchHeaders::has()` of a `name` for which fetchHeadersNeedsLookup() is false: the `TypeError` for an invalid name,
/// else `hasSetCookie`.
@_expose(Cxx)
func fetchHeadersHas(_ name: consuming WTF.String, _ hasSetCookie: Bool) -> WebCore.SecurityPoliciesExceptionOrBool {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrBool(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    }
    return WebCore.SecurityPoliciesExceptionOrBool(consuming: hasSetCookie)
}

// MARK: - Filling from other headers

/// `FetchHeaders::fill(const FetchHeaders&)`: appends each of the other object's headers, then each of its Set-Cookie
/// values, stopping at the first exception.
///
/// A header's value is checked trimmed of HTTP whitespace and added as it is.
///
/// `headers` and `setCookieValues` are the `FetchHeaders`' `m_headers` and `m_setCookieValues`, passed by its member;
/// only this function changes them during the call, through their own members (`HTTPHeaderMap`'s `add()`,
/// `addUncommonHeader()` and `remove()`, `Vector`'s `append()`). `source` is the other object's `m_headers`, and
/// `sourceSetCookieValues` its `m_setCookieValues`, which this function only reads (`commonHeadersSpan()`,
/// `uncommonHeadersSpan()`, `size()`, the subscript); the member passes a copy of itself as the other object when it is
/// filled from itself, so neither aliases what this function changes. The other C++ this function calls
/// (`findHTTPHeaderName()`, String functions) reaches neither object.
@_expose(Cxx)
func fetchHeadersFill(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard,
    _ source: borrowing WebCore.HTTPHeaderMap,
    _ sourceSetCookieValues: borrowing WebCore.SecurityPoliciesStringVector
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = source.commonHeadersSpan()
    for index in commonHeaders.indices {
        let decision = fetchHeadersCanAddCommonHeader(commonHeaders[index].key, commonHeaders[index].value, headersGuard)
        switch decision {
        case .write:
            break
        case .skip:
            continue
        default:
            return fetchHeadersResult(
                decision,
                WebCore.securityPoliciesHTTPHeaderNameString(commonHeaders[index].key),
                commonHeaders[index].value,
                fetchHeadersTrim(commonHeaders[index].value).range
            )
        }
        headers.add(commonHeaders[index].key, commonHeaders[index].value)
        if headersGuard == .RequestNoCors {
            // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
            headers.remove(WebCore.HTTPHeaderName.Range)
        }
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = source.uncommonHeadersSpan()
    for index in uncommonHeaders.indices {
        let decision = fetchHeadersCanAddHeader(uncommonHeaders[index].key, uncommonHeaders[index].value, headersGuard)
        switch decision {
        case .write:
            break
        case .skip:
            continue
        default:
            return fetchHeadersResult(
                decision,
                uncommonHeaders[index].key,
                uncommonHeaders[index].value,
                fetchHeadersTrim(uncommonHeaders[index].value).range
            )
        }
        headers.addUncommonHeader(uncommonHeaders[index].key, uncommonHeaders[index].value)
        if headersGuard == .RequestNoCors {
            // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
            headers.remove(WebCore.HTTPHeaderName.Range)
        }
    }

    for index in 0..<sourceSetCookieValues.size() {
        let value = sourceSetCookieValues[index]
        let decision = fetchHeadersSetCookieDecision(fetchHeadersIsValidHTTPHeaderValue(value), headersGuard)
        switch decision {
        case .write:
            setCookieValues.append(consuming: value)
        case .skip:
            break
        default:
            return fetchHeadersSetCookieResult(decision, value, nil)
        }
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::filterAndFill()`: adds each header of `source` that `headersGuard` lets a script write, as it is,
/// skipping the others and any that would throw.
///
/// `headers` is the `FetchHeaders`' `m_headers`, passed by its member; only this function changes it during the call,
/// through its own members (`HTTPHeaderMap`'s `add()` and `addUncommonHeader()`). `source` is the caller's map (a
/// response's or a WebTransport session's headers), never `headers`. The other C++ this function calls
/// (`findHTTPHeaderName()`, String functions) reaches neither map.
@_expose(Cxx)
func fetchHeadersFilterAndFill(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ source: borrowing WebCore.HTTPHeaderMap,
    _ headersGuard: WebCore.FetchHeadersGuard
) {
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = source.commonHeadersSpan()
    for index in commonHeaders.indices {
        guard case .write = fetchHeadersCanAddCommonHeader(commonHeaders[index].key, commonHeaders[index].value, headersGuard) else {
            continue
        }
        headers.add(commonHeaders[index].key, commonHeaders[index].value)
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = source.uncommonHeadersSpan()
    for index in uncommonHeaders.indices {
        guard case .write = fetchHeadersCanAddHeader(uncommonHeaders[index].key, uncommonHeaders[index].value, headersGuard) else {
            continue
        }
        headers.addUncommonHeader(uncommonHeaders[index].key, uncommonHeaders[index].value)
    }
}

// MARK: - Iteration

/// `FetchHeaders::Iterator::next()`: the next header, by name lowercased and sorted by code point, with one pair per
/// Set-Cookie value under `set-cookie`.
///
/// When `headersUpdateCounter` differs from the iterator's `updateCounter`, the names are gathered and sorted again and
/// the position moved to the same place among them.
///
/// `headers` is the iterated `FetchHeaders`' `m_headers`, and `setCookieValues` its `m_setCookieValues`, passed through
/// the iterator's reference to the object, which keeps the object alive for the call; this function only reads them
/// (`commonHeadersSpan()`, `uncommonHeadersSpan()`, `valueForName()`, `isEmpty()`, `size()`, the subscript). `keys` is
/// the iterator's `m_keys`, passed by its member: only this function changes it during the call, through its own
/// members (`shrink()`, `append()`). No script runs, and the other C++ this function calls (String functions,
/// `securityPoliciesSpan8()`, `lowercaseHTTPHeaderNameString()` and `securityPoliciesOptionalStringPair()`) reaches
/// neither the `FetchHeaders` nor the iterator.
@_expose(Cxx)
func fetchHeadersIteratorNext(
    _ headers: borrowing WebCore.HTTPHeaderMap,
    _ setCookieValues: borrowing WebCore.SecurityPoliciesStringVector,
    _ headersUpdateCounter: UInt64,
    _ keys: inout WebCore.SecurityPoliciesStringVector,
    _ currentIndex: inout UInt,
    _ setCookieIndex: inout UInt,
    _ updateCounter: inout UInt
) -> WebCore.SecurityPoliciesOptionalStringPair {
    // The iterator's counter is a size_t and the object's a uint64_t, compared and assigned as the C++ does.
    if keys.isEmpty() || UInt64(updateCounter) != headersUpdateCounter {
        let hasSetCookie = !setCookieValues.isEmpty()
        let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
        let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
        // A map holds fewer than 2^32 headers, so this cannot overflow.
        let count = commonHeaders.count &+ uncommonHeaders.count &+ (hasSetCookie ? 1 : 0)

        // The names are ordered on the stack when they fit there and no common header repeats, else sorted on the heap.
        keys.shrink(0)
        var setCookieKeyIndex: UInt = 0
        var codeUnitCount = Int.max
        var isOrdered = false
        if count <= FetchHeadersInlineIteratorNames.count {
            var inlineNames = FetchHeadersInlineIteratorNames(repeating: FetchHeadersIteratorName(start: 0, end: 0, source: 0))
            var inlineCodeUnits = FetchHeadersInlineIteratorCodeUnits(repeating: 0)
            var commonNameRanks: UInt128 = 0
            var hasRepeatedCommonName = false
            do {
                var names = inlineNames.mutableSpan
                var codeUnits = inlineCodeUnits.mutableSpan
                codeUnitCount = fetchHeadersWriteUncommonIteratorNames(
                    commonHeaders,
                    uncommonHeaders,
                    hasSetCookie,
                    &commonNameRanks,
                    &hasRepeatedCommonName,
                    &names,
                    &codeUnits
                )
            }
            if codeUnitCount <= FetchHeadersInlineIteratorCodeUnits.count, !hasRepeatedCommonName {
                var inlineOrder = FetchHeadersInlineIteratorOrder(repeating: 0)
                do {
                    var order = inlineOrder.mutableSpan
                    setCookieKeyIndex = UInt(
                        fetchHeadersOrderIteratorNames(
                            commonNameRanks,
                            inlineNames.span.extracting(0..<uncommonHeaders.count),
                            inlineCodeUnits.span,
                            hasSetCookie,
                            &order
                        )
                    )
                }
                let order = inlineOrder.span.extracting(0..<count)
                for position in order.indices {
                    keys.append(consuming: fetchHeadersOrderedIteratorKey(order[position], uncommonHeaders))
                }
                isOrdered = true
            }
        }
        if !isOrdered {
            if codeUnitCount == Int.max {
                // Only counted: no name fits in empty buffers.
                var noNames = UniqueArray<FetchHeadersIteratorName>()
                var noCodeUnits = UniqueArray<UInt16>()
                var names = noNames.mutableSpan
                var codeUnits = noCodeUnits.mutableSpan
                codeUnitCount = fetchHeadersWriteIteratorNames(
                    commonHeaders,
                    uncommonHeaders,
                    hasSetCookie,
                    count,
                    &names,
                    &codeUnits
                )
            }
            var heapNames = UniqueArray(repeating: FetchHeadersIteratorName(start: 0, end: 0, source: 0), count: count)
            var heapCodeUnits = UniqueArray<UInt16>(repeating: 0, count: codeUnitCount)
            do {
                var names = heapNames.mutableSpan
                var codeUnits = heapCodeUnits.mutableSpan
                _ = fetchHeadersWriteIteratorNames(
                    commonHeaders,
                    uncommonHeaders,
                    hasSetCookie,
                    count,
                    &names,
                    &codeUnits
                )
                fetchHeadersSortIteratorNames(&names, count, codeUnits.span)
            }
            let names = heapNames.span
            for position in names.indices {
                keys.append(consuming: fetchHeadersIteratorKey(names[position], commonHeaders, uncommonHeaders))
            }
            if hasSetCookie {
                setCookieKeyIndex = UInt(fetchHeadersSetCookieKeyIndex(names, heapCodeUnits.span))
            }
        }

        // Adjust the current index to work with Set-Cookie headers. This relies on the fact that
        // `currentIndex + setCookieIndex` gives you the current total index into the iteration.
        // Both are below the number of pairs already returned, so the sum cannot overflow.
        currentIndex &+= setCookieIndex
        if hasSetCookie {
            if currentIndex < setCookieKeyIndex {
                setCookieIndex = 0
            } else {
                setCookieIndex = min(currentIndex - setCookieKeyIndex, UInt(setCookieValues.size()))
                // setCookieIndex is at most currentIndex - setCookieKeyIndex.
                currentIndex &-= setCookieIndex
            }
        } else {
            setCookieIndex = 0
        }

        updateCounter = UInt(truncatingIfNeeded: headersUpdateCounter)
    }

    while currentIndex < UInt(keys.size()) {
        let key = keys[Int(currentIndex)]
        if key.isNull() {
            if setCookieIndex < UInt(setCookieValues.size()) {
                let value = setCookieValues[Int(setCookieIndex)]
                // Below the number of Set-Cookie values.
                setCookieIndex &+= 1
                return WebCore.securityPoliciesOptionalStringPair(
                    consuming: WTF.makeStringFromLatin1Characters(fetchHeadersSetCookieName.span),
                    consuming: value
                )
            }
            // Below keys.size().
            currentIndex &+= 1
            continue
        }
        // Below keys.size().
        currentIndex &+= 1
        let value = headers.valueForName(key)
        if !value.isNull() {
            return WebCore.securityPoliciesOptionalStringPair(consuming: key, consuming: value)
        }
    }
    return WebCore.SecurityPoliciesOptionalStringPair()
}

/// Room on the stack for the names of most maps: up to 16 names of 256 code units in all, and their sorted order.
///
/// More go on the heap.
private typealias FetchHeadersInlineIteratorNames = [16 of FetchHeadersIteratorName]
private typealias FetchHeadersInlineIteratorCodeUnits = [256 of UInt16]
private typealias FetchHeadersInlineIteratorOrder = [16 of UInt8]

/// One of the names the iterator sorts: its lowercased code units are `codeUnits[start..<end]`, and `source` is its
/// position in map order (common headers, uncommon headers, then the null String standing for the Set-Cookie values).
private struct FetchHeadersIteratorName {
    var start: Int
    var end: Int
    var source: Int
}

/// Writes the names of `uncommonHeaders` to `names` in map order, `source` being the index among them, each name's code
/// units lowercased with ASCII rules to `codeUnits` from the start (those past its end are not written), and sets the bit
/// of each common header name's rank in `commonNameRanks`, with `hasRepeatedCommonName` when it is set already.
///
/// Returns the number of code units of all the iterator's names, as fetchHeadersWriteIteratorNames() counts them.
private func fetchHeadersWriteUncommonIteratorNames(
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ hasSetCookie: Bool,
    _ commonNameRanks: inout UInt128,
    _ hasRepeatedCommonName: inout Bool,
    _ names: inout MutableSpan<FetchHeadersIteratorName>,
    _ codeUnits: inout MutableSpan<UInt16>
) -> Int {
    let offsets = fetchHeadersCommonNameOffsets.span
    let ranks = fetchHeadersCommonNameRanks.span
    var codeUnitCount = 0
    for index in commonHeaders.indices {
        let nameIndex = Int(commonHeaders[index].key.rawValue)
        // A rank is below the number of HTTPHeaderName's values, 103, so the shift is by less than 128.
        let rankBit = UInt128(1) &<< ranks[nameIndex]
        if commonNameRanks & rankBit != 0 {
            hasRepeatedCommonName = true
        }
        commonNameRanks |= rankBit
        // nameIndex is below the number of HTTPHeaderName's values, and the offsets have one more and increase; the code
        // units of fewer than 2^32 names, each shorter than 2^31, do not overflow.
        codeUnitCount &+= Int(offsets[nameIndex &+ 1]) &- Int(offsets[nameIndex])
    }
    var start = 0
    for index in uncommonHeaders.indices {
        let end = fetchHeadersWriteIteratorName(uncommonHeaders[index].key, start, &codeUnits)
        names[index] = FetchHeadersIteratorName(start: start, end: end, source: index)
        // Neither the code units of the uncommon names nor of all the names, as above, overflow.
        codeUnitCount &+= end &- start
        start = end
    }
    if hasSetCookie {
        // Likewise.
        codeUnitCount &+= fetchHeadersSetCookieName.count
    }
    return codeUnitCount
}

/// Writes the iterator's `count` names to `names` in map order, each name's code units lowercased with ASCII rules to
/// `codeUnits` (`set-cookie` stands for the Set-Cookie values, as `compareIteratorKeys()` reads the null String).
///
/// Returns the number of code units the names have; those past the end of `codeUnits` are not written.
private func fetchHeadersWriteIteratorNames(
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ hasSetCookie: Bool,
    _ count: Int,
    _ names: inout MutableSpan<FetchHeadersIteratorName>,
    _ codeUnits: inout MutableSpan<UInt16>
) -> Int {
    let fitsNames = count <= names.count
    var codeUnitCount = 0
    for index in commonHeaders.indices {
        let end = fetchHeadersWriteCommonIteratorName(commonHeaders[index].key, codeUnitCount, &codeUnits)
        if fitsNames {
            names[index] = FetchHeadersIteratorName(start: codeUnitCount, end: end, source: index)
        }
        codeUnitCount = end
    }
    for index in uncommonHeaders.indices {
        let end = fetchHeadersWriteIteratorName(uncommonHeaders[index].key, codeUnitCount, &codeUnits)
        if fitsNames {
            // Below count.
            let source = commonHeaders.count &+ index
            names[source] = FetchHeadersIteratorName(start: codeUnitCount, end: end, source: source)
        }
        codeUnitCount = end
    }
    if hasSetCookie {
        let setCookieName = fetchHeadersSetCookieName.span
        // The code units of fewer than 2^32 names, each shorter than 2^31, and these: no overflow.
        let end = codeUnitCount &+ setCookieName.count
        if end <= codeUnits.count {
            for index in setCookieName.indices {
                // Below end.
                codeUnits[codeUnitCount &+ index] = UInt16(setCookieName[index])
            }
        }
        if fitsNames {
            // count is the number of headers plus one here.
            names[count &- 1] = FetchHeadersIteratorName(start: codeUnitCount, end: end, source: count &- 1)
        }
        codeUnitCount = end
    }
    return codeUnitCount
}

/// Writes the code units of the common header name `name`, lowercased, to `codeUnits` from `start` on, when they fit in
/// `codeUnits`, from fetchHeadersCommonNameCharacters.
///
/// Returns the end of them.
private func fetchHeadersWriteCommonIteratorName(
    _ name: WebCore.HTTPHeaderName,
    _ start: Int,
    _ codeUnits: inout MutableSpan<UInt16>
) -> Int {
    let offsets = fetchHeadersCommonNameOffsets.span
    let index = Int(name.rawValue)
    // index is below the number of HTTPHeaderName's values, and the offsets have one more.
    let characters = fetchHeadersCommonNameCharacters.span.extracting(Int(offsets[index])..<Int(offsets[index &+ 1]))
    // The code units of fewer than 2^32 names, each shorter than 2^31: no overflow.
    let end = start &+ characters.count
    if end <= codeUnits.count {
        fetchHeadersWriteLowercased(characters, start, &codeUnits)
    }
    return end
}

/// Writes the code units of `name`, lowercased with ASCII rules, to `codeUnits` from `start` on, when they fit in
/// `codeUnits`.
///
/// Returns the end of them.
private func fetchHeadersWriteIteratorName(
    _ name: borrowing WTF.String,
    _ start: Int,
    _ codeUnits: inout MutableSpan<UInt16>
) -> Int {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !characters.isEmpty {
        // The code units of fewer than 2^32 names, each shorter than 2^31: no overflow.
        let end = start &+ characters.count
        if end <= codeUnits.count {
            fetchHeadersWriteLowercased(characters, start, &codeUnits)
        }
        return end
    }
    let units: Span<UInt16> = name.checkedSpan16()
    // The code units of fewer than 2^32 names, each shorter than 2^31: no overflow.
    let end = start &+ units.count
    if end <= codeUnits.count {
        fetchHeadersWriteLowercased(units, start, &codeUnits)
    }
    return end
}

/// Writes `characters`, lowercased with ASCII rules, to `codeUnits` from `start` on, where they fit: eight at a time, the
/// last eight overlapping the ones before them, when there are eight.
private func fetchHeadersWriteLowercased(
    _ characters: Span<UInt8>,
    _ start: Int,
    _ codeUnits: inout MutableSpan<UInt16>
) {
    if characters.count < 8 {
        for index in characters.indices {
            let character = UInt8(truncatingIfNeeded: HTTPHeaderCodeUnits.toASCIILower(UInt32(characters[index])))
            // Below the end the caller checked.
            codeUnits[start &+ index] = UInt16(character)
        }
        return
    }
    let bytes = characters.bytes
    var codeUnitBytes = codeUnits.mutableBytes
    // There are at least eight characters here.
    let lastOffset = characters.count &- 8
    var offset = 0
    while true {
        let word = fetchHeadersASCIILowercase(UInt64(littleEndian: bytes.load(fromByteOffset: offset, as: UInt64.self)))
        // Below the end the caller checked, which is at most codeUnits.count, so neither this nor the byte offsets overflow.
        let position = start &+ offset
        // Likewise.
        codeUnitBytes.storeBytes(of: fetchHeadersWidened(word).littleEndian, toByteOffset: position &* 2, as: UInt64.self)
        // Likewise.
        codeUnitBytes.storeBytes(of: fetchHeadersWidened(word >> 32).littleEndian, toByteOffset: position &* 2 &+ 8, as: UInt64.self)
        if offset == lastOffset {
            return
        }
        // Below lastOffset here, so this is below the characters' count.
        offset = min(offset &+ 8, lastOffset)
    }
}

/// Writes `units`, lowercased with ASCII rules, to `codeUnits` from `start` on, where they fit: four at a time, the last
/// four overlapping the ones before them, when there are four.
private func fetchHeadersWriteLowercased(_ units: Span<UInt16>, _ start: Int, _ codeUnits: inout MutableSpan<UInt16>) {
    if units.count < 4 {
        for index in units.indices {
            // Below the end the caller checked.
            codeUnits[start &+ index] = UInt16(truncatingIfNeeded: HTTPHeaderCodeUnits.toASCIILower(UInt32(units[index])))
        }
        return
    }
    let bytes = units.bytes
    var codeUnitBytes = codeUnits.mutableBytes
    // There are at least four units here.
    let lastOffset = units.count &- 4
    var offset = 0
    while true {
        // Below the units' count, a String's length.
        let word = fetchHeadersASCIILowercaseUnits(UInt64(littleEndian: bytes.load(fromByteOffset: offset &* 2, as: UInt64.self)))
        // Below the end the caller checked, which is at most codeUnits.count.
        codeUnitBytes.storeBytes(of: word.littleEndian, toByteOffset: (start &+ offset) &* 2, as: UInt64.self)
        if offset == lastOffset {
            return
        }
        // Below lastOffset here, so this is below the units' count.
        offset = min(offset &+ 4, lastOffset)
    }
}

/// The eight characters of `word`, the first in its lowest byte, with the ASCII capital letters lowercased.
///
/// A character's low seven bits plus 0x3F, and plus 0x25, reach its high bit when they are at least 'A', and above 'Z';
/// neither sum carries out of the character.
@inline(always)
private func fetchHeadersASCIILowercase(_ word: UInt64) -> UInt64 {
    let low = word & 0x7F7F_7F7F_7F7F_7F7F
    let isUpper = (low + 0x3F3F_3F3F_3F3F_3F3F) & ~(low + 0x2525_2525_2525_2525) & ~word & 0x8080_8080_8080_8080
    return word | isUpper >> 2
}

/// The four 16-bit code units of `word`, the first in its lowest bits, with the ASCII capital letters lowercased, as
/// fetchHeadersASCIILowercase() does with 0x7FBF and 0x7FA5.
@inline(always)
private func fetchHeadersASCIILowercaseUnits(_ word: UInt64) -> UInt64 {
    let low = word & 0x7FFF_7FFF_7FFF_7FFF
    let isUpper = (low + 0x7FBF_7FBF_7FBF_7FBF) & ~(low + 0x7FA5_7FA5_7FA5_7FA5) & ~word & 0x8000_8000_8000_8000
    return word | isUpper >> 10
}

/// The four low bytes of `word` as four 16-bit code units, the first in the lowest.
@inline(always)
private func fetchHeadersWidened(_ word: UInt64) -> UInt64 {
    (word & 0xFF) | (word & 0xFF00) << 8 | (word & 0xFF_0000) << 16 | (word & 0xFF00_0000) << 24
}

/// Sorts the first `count` of `names` by code point, keeping names that compare equal in their order (a header named
/// Set-Cookie before the null String): each name goes after the sorted names that are not above it.
private func fetchHeadersSortIteratorNames(_ names: inout MutableSpan<FetchHeadersIteratorName>, _ count: Int, _ codeUnits: Span<UInt16>) {
    var index = 1
    while index < count {
        let name = names[index]
        var low = 0
        var high = index
        while low < high {
            // Both are at most index, so neither the sum nor the difference overflows.
            let middle = low &+ (high &- low) / 2
            if fetchHeadersIteratorNameLessThan(codeUnits, name, names[middle]) {
                high = middle
            } else {
                // Below index.
                low = middle &+ 1
            }
        }
        var position = index
        while position > low {
            // position is above low, which is at least 0.
            names[position] = names[position &- 1]
            // Likewise.
            position &-= 1
        }
        names[low] = name
        // Below count.
        index &+= 1
    }
}

/// The order fetchHeadersSortIteratorNames() gives the iterator's names when no common header repeats: the common header
/// names whose ranks are set in `commonNameRanks`, the uncommon header names `names`, and with `hasSetCookie` the null
/// String standing for the Set-Cookie values, at most 16 names in all.
///
/// A common name sorts before an uncommon name equal to it, and both before the null String, as in map order.
/// `order[position]` is the raw value of the common header name sorted to `position`,
/// `fetchHeadersUncommonIteratorName` plus the index of an uncommon header name, or
/// `fetchHeadersSetCookieIteratorName`. With `hasSetCookie`, returns the number of names below `set-cookie`, as
/// fetchHeadersSetCookieKeyIndex() counts them; else returns 0.
private func fetchHeadersOrderIteratorNames(
    _ commonNameRanks: UInt128,
    _ names: Span<FetchHeadersIteratorName>,
    _ codeUnits: Span<UInt16>,
    _ hasSetCookie: Bool,
    _ order: inout MutableSpan<UInt8>
) -> Int {
    let setCookieRank = Int(fetchHeadersCommonNameRanks.span[Int(WebCore.HTTPHeaderName.SetCookie.rawValue)])
    // A rank is below 103: no overflow.
    let setCookieUpperBound = setCookieRank &+ 1
    // Each uncommon name's number of HTTPHeaderName's names not above it, which is the number of ranks below it.
    var inlineUpperBounds = FetchHeadersInlineIteratorOrder(repeating: 0)
    var uncommonNamesBelowSetCookie = 0
    var uncommonNamesAboveSetCookie = 0
    var isAboveSetCookie: UInt16 = 0
    do {
        var upperBounds = inlineUpperBounds.mutableSpan
        for index in names.indices {
            let name = codeUnits.extracting(names[index].start..<names[index].end)
            let upperBound = fetchHeadersCommonNameUpperBound(name)
            upperBounds[index] = UInt8(truncatingIfNeeded: upperBound)
            if !hasSetCookie {
                continue
            }
            if upperBound < setCookieUpperBound {
                // At most 16 names: neither count overflows.
                uncommonNamesBelowSetCookie &+= 1
            } else if upperBound > setCookieUpperBound || crossOriginAccessControlCodePointLessThan(fetchHeadersSetCookieName.span, name) {
                // Likewise.
                uncommonNamesAboveSetCookie &+= 1
                // index is below 16, so the shift is exact.
                isAboveSetCookie |= 1 &<< index
            }
        }
    }
    let upperBounds = inlineUpperBounds.span
    for index in names.indices {
        var position = fetchHeadersRanksBelow(commonNameRanks, Int(upperBounds[index]))
        for other in names.indices {
            // At most 16 names: no overflow.
            position &+= other != index && fetchHeadersIteratorNameSortsBefore(codeUnits, names[other], other, names[index], index) ? 1 : 0
        }
        if isAboveSetCookie >> index & 1 != 0 {
            // Below 16.
            position &+= 1
        }
        order[position] = fetchHeadersUncommonIteratorName | UInt8(truncatingIfNeeded: index)
    }
    let namesByRank = fetchHeadersCommonNamesByRank.span
    var remainingRanks = commonNameRanks
    var commonNamesBefore = 0
    while remainingRanks != 0 {
        let rank = remainingRanks.trailingZeroBitCount
        var position = commonNamesBefore
        for index in names.indices {
            // At most 16 names: no overflow.
            position &+= Int(upperBounds[index]) <= rank ? 1 : 0
        }
        if hasSetCookie, rank > setCookieRank {
            // Below 16.
            position &+= 1
        }
        order[position] = namesByRank[rank]
        // Likewise.
        commonNamesBefore &+= 1
        // remainingRanks is not 0.
        remainingRanks &= remainingRanks &- 1
    }
    if !hasSetCookie {
        return 0
    }
    // At most 16 names: none of these overflows.
    order[fetchHeadersRanksBelow(commonNameRanks, setCookieUpperBound) &+ names.count &- uncommonNamesAboveSetCookie] =
        fetchHeadersSetCookieIteratorName
    // Likewise.
    return fetchHeadersRanksBelow(commonNameRanks, setCookieRank) &+ uncommonNamesBelowSetCookie
}

/// What fetchHeadersOrderIteratorNames() writes for an uncommon header name, plus its index, and for the null String.
private let fetchHeadersUncommonIteratorName: UInt8 = 0x80
private let fetchHeadersSetCookieIteratorName: UInt8 = 0xFF

/// The number of ranks below `rank` set in `ranks`.
@inline(always)
private func fetchHeadersRanksBelow(_ ranks: UInt128, _ rank: Int) -> Int {
    // rank is at most the number of HTTPHeaderName's values, 103, so the shift is by less than 128.
    (ranks & ~(UInt128.max &<< rank)).nonzeroBitCount
}

/// The number of HTTPHeaderName's names, lowercased, that are not above `name` by code point, as `std::ranges::upper_bound`
/// finds it among them sorted.
///
/// `name`'s prefix, made as fetchHeadersCommonNamePrefixesByRank's are, orders it against each name whose prefix
/// differs from it; a name with the same prefix is compared by code point.
private func fetchHeadersCommonNameUpperBound(_ name: Span<UInt16>) -> Int {
    let namesByRank = fetchHeadersCommonNamesByRank.span
    let prefixes = fetchHeadersCommonNamePrefixesByRank.span
    let offsets = fetchHeadersCommonNameOffsets.span
    let characters = fetchHeadersCommonNameCharacters.span
    // A code unit above 0xFF is taken as 0xFF: either is above every character of the names.
    var prefix: UInt64 = 0
    for position in 0..<8 {
        prefix <<= 8
        if position < name.count {
            prefix |= UInt64(min(name[position], 0xFF))
        }
    }
    var first = 0
    var remaining = namesByRank.count
    while remaining > 0 {
        let step = remaining / 2
        // first + step is below namesByRank.count.
        let middle = first &+ step
        let isBelow: Bool
        if prefix != prefixes[middle] {
            isBelow = prefix < prefixes[middle]
        } else {
            let index = Int(namesByRank[middle])
            // index is below the number of HTTPHeaderName's values, and the offsets have one more.
            isBelow = crossOriginAccessControlCodePointLessThan(name, characters.extracting(Int(offsets[index])..<Int(offsets[index &+ 1])))
        }
        if isBelow {
            remaining = step
        } else {
            // middle is below namesByRank.count, and step + 1 at most remaining.
            first = middle &+ 1
            // Likewise.
            remaining &-= step &+ 1
        }
    }
    return first
}

/// The key of the name fetchHeadersOrderIteratorNames() writes as `name`: a common header's name lowercased, an uncommon
/// header's name lowercased, or the null String standing for the Set-Cookie values.
private func fetchHeadersOrderedIteratorKey(_ name: UInt8, _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>) -> WTF.String {
    if name < fetchHeadersUncommonIteratorName {
        // What convertToASCIILowercase() makes of httpHeaderNameString(); name is the raw value of one of HTTPHeaderName's
        // values, from fetchHeadersCommonNamesByRank.
        return WebCore.lowercaseHTTPHeaderNameString(WebCore.HTTPHeaderName(rawValue: UInt16(name))!)
    }
    if name == fetchHeadersSetCookieIteratorName {
        return WTF.String()
    }
    return uncommonHeaders[Int(name & ~fetchHeadersUncommonIteratorName)].key.convertToASCIILowercase()
}

/// Whether name `a`, at `aIndex` in map order, sorts before name `b`, at `bIndex`: fetchHeadersIteratorNameLessThan(),
/// and map order for equal names.
private func fetchHeadersIteratorNameSortsBefore(
    _ codeUnits: Span<UInt16>,
    _ a: FetchHeadersIteratorName,
    _ aIndex: Int,
    _ b: FetchHeadersIteratorName,
    _ bIndex: Int
) -> Bool {
    if fetchHeadersIteratorNameLessThan(codeUnits, a, b) {
        return true
    }
    return !fetchHeadersIteratorNameLessThan(codeUnits, b, a) && aIndex < bIndex
}

/// The first position among the sorted `names` whose name is not below `set-cookie`, as `std::ranges::lower_bound`
/// finds it.
private func fetchHeadersSetCookieKeyIndex(_ names: Span<FetchHeadersIteratorName>, _ codeUnits: Span<UInt16>) -> Int {
    var first = 0
    var remaining = names.count
    while remaining > 0 {
        let step = remaining / 2
        // first + step is below names.count.
        let middle = first &+ step
        let name = names[middle]
        if crossOriginAccessControlCodePointLessThan(codeUnits.extracting(name.start..<name.end), fetchHeadersSetCookieName.span) {
            // middle is below names.count, and step + 1 at most remaining.
            first = middle &+ 1
            // Likewise.
            remaining &-= step &+ 1
        } else {
            remaining = step
        }
    }
    return first
}

/// `compareIteratorKeys()` of two of the names the iterator sorts: `WTF::codePointCompareLessThan()` of their code units,
/// four at a time, the last four overlapping the ones before them, while both have four.
private func fetchHeadersIteratorNameLessThan(
    _ codeUnits: Span<UInt16>,
    _ a: FetchHeadersIteratorName,
    _ b: FetchHeadersIteratorName
) -> Bool {
    // Each name lies within codeUnits, so none of these offsets overflows.
    let aCount = a.end &- a.start
    // Likewise.
    let bCount = b.end &- b.start
    let commonLength = min(aCount, bCount)
    if commonLength < 4 {
        var position = 0
        while position < commonLength {
            // Below a.end and b.end.
            let aCodeUnit = codeUnits[a.start &+ position]
            // Likewise.
            let bCodeUnit = codeUnits[b.start &+ position]
            if aCodeUnit != bCodeUnit {
                return aCodeUnit < bCodeUnit
            }
            // Below commonLength.
            position &+= 1
        }
        return aCount < bCount
    }
    let bytes = codeUnits.bytes
    // commonLength is at least 4 here.
    let lastOffset = commonLength &- 4
    var offset = 0
    while true {
        // Below a.end, at most codeUnits.count, so neither the position nor its byte offset overflows.
        let aWord = UInt64(littleEndian: bytes.load(fromByteOffset: (a.start &+ offset) &* 2, as: UInt64.self))
        // Likewise for b.
        let bWord = UInt64(littleEndian: bytes.load(fromByteOffset: (b.start &+ offset) &* 2, as: UInt64.self))
        if aWord != bWord {
            // The code units before this word are equal, and the first that differs is the lowest one that does.
            let shift = UInt64((aWord ^ bWord).trailingZeroBitCount / 16 * 16)
            return (aWord >> shift) & 0xFFFF < (bWord >> shift) & 0xFFFF
        }
        if offset == lastOffset {
            return aCount < bCount
        }
        // Below lastOffset here, so this is below commonLength.
        offset = min(offset &+ 4, lastOffset)
    }
}

/// The key of `name` among the sorted names: a common header's name lowercased, an uncommon header's name lowercased, or
/// the null String standing for the Set-Cookie values.
private func fetchHeadersIteratorKey(
    _ name: FetchHeadersIteratorName,
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>
) -> WTF.String {
    if name.source < commonHeaders.count {
        // What convertToASCIILowercase() makes of httpHeaderNameString().
        return WebCore.lowercaseHTTPHeaderNameString(commonHeaders[name.source].key)
    }
    // source is at least commonHeaders.count here.
    let uncommonIndex = name.source &- commonHeaders.count
    if uncommonIndex < uncommonHeaders.count {
        return uncommonHeaders[uncommonIndex].key.convertToASCIILowercase()
    }
    return WTF.String()
}

// MARK: - The checks

/// What `canWriteHeader()` and `appendSetCookie()` decide.
///
/// The last three are a `TypeError`, whose message names the header and its value as the C++ does
/// (fetchHeadersResult(), fetchHeadersSetCookieResult()).
private enum FetchHeadersDecision {
    case write
    case skip
    case invalidName
    case invalidValue
    case immutable
}

/// A header value trimmed of HTTP whitespace, as `String::trim(isASCIIWhitespaceWithoutFF)` trims it: the trimmed value
/// is the value's code units `range`, of `length`.
private struct FetchHeadersTrimmedValue {
    var range: Range<Int>
    var length: Int
    /// Whether the trimmed value is a valid header value.
    var isValid: Bool
}

/// `canWriteHeader()`: the checks a header passes before a script may write it under `headersGuard`, in the order
/// the C++ makes them. `value` is checked trimmed; the RequestNoCors check reads the value's code units
/// `combinedValueRange` when there is one, else `combinedValue`. `nameCharacters` and `valueCharacters` are what
/// securityPoliciesSpan8() reads of `name` and `value`.
private func fetchHeadersCanWriteHeader(
    _ name: borrowing WTF.String,
    _ nameCharacters: Span<UInt8>,
    _ value: borrowing WTF.String,
    _ valueCharacters: Span<UInt8>,
    _ trimmedValue: FetchHeadersTrimmedValue,
    _ combinedValue: borrowing WTF.String,
    _ combinedValueRange: Range<Int>?,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> FetchHeadersDecision {
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return .invalidName
    }
    if !trimmedValue.isValid {
        return .invalidValue
    }
    if headersGuard == .Immutable {
        return .immutable
    }
    if headersGuard == .Request, fetchHeadersIsForbiddenHeader(name, nameCharacters, value, valueCharacters, trimmedValue.range) {
        return .skip
    }
    if headersGuard == .RequestNoCors {
        let isSimpleHeader =
            if let combinedValueRange {
                fetchHeadersIsSimpleHeader(name, value, valueCharacters, combinedValueRange)
            } else {
                fetchHeadersIsSimpleHeader(name, combinedValue, WebCore.securityPoliciesSpan8(combinedValue), nil)
            }
        if !isSimpleHeader {
            return .skip
        }
    }
    if headersGuard == .Response, fetchHeadersIsForbiddenResponseHeaderName(name, nameCharacters) {
        return .skip
    }
    return .write
}

/// canWriteHeader() of an uncommon header of another map, `name` with `value`: the value is checked trimmed and, under
/// RequestNoCors, as it is.
private func fetchHeadersCanAddHeader(
    _ name: borrowing WTF.String,
    _ value: borrowing WTF.String,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> FetchHeadersDecision {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    let trimmedValue = fetchHeadersTrim(value, valueCharacters)
    return fetchHeadersCanWriteHeader(
        name,
        nameCharacters,
        value,
        valueCharacters,
        trimmedValue,
        value,
        0..<trimmedValue.length,
        headersGuard
    )
}

/// fetchHeadersCanAddHeader() of a common header of another map, named `name`, with `value`.
///
/// A known name is a valid token, and the checks of a name ignore ASCII case, so they read its lowercased characters
/// from fetchHeadersCommonNameCharacters.
private func fetchHeadersCanAddCommonHeader(
    _ name: WebCore.HTTPHeaderName,
    _ value: borrowing WTF.String,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> FetchHeadersDecision {
    let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    let trimmedValue = fetchHeadersTrim(value, valueCharacters)
    if !trimmedValue.isValid {
        return .invalidValue
    }
    if headersGuard == .Immutable {
        return .immutable
    }
    let offsets = fetchHeadersCommonNameOffsets.span
    let index = Int(name.rawValue)
    // index is below the number of HTTPHeaderName's values, and the offsets have one more.
    let nameCharacters = fetchHeadersCommonNameCharacters.span.extracting(Int(offsets[index])..<Int(offsets[index &+ 1]))
    if headersGuard == .Request {
        let isForbidden: Bool
        if !valueCharacters.isEmpty {
            isForbidden = FetchHeaderChecks.isForbiddenHeader(
                isKnown: true,
                headerName: name,
                nameCharacters,
                valueCharacters.extracting(trimmedValue.range)
            )
        } else {
            let valueUnits: Span<UInt16> = value.checkedSpan16()
            isForbidden = FetchHeaderChecks.isForbiddenHeader(
                isKnown: true,
                headerName: name,
                nameCharacters,
                valueUnits.extracting(trimmedValue.range)
            )
        }
        if isForbidden {
            return .skip
        }
    }
    if headersGuard == .RequestNoCors {
        let isSimpleHeader: Bool
        if !valueCharacters.isEmpty {
            isSimpleHeader = isCrossOriginSafeRequestHeaderBody(name, valueCharacters)
        } else {
            let valueUnits: Span<UInt16> = value.checkedSpan16()
            isSimpleHeader = isCrossOriginSafeRequestHeaderBody(name, valueUnits)
        }
        if !isSimpleHeader {
            return .skip
        }
    }
    if headersGuard == .Response, FetchHeaderChecks.isForbiddenResponseHeaderName(nameCharacters) {
        return .skip
    }
    return .write
}

/// The checks `appendSetCookie()` makes of a value: `.write` to append it, which only the None guard keeps.
private func fetchHeadersSetCookieDecision(_ isValidValue: Bool, _ headersGuard: WebCore.FetchHeadersGuard) -> FetchHeadersDecision {
    if !isValidValue {
        return .invalidValue
    }
    if headersGuard == .Immutable {
        return .immutable
    }
    return headersGuard == .None ? .write : .skip
}

/// What canWriteHeader() returns for a decision other than `.write`: nothing for `.skip`, else the `TypeError` for the
/// header `name` with `value`, checked as its code units `valueRange`.
private func fetchHeadersResult(
    _ decision: FetchHeadersDecision,
    _ name: borrowing WTF.String,
    _ value: borrowing WTF.String,
    _ valueRange: Range<Int>
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    switch decision {
    case .write, .skip:
        return WebCore.SecurityPoliciesExceptionOrVoid()
    case .invalidName:
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    case .invalidValue:
        // An invalid value is not empty, so its trimmed String has its width.
        let message = fetchHeadersMakeString(
            fetchHeadersInvalidValuePrefix,
            name,
            WebCore.securityPoliciesSpan8(name),
            nil,
            fetchHeadersInvalidValueMiddle,
            value,
            WebCore.securityPoliciesSpan8(value),
            valueRange,
            fetchHeadersQuote
        )
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(message))
    case .immutable:
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersImmutableMessage()))
    }
}

/// What appendSetCookie() returns for a decision other than `.write`: nothing for `.skip`, else a `TypeError`, whose
/// message for `.invalidValue` names `value`, or its code units `valueRange` when there is one.
private func fetchHeadersSetCookieResult(
    _ decision: FetchHeadersDecision,
    _ value: borrowing WTF.String,
    _ valueRange: Range<Int>?
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    switch decision {
    case .write, .skip:
        return WebCore.SecurityPoliciesExceptionOrVoid()
    case .invalidValue:
        let message = fetchHeadersMakeString(
            fetchHeadersInvalidSetCookieValuePrefix,
            value,
            WebCore.securityPoliciesSpan8(value),
            valueRange,
            fetchHeadersQuote,
            WTF.String(),
            Span(),
            nil,
            fetchHeadersNoCharacters
        )
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(message))
    case .invalidName, .immutable:
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersImmutableMessage()))
    }
}

/// `findHTTPHeaderName()` of `name`.
private func fetchHeadersHeaderName(_ name: borrowing WTF.String) -> WebCore.HTTPHeaderName? {
    // What `HTTPHeaderName headerName { }` holds; findHTTPHeaderName() writes it only when it finds the name.
    var headerName = WebCore.HTTPHeaderName.Accept
    if WebCore.securityPoliciesFindHTTPHeaderName(name, &headerName) {
        return headerName
    }
    return nil
}

/// `isValidHTTPToken(const String&)` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsValidHTTPToken(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return HTTPHeaderValueValidation.isValidHTTPToken(characters)
    }
    return HTTPHeaderValueValidation.isValidHTTPToken(name.checkedSpan16())
}

/// `isValidHTTPHeaderValue()`.
private func fetchHeadersIsValidHTTPHeaderValue(_ value: borrowing WTF.String) -> Bool {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    if !characters.isEmpty {
        return HTTPHeaderValueValidation.isValidHTTPHeaderValue(characters)
    }
    return HTTPHeaderValueValidation.isValidHTTPHeaderValue(value.checkedSpan16())
}

/// `isForbiddenHeader()` of `name` and the code units `valueRange` of `value`, whose 8-bit characters are
/// `nameCharacters` and `valueCharacters`.
private func fetchHeadersIsForbiddenHeader(
    _ name: borrowing WTF.String,
    _ nameCharacters: Span<UInt8>,
    _ value: borrowing WTF.String,
    _ valueCharacters: Span<UInt8>,
    _ valueRange: Range<Int>
) -> Bool {
    let headerName = fetchHeadersHeaderName(name)
    let isKnown = headerName != nil
    let knownName = headerName ?? WebCore.HTTPHeaderName.Accept
    if !nameCharacters.isEmpty {
        if !valueCharacters.isEmpty {
            return FetchHeaderChecks.isForbiddenHeader(
                isKnown: isKnown,
                headerName: knownName,
                nameCharacters,
                valueCharacters.extracting(valueRange)
            )
        }
        let valueUnits: Span<UInt16> = value.checkedSpan16()
        return FetchHeaderChecks.isForbiddenHeader(
            isKnown: isKnown,
            headerName: knownName,
            nameCharacters,
            valueUnits.extracting(valueRange)
        )
    }
    let nameUnits: Span<UInt16> = name.checkedSpan16()
    if !valueCharacters.isEmpty {
        return FetchHeaderChecks.isForbiddenHeader(
            isKnown: isKnown,
            headerName: knownName,
            nameUnits,
            valueCharacters.extracting(valueRange)
        )
    }
    let valueUnits: Span<UInt16> = value.checkedSpan16()
    return FetchHeaderChecks.isForbiddenHeader(isKnown: isKnown, headerName: knownName, nameUnits, valueUnits.extracting(valueRange))
}

/// `isSimpleHeader()` of `name` and `value`, or its code units `valueRange` when there is one; `characters` are the value's
/// 8-bit characters.
private func fetchHeadersIsSimpleHeader(
    _ name: borrowing WTF.String,
    _ value: borrowing WTF.String,
    _ characters: Span<UInt8>,
    _ valueRange: Range<Int>?
) -> Bool {
    guard let headerName = fetchHeadersHeaderName(name) else {
        return false
    }
    if !characters.isEmpty {
        return isCrossOriginSafeRequestHeaderBody(headerName, characters.extracting(valueRange ?? characters.indices))
    }
    let units: Span<UInt16> = value.checkedSpan16()
    return isCrossOriginSafeRequestHeaderBody(headerName, units.extracting(valueRange ?? units.indices))
}

/// `isForbiddenHeaderName()` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsForbiddenHeaderName(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    let headerName = fetchHeadersHeaderName(name)
    let isKnown = headerName != nil
    let knownName = headerName ?? WebCore.HTTPHeaderName.Accept
    if !characters.isEmpty {
        return FetchHeaderChecks.isForbiddenHeaderName(isKnown: isKnown, headerName: knownName, characters)
    }
    return FetchHeaderChecks.isForbiddenHeaderName(isKnown: isKnown, headerName: knownName, name.checkedSpan16())
}

/// `isNoCORSSafelistedRequestHeaderName()`.
private func fetchHeadersIsNoCORSSafelistedRequestHeaderName(_ name: borrowing WTF.String) -> Bool {
    let headerName = fetchHeadersHeaderName(name)
    return FetchHeaderChecks.isNoCORSSafelistedRequestHeaderName(
        isKnown: headerName != nil,
        headerName: headerName ?? WebCore.HTTPHeaderName.Accept
    )
}

/// `isPriviledgedNoCORSRequestHeaderName()` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsPriviledgedNoCORSRequestHeaderName(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return FetchHeaderChecks.isPriviledgedNoCORSRequestHeaderName(characters)
    }
    return FetchHeaderChecks.isPriviledgedNoCORSRequestHeaderName(name.checkedSpan16())
}

/// `isForbiddenResponseHeaderName()` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsForbiddenResponseHeaderName(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return FetchHeaderChecks.isForbiddenResponseHeaderName(characters)
    }
    return FetchHeaderChecks.isForbiddenResponseHeaderName(name.checkedSpan16())
}

/// `equalIgnoringASCIICase(name, "set-cookie"_s)` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsSetCookie(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return HTTPHeaderCodeUnits.equalIgnoringASCIICase(characters, fetchHeadersSetCookieName.span)
    }
    return HTTPHeaderCodeUnits.equalIgnoringASCIICase(name.checkedSpan16(), fetchHeadersSetCookieName.span)
}

/// The names of HTTPHeaderName's values, as httpHeaderNameString() gives them, lowercased: the name of the value with
/// raw value `index` is
/// `fetchHeadersCommonNameCharacters[fetchHeadersCommonNameOffsets[index]..<fetchHeadersCommonNameOffsets[index + 1]]`.
///
/// FetchHeaders.cpp checks that HTTPHeaderName has this many values.
private let fetchHeadersCommonNameOffsets: [UInt16] = [
    0, 6, 20, 35, 50, 63, 95, 123, 151, 178, 207, 229, 259, 288, 291, 304,
    317, 332, 342, 361, 377, 393, 407, 423, 436, 459, 494, 506, 512, 519, 547, 587,
    613, 651, 679, 682, 686, 699, 724, 761, 765, 771, 778, 782, 793, 805, 813, 830,
    843, 851, 870, 886, 914, 924, 937, 950, 954, 962, 968, 988, 997, 1004, 1010, 1029,
    1034, 1041, 1056, 1063, 1072, 1091, 1105, 1119, 1133, 1140, 1151, 1171, 1191, 1215, 1232, 1254,
    1275, 1288, 1302, 1324, 1357, 1367, 1378, 1387, 1404, 1406, 1425, 1432, 1449, 1456, 1481, 1498,
    1508, 1512, 1515, 1537, 1552, 1563, 1576, 1592,
]
private let fetchHeadersCommonNameCharacters: [UInt8] = [
    // accept
    0x61, 0x63, 0x63, 0x65, 0x70, 0x74,
    // accept-charset
    0x61, 0x63, 0x63, 0x65, 0x70, 0x74, 0x2D, 0x63, 0x68, 0x61, 0x72, 0x73, 0x65, 0x74,
    // accept-encoding
    0x61, 0x63, 0x63, 0x65, 0x70, 0x74, 0x2D, 0x65, 0x6E, 0x63, 0x6F, 0x64, 0x69, 0x6E, 0x67,
    // accept-language
    0x61, 0x63, 0x63, 0x65, 0x70, 0x74, 0x2D, 0x6C, 0x61, 0x6E, 0x67, 0x75, 0x61, 0x67, 0x65,
    // accept-ranges
    0x61, 0x63, 0x63, 0x65, 0x70, 0x74, 0x2D, 0x72, 0x61, 0x6E, 0x67, 0x65, 0x73,
    // access-control-allow-credentials
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x63,
    0x72, 0x65, 0x64, 0x65, 0x6E, 0x74, 0x69, 0x61, 0x6C, 0x73,
    // access-control-allow-headers
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x68,
    0x65, 0x61, 0x64, 0x65, 0x72, 0x73,
    // access-control-allow-methods
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x6D,
    0x65, 0x74, 0x68, 0x6F, 0x64, 0x73,
    // access-control-allow-origin
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x6F,
    0x72, 0x69, 0x67, 0x69, 0x6E,
    // access-control-expose-headers
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x65, 0x78, 0x70, 0x6F, 0x73, 0x65, 0x2D,
    0x68, 0x65, 0x61, 0x64, 0x65, 0x72, 0x73,
    // access-control-max-age
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x6D, 0x61, 0x78, 0x2D, 0x61, 0x67, 0x65,
    // access-control-request-headers
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x72, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74,
    0x2D, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72, 0x73,
    // access-control-request-method
    0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x72, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74,
    0x2D, 0x6D, 0x65, 0x74, 0x68, 0x6F, 0x64,
    // age
    0x61, 0x67, 0x65,
    // authorization
    0x61, 0x75, 0x74, 0x68, 0x6F, 0x72, 0x69, 0x7A, 0x61, 0x74, 0x69, 0x6F, 0x6E,
    // cache-control
    0x63, 0x61, 0x63, 0x68, 0x65, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C,
    // clear-site-data
    0x63, 0x6C, 0x65, 0x61, 0x72, 0x2D, 0x73, 0x69, 0x74, 0x65, 0x2D, 0x64, 0x61, 0x74, 0x61,
    // connection
    0x63, 0x6F, 0x6E, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x6F, 0x6E,
    // content-disposition
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x64, 0x69, 0x73, 0x70, 0x6F, 0x73, 0x69, 0x74, 0x69, 0x6F, 0x6E,
    // content-encoding
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x65, 0x6E, 0x63, 0x6F, 0x64, 0x69, 0x6E, 0x67,
    // content-language
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x6C, 0x61, 0x6E, 0x67, 0x75, 0x61, 0x67, 0x65,
    // content-length
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x6C, 0x65, 0x6E, 0x67, 0x74, 0x68,
    // content-location
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x6C, 0x6F, 0x63, 0x61, 0x74, 0x69, 0x6F, 0x6E,
    // content-range
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x72, 0x61, 0x6E, 0x67, 0x65,
    // content-security-policy
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x73, 0x65, 0x63, 0x75, 0x72, 0x69, 0x74, 0x79, 0x2D, 0x70, 0x6F, 0x6C, 0x69, 0x63,
    0x79,
    // content-security-policy-report-only
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x73, 0x65, 0x63, 0x75, 0x72, 0x69, 0x74, 0x79, 0x2D, 0x70, 0x6F, 0x6C, 0x69, 0x63,
    0x79, 0x2D, 0x72, 0x65, 0x70, 0x6F, 0x72, 0x74, 0x2D, 0x6F, 0x6E, 0x6C, 0x79,
    // content-type
    0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x74, 0x79, 0x70, 0x65,
    // cookie
    0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65,
    // cookie2
    0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x32,
    // cross-origin-embedder-policy
    0x63, 0x72, 0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x65, 0x6D, 0x62, 0x65, 0x64, 0x64, 0x65, 0x72, 0x2D,
    0x70, 0x6F, 0x6C, 0x69, 0x63, 0x79,
    // cross-origin-embedder-policy-report-only
    0x63, 0x72, 0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x65, 0x6D, 0x62, 0x65, 0x64, 0x64, 0x65, 0x72, 0x2D,
    0x70, 0x6F, 0x6C, 0x69, 0x63, 0x79, 0x2D, 0x72, 0x65, 0x70, 0x6F, 0x72, 0x74, 0x2D, 0x6F, 0x6E, 0x6C, 0x79,
    // cross-origin-opener-policy
    0x63, 0x72, 0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x6F, 0x70, 0x65, 0x6E, 0x65, 0x72, 0x2D, 0x70, 0x6F,
    0x6C, 0x69, 0x63, 0x79,
    // cross-origin-opener-policy-report-only
    0x63, 0x72, 0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x6F, 0x70, 0x65, 0x6E, 0x65, 0x72, 0x2D, 0x70, 0x6F,
    0x6C, 0x69, 0x63, 0x79, 0x2D, 0x72, 0x65, 0x70, 0x6F, 0x72, 0x74, 0x2D, 0x6F, 0x6E, 0x6C, 0x79,
    // cross-origin-resource-policy
    0x63, 0x72, 0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x72, 0x65, 0x73, 0x6F, 0x75, 0x72, 0x63, 0x65, 0x2D,
    0x70, 0x6F, 0x6C, 0x69, 0x63, 0x79,
    // dnt
    0x64, 0x6E, 0x74,
    // date
    0x64, 0x61, 0x74, 0x65,
    // default-style
    0x64, 0x65, 0x66, 0x61, 0x75, 0x6C, 0x74, 0x2D, 0x73, 0x74, 0x79, 0x6C, 0x65,
    // document-isolation-policy
    0x64, 0x6F, 0x63, 0x75, 0x6D, 0x65, 0x6E, 0x74, 0x2D, 0x69, 0x73, 0x6F, 0x6C, 0x61, 0x74, 0x69, 0x6F, 0x6E, 0x2D, 0x70, 0x6F, 0x6C,
    0x69, 0x63, 0x79,
    // document-isolation-policy-report-only
    0x64, 0x6F, 0x63, 0x75, 0x6D, 0x65, 0x6E, 0x74, 0x2D, 0x69, 0x73, 0x6F, 0x6C, 0x61, 0x74, 0x69, 0x6F, 0x6E, 0x2D, 0x70, 0x6F, 0x6C,
    0x69, 0x63, 0x79, 0x2D, 0x72, 0x65, 0x70, 0x6F, 0x72, 0x74, 0x2D, 0x6F, 0x6E, 0x6C, 0x79,
    // etag
    0x65, 0x74, 0x61, 0x67,
    // expect
    0x65, 0x78, 0x70, 0x65, 0x63, 0x74,
    // expires
    0x65, 0x78, 0x70, 0x69, 0x72, 0x65, 0x73,
    // host
    0x68, 0x6F, 0x73, 0x74,
    // icy-metaint
    0x69, 0x63, 0x79, 0x2D, 0x6D, 0x65, 0x74, 0x61, 0x69, 0x6E, 0x74,
    // icy-metadata
    0x69, 0x63, 0x79, 0x2D, 0x6D, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61,
    // if-match
    0x69, 0x66, 0x2D, 0x6D, 0x61, 0x74, 0x63, 0x68,
    // if-modified-since
    0x69, 0x66, 0x2D, 0x6D, 0x6F, 0x64, 0x69, 0x66, 0x69, 0x65, 0x64, 0x2D, 0x73, 0x69, 0x6E, 0x63, 0x65,
    // if-none-match
    0x69, 0x66, 0x2D, 0x6E, 0x6F, 0x6E, 0x65, 0x2D, 0x6D, 0x61, 0x74, 0x63, 0x68,
    // if-range
    0x69, 0x66, 0x2D, 0x72, 0x61, 0x6E, 0x67, 0x65,
    // if-unmodified-since
    0x69, 0x66, 0x2D, 0x75, 0x6E, 0x6D, 0x6F, 0x64, 0x69, 0x66, 0x69, 0x65, 0x64, 0x2D, 0x73, 0x69, 0x6E, 0x63, 0x65,
    // integrity-policy
    0x69, 0x6E, 0x74, 0x65, 0x67, 0x72, 0x69, 0x74, 0x79, 0x2D, 0x70, 0x6F, 0x6C, 0x69, 0x63, 0x79,
    // integrity-policy-report-only
    0x69, 0x6E, 0x74, 0x65, 0x67, 0x72, 0x69, 0x74, 0x79, 0x2D, 0x70, 0x6F, 0x6C, 0x69, 0x63, 0x79, 0x2D, 0x72, 0x65, 0x70, 0x6F, 0x72,
    0x74, 0x2D, 0x6F, 0x6E, 0x6C, 0x79,
    // keep-alive
    0x6B, 0x65, 0x65, 0x70, 0x2D, 0x61, 0x6C, 0x69, 0x76, 0x65,
    // last-event-id
    0x6C, 0x61, 0x73, 0x74, 0x2D, 0x65, 0x76, 0x65, 0x6E, 0x74, 0x2D, 0x69, 0x64,
    // last-modified
    0x6C, 0x61, 0x73, 0x74, 0x2D, 0x6D, 0x6F, 0x64, 0x69, 0x66, 0x69, 0x65, 0x64,
    // link
    0x6C, 0x69, 0x6E, 0x6B,
    // location
    0x6C, 0x6F, 0x63, 0x61, 0x74, 0x69, 0x6F, 0x6E,
    // origin
    0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E,
    // origin-agent-cluster
    0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x61, 0x67, 0x65, 0x6E, 0x74, 0x2D, 0x63, 0x6C, 0x75, 0x73, 0x74, 0x65, 0x72,
    // ping-from
    0x70, 0x69, 0x6E, 0x67, 0x2D, 0x66, 0x72, 0x6F, 0x6D,
    // ping-to
    0x70, 0x69, 0x6E, 0x67, 0x2D, 0x74, 0x6F,
    // pragma
    0x70, 0x72, 0x61, 0x67, 0x6D, 0x61,
    // proxy-authorization
    0x70, 0x72, 0x6F, 0x78, 0x79, 0x2D, 0x61, 0x75, 0x74, 0x68, 0x6F, 0x72, 0x69, 0x7A, 0x61, 0x74, 0x69, 0x6F, 0x6E,
    // range
    0x72, 0x61, 0x6E, 0x67, 0x65,
    // referer
    0x72, 0x65, 0x66, 0x65, 0x72, 0x65, 0x72,
    // referrer-policy
    0x72, 0x65, 0x66, 0x65, 0x72, 0x72, 0x65, 0x72, 0x2D, 0x70, 0x6F, 0x6C, 0x69, 0x63, 0x79,
    // refresh
    0x72, 0x65, 0x66, 0x72, 0x65, 0x73, 0x68,
    // report-to
    0x72, 0x65, 0x70, 0x6F, 0x72, 0x74, 0x2D, 0x74, 0x6F,
    // reporting-endpoints
    0x72, 0x65, 0x70, 0x6F, 0x72, 0x74, 0x69, 0x6E, 0x67, 0x2D, 0x65, 0x6E, 0x64, 0x70, 0x6F, 0x69, 0x6E, 0x74, 0x73,
    // sec-fetch-dest
    0x73, 0x65, 0x63, 0x2D, 0x66, 0x65, 0x74, 0x63, 0x68, 0x2D, 0x64, 0x65, 0x73, 0x74,
    // sec-fetch-mode
    0x73, 0x65, 0x63, 0x2D, 0x66, 0x65, 0x74, 0x63, 0x68, 0x2D, 0x6D, 0x6F, 0x64, 0x65,
    // sec-fetch-site
    0x73, 0x65, 0x63, 0x2D, 0x66, 0x65, 0x74, 0x63, 0x68, 0x2D, 0x73, 0x69, 0x74, 0x65,
    // sec-gpc
    0x73, 0x65, 0x63, 0x2D, 0x67, 0x70, 0x63,
    // sec-purpose
    0x73, 0x65, 0x63, 0x2D, 0x70, 0x75, 0x72, 0x70, 0x6F, 0x73, 0x65,
    // sec-speculation-tags
    0x73, 0x65, 0x63, 0x2D, 0x73, 0x70, 0x65, 0x63, 0x75, 0x6C, 0x61, 0x74, 0x69, 0x6F, 0x6E, 0x2D, 0x74, 0x61, 0x67, 0x73,
    // sec-websocket-accept
    0x73, 0x65, 0x63, 0x2D, 0x77, 0x65, 0x62, 0x73, 0x6F, 0x63, 0x6B, 0x65, 0x74, 0x2D, 0x61, 0x63, 0x63, 0x65, 0x70, 0x74,
    // sec-websocket-extensions
    0x73, 0x65, 0x63, 0x2D, 0x77, 0x65, 0x62, 0x73, 0x6F, 0x63, 0x6B, 0x65, 0x74, 0x2D, 0x65, 0x78, 0x74, 0x65, 0x6E, 0x73, 0x69, 0x6F,
    0x6E, 0x73,
    // sec-websocket-key
    0x73, 0x65, 0x63, 0x2D, 0x77, 0x65, 0x62, 0x73, 0x6F, 0x63, 0x6B, 0x65, 0x74, 0x2D, 0x6B, 0x65, 0x79,
    // sec-websocket-protocol
    0x73, 0x65, 0x63, 0x2D, 0x77, 0x65, 0x62, 0x73, 0x6F, 0x63, 0x6B, 0x65, 0x74, 0x2D, 0x70, 0x72, 0x6F, 0x74, 0x6F, 0x63, 0x6F, 0x6C,
    // sec-websocket-version
    0x73, 0x65, 0x63, 0x2D, 0x77, 0x65, 0x62, 0x73, 0x6F, 0x63, 0x6B, 0x65, 0x74, 0x2D, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E,
    // server-timing
    0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0x2D, 0x74, 0x69, 0x6D, 0x69, 0x6E, 0x67,
    // service-worker
    0x73, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x2D, 0x77, 0x6F, 0x72, 0x6B, 0x65, 0x72,
    // service-worker-allowed
    0x73, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x2D, 0x77, 0x6F, 0x72, 0x6B, 0x65, 0x72, 0x2D, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x65, 0x64,
    // service-worker-navigation-preload
    0x73, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x2D, 0x77, 0x6F, 0x72, 0x6B, 0x65, 0x72, 0x2D, 0x6E, 0x61, 0x76, 0x69, 0x67, 0x61, 0x74,
    0x69, 0x6F, 0x6E, 0x2D, 0x70, 0x72, 0x65, 0x6C, 0x6F, 0x61, 0x64,
    // set-cookie
    0x73, 0x65, 0x74, 0x2D, 0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65,
    // set-cookie2
    0x73, 0x65, 0x74, 0x2D, 0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x32,
    // sourcemap
    0x73, 0x6F, 0x75, 0x72, 0x63, 0x65, 0x6D, 0x61, 0x70,
    // speculation-rules
    0x73, 0x70, 0x65, 0x63, 0x75, 0x6C, 0x61, 0x74, 0x69, 0x6F, 0x6E, 0x2D, 0x72, 0x75, 0x6C, 0x65, 0x73,
    // te
    0x74, 0x65,
    // timing-allow-origin
    0x74, 0x69, 0x6D, 0x69, 0x6E, 0x67, 0x2D, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E,
    // trailer
    0x74, 0x72, 0x61, 0x69, 0x6C, 0x65, 0x72,
    // transfer-encoding
    0x74, 0x72, 0x61, 0x6E, 0x73, 0x66, 0x65, 0x72, 0x2D, 0x65, 0x6E, 0x63, 0x6F, 0x64, 0x69, 0x6E, 0x67,
    // upgrade
    0x75, 0x70, 0x67, 0x72, 0x61, 0x64, 0x65,
    // upgrade-insecure-requests
    0x75, 0x70, 0x67, 0x72, 0x61, 0x64, 0x65, 0x2D, 0x69, 0x6E, 0x73, 0x65, 0x63, 0x75, 0x72, 0x65, 0x2D, 0x72, 0x65, 0x71, 0x75, 0x65,
    0x73, 0x74, 0x73,
    // use-as-dictionary
    0x75, 0x73, 0x65, 0x2D, 0x61, 0x73, 0x2D, 0x64, 0x69, 0x63, 0x74, 0x69, 0x6F, 0x6E, 0x61, 0x72, 0x79,
    // user-agent
    0x75, 0x73, 0x65, 0x72, 0x2D, 0x61, 0x67, 0x65, 0x6E, 0x74,
    // vary
    0x76, 0x61, 0x72, 0x79,
    // via
    0x76, 0x69, 0x61,
    // x-content-type-options
    0x78, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x74, 0x79, 0x70, 0x65, 0x2D, 0x6F, 0x70, 0x74, 0x69, 0x6F, 0x6E, 0x73,
    // x-frame-options
    0x78, 0x2D, 0x66, 0x72, 0x61, 0x6D, 0x65, 0x2D, 0x6F, 0x70, 0x74, 0x69, 0x6F, 0x6E, 0x73,
    // x-sourcemap
    0x78, 0x2D, 0x73, 0x6F, 0x75, 0x72, 0x63, 0x65, 0x6D, 0x61, 0x70,
    // x-temp-tablet
    0x78, 0x2D, 0x74, 0x65, 0x6D, 0x70, 0x2D, 0x74, 0x61, 0x62, 0x6C, 0x65, 0x74,
    // x-xss-protection
    0x78, 0x2D, 0x78, 0x73, 0x73, 0x2D, 0x70, 0x72, 0x6F, 0x74, 0x65, 0x63, 0x74, 0x69, 0x6F, 0x6E,
]

/// The rank of each of HTTPHeaderName's names, lowercased, among them all sorted by code point:
/// `fetchHeadersCommonNameRanks[index]` for the value with raw value `index`, and `fetchHeadersCommonNamesByRank[rank]` the
/// raw value of the name of that rank.
private let fetchHeadersCommonNameRanks: [UInt8] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 36, 34, 35, 37, 38, 39, 40, 41, 42, 44, 43, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
    96, 97, 98, 99, 100, 101, 102,
]
private let fetchHeadersCommonNamesByRank: [UInt8] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 35, 36, 34, 37, 38, 39, 40, 41, 42, 44, 43, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
    96, 97, 98, 99, 100, 101, 102,
]

/// The first eight characters of each of HTTPHeaderName's names, lowercased, in rank order: one byte each from the most
/// significant, zeros past the name's end.
///
/// No name has a zero character, so two names' prefixes compare as their first eight characters do.
private let fetchHeadersCommonNamePrefixesByRank: [UInt64] = [
    0x6163636570740000, 0x6163636570742D63, 0x6163636570742D65, 0x6163636570742D6C,
    0x6163636570742D72, 0x6163636573732D63, 0x6163636573732D63, 0x6163636573732D63,
    0x6163636573732D63, 0x6163636573732D63, 0x6163636573732D63, 0x6163636573732D63,
    0x6163636573732D63, 0x6167650000000000, 0x617574686F72697A, 0x63616368652D636F,
    0x636C6561722D7369, 0x636F6E6E65637469, 0x636F6E74656E742D, 0x636F6E74656E742D,
    0x636F6E74656E742D, 0x636F6E74656E742D, 0x636F6E74656E742D, 0x636F6E74656E742D,
    0x636F6E74656E742D, 0x636F6E74656E742D, 0x636F6E74656E742D, 0x636F6F6B69650000,
    0x636F6F6B69653200, 0x63726F73732D6F72, 0x63726F73732D6F72, 0x63726F73732D6F72,
    0x63726F73732D6F72, 0x63726F73732D6F72, 0x6461746500000000, 0x64656661756C742D,
    0x646E740000000000, 0x646F63756D656E74, 0x646F63756D656E74, 0x6574616700000000,
    0x6578706563740000, 0x6578706972657300, 0x686F737400000000, 0x6963792D6D657461,
    0x6963792D6D657461, 0x69662D6D61746368, 0x69662D6D6F646966, 0x69662D6E6F6E652D,
    0x69662D72616E6765, 0x69662D756E6D6F64, 0x696E746567726974, 0x696E746567726974,
    0x6B6565702D616C69, 0x6C6173742D657665, 0x6C6173742D6D6F64, 0x6C696E6B00000000,
    0x6C6F636174696F6E, 0x6F726967696E0000, 0x6F726967696E2D61, 0x70696E672D66726F,
    0x70696E672D746F00, 0x707261676D610000, 0x70726F78792D6175, 0x72616E6765000000,
    0x7265666572657200, 0x7265666572726572, 0x7265667265736800, 0x7265706F72742D74,
    0x7265706F7274696E, 0x7365632D66657463, 0x7365632D66657463, 0x7365632D66657463,
    0x7365632D67706300, 0x7365632D70757270, 0x7365632D73706563, 0x7365632D77656273,
    0x7365632D77656273, 0x7365632D77656273, 0x7365632D77656273, 0x7365632D77656273,
    0x7365727665722D74, 0x736572766963652D, 0x736572766963652D, 0x736572766963652D,
    0x7365742D636F6F6B, 0x7365742D636F6F6B, 0x736F757263656D61, 0x73706563756C6174,
    0x7465000000000000, 0x74696D696E672D61, 0x747261696C657200, 0x7472616E73666572,
    0x7570677261646500, 0x757067726164652D, 0x7573652D61732D64, 0x757365722D616765,
    0x7661727900000000, 0x7669610000000000, 0x782D636F6E74656E, 0x782D6672616D652D,
    0x782D736F75726365, 0x782D74656D702D74, 0x782D7873732D7072,
]

private let fetchHeadersSetCookieName: [UInt8] = Array("set-cookie".utf8)

// MARK: - Strings

/// `value` trimmed of HTTP whitespace, and whether what remains is a valid header value.
private func fetchHeadersTrim(_ value: borrowing WTF.String) -> FetchHeadersTrimmedValue {
    fetchHeadersTrim(value, WebCore.securityPoliciesSpan8(value))
}

/// fetchHeadersTrim() of `value`, whose 8-bit characters are `characters`.
private func fetchHeadersTrim(_ value: borrowing WTF.String, _ characters: Span<UInt8>) -> FetchHeadersTrimmedValue {
    if !characters.isEmpty {
        return fetchHeadersTrim(characters)
    }
    return fetchHeadersTrim(value.checkedSpan16())
}

private func fetchHeadersTrim<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) -> FetchHeadersTrimmedValue {
    let range = HTTPHeaderCodeUnits.trim(characters, characters.indices, HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF)
    return FetchHeadersTrimmedValue(
        range: range,
        length: characters.count,
        isValid: HTTPHeaderValueValidation.isValidHTTPHeaderValue(characters.extracting(range))
    )
}

/// The String `String::trim(isASCIIWhitespaceWithoutFF)` makes: `value` itself when there is nothing to trim, the empty
/// String when only whitespace remains, else a new String of the same width.
private func fetchHeadersTrimmedString(_ value: consuming WTF.String, _ trimmedValue: FetchHeadersTrimmedValue) -> WTF.String {
    if trimmedValue.range.count == trimmedValue.length {
        return value
    }
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    if !characters.isEmpty {
        return WTF.makeStringFromLatin1Characters(characters.extracting(trimmedValue.range))
    }
    let units: Span<UInt16> = value.checkedSpan16()
    return WTF.makeStringFromUTF16Characters(units.extracting(trimmedValue.range))
}

/// `makeString(prefix, first, middle, second, suffix)` of ASCII text and two Strings, as WTF makes it: one String of
/// their length, 8-bit when both Strings are (the null String counts as 8-bit).
///
/// A String given with a range stands for the String `String::trim()` makes of those code units, which is the empty
/// String, 8-bit, when only whitespace remains. `firstCharacters` and `secondCharacters` are the Strings' 8-bit
/// characters.
private func fetchHeadersMakeString(
    _ prefix: borrowing [UInt8],
    _ first: borrowing WTF.String,
    _ firstCharacters: Span<UInt8>,
    _ firstRange: Range<Int>?,
    _ middle: borrowing [UInt8],
    _ second: borrowing WTF.String,
    _ secondCharacters: Span<UInt8>,
    _ secondRange: Range<Int>?,
    _ suffix: borrowing [UInt8]
) -> WTF.String {
    // checkedSpan16() is read only for a String with no 8-bit characters.
    let firstUnits: Span<UInt16> = firstCharacters.isEmpty ? first.checkedSpan16() : Span()
    let secondUnits: Span<UInt16> = secondCharacters.isEmpty ? second.checkedSpan16() : Span()
    // Each String is shorter than 2^31, so the sum cannot overflow.
    let length =
        prefix.count &+ (firstRange?.count ?? firstCharacters.count &+ firstUnits.count) &+ middle.count
        &+ (secondRange?.count ?? secondCharacters.count &+ secondUnits.count) &+ suffix.count
    if fetchHeadersIs8Bit(first, firstCharacters, firstUnits, firstRange),
        fetchHeadersIs8Bit(second, secondCharacters, secondUnits, secondRange)
    {
        return fetchHeadersConcatenation(
            UInt8.self,
            length,
            prefix.span,
            firstCharacters,
            firstUnits,
            firstRange,
            middle.span,
            secondCharacters,
            secondUnits,
            secondRange,
            suffix.span
        )
    }
    return fetchHeadersConcatenation(
        UInt16.self,
        length,
        prefix.span,
        firstCharacters,
        firstUnits,
        firstRange,
        middle.span,
        secondCharacters,
        secondUnits,
        secondRange,
        suffix.span
    )
}

/// Whether the String whose code units are `characters` or `units` is 8-bit or, with `range`, the String
/// `String::trim()` makes of those code units.
private func fetchHeadersIs8Bit(
    _ string: borrowing WTF.String,
    _ characters: Span<UInt8>,
    _ units: Span<UInt16>,
    _ range: Range<Int>?
) -> Bool {
    if !characters.isEmpty {
        return true
    }
    if units.isEmpty {
        return string.is8Bit()
    }
    if let range {
        return range.isEmpty
    }
    return false
}

private func fetchHeadersConcatenation<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ codeUnit: CodeUnit.Type,
    _ length: Int,
    _ prefix: Span<UInt8>,
    _ firstCharacters: Span<UInt8>,
    _ firstUnits: Span<UInt16>,
    _ firstRange: Range<Int>?,
    _ middle: Span<UInt8>,
    _ secondCharacters: Span<UInt8>,
    _ secondUnits: Span<UInt16>,
    _ secondRange: Range<Int>?,
    _ suffix: Span<UInt8>
) -> WTF.String {
    crossOriginAccessControlMakeString(CodeUnit.self, length) { output in
        var offset = crossOriginAccessControlCopy(prefix, to: &output, at: 0)
        offset = fetchHeadersStoreString(firstCharacters, firstUnits, firstRange, &output, offset)
        offset = crossOriginAccessControlCopy(middle, to: &output, at: offset)
        offset = fetchHeadersStoreString(secondCharacters, secondUnits, secondRange, &output, offset)
        _ = crossOriginAccessControlCopy(suffix, to: &output, at: offset)
    }
}

/// Stores the code units of a String, `characters` or else `units`, all of them or those in `range`, in `output` from
/// `offset` on, and returns the offset after them.
private func fetchHeadersStoreString<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ characters: Span<UInt8>,
    _ units: Span<UInt16>,
    _ range: Range<Int>?,
    _ output: inout MutableSpan<CodeUnit>,
    _ offset: Int
) -> Int {
    if !characters.isEmpty {
        return crossOriginAccessControlCopy(characters.extracting(range ?? characters.indices), to: &output, at: offset)
    }
    return crossOriginAccessControlCopy(units.extracting(range ?? units.indices), to: &output, at: offset)
}

/// `makeString(interleave(values, ", "_s))`, which StringBuilder makes: the only value itself (the empty String for
/// the null one), else the values joined with `", "`, 16-bit when the first value is, or when a later one is 16-bit
/// and neither empty nor a single Latin-1 character.
///
/// `values` is not empty.
private func fetchHeadersJoinedSetCookieValues(_ values: borrowing WebCore.SecurityPoliciesStringVector) -> WTF.String {
    let count = values.size()
    if count == 1 {
        if values[0].isNull() {
            return WTF.makeStringFromLatin1Characters(fetchHeadersNoCharacters.span)
        }
        return values[0]
    }

    // A Vector holds fewer than 2^32 Strings, each shorter than 2^31, so none of these sums can overflow.
    var length = 2 &* (count &- 1)
    var is8Bit = values[0].is8Bit()
    for index in 0..<count {
        let valueLength = Int(values[index].length())
        length &+= valueLength
        if index > 0, is8Bit, !values[index].is8Bit() {
            // StringBuilder stays 8-bit for an empty 16-bit String, and for one Latin-1 character.
            if valueLength > 1 {
                is8Bit = false
            } else if valueLength == 1 {
                let value = values[index]
                let characters: Span<UInt16> = value.checkedSpan16()
                if characters[0] > 0xFF {
                    is8Bit = false
                }
            }
        }
    }
    if is8Bit {
        return fetchHeadersJoinedSetCookieValues(UInt8.self, length, values)
    }
    return fetchHeadersJoinedSetCookieValues(UInt16.self, length, values)
}

private func fetchHeadersJoinedSetCookieValues<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ codeUnit: CodeUnit.Type,
    _ length: Int,
    _ values: borrowing WebCore.SecurityPoliciesStringVector
) -> WTF.String {
    if length <= 256 {
        var buffer = InlineArray<256, CodeUnit>(repeating: 0)
        var output = buffer.mutableSpan
        fetchHeadersStoreJoinedValues(values, &output)
        return CodeUnit.httpHeaderString(output.span.extracting(first: length))
    }
    var buffer = UniqueArray<CodeUnit>(repeating: 0, count: length)
    var output = buffer.mutableSpan
    fetchHeadersStoreJoinedValues(values, &output)
    return CodeUnit.httpHeaderString(output.span)
}

private func fetchHeadersStoreJoinedValues<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ values: borrowing WebCore.SecurityPoliciesStringVector,
    _ output: inout MutableSpan<CodeUnit>
) {
    var offset = 0
    for index in 0..<values.size() {
        if index > 0 {
            offset = crossOriginAccessControlCopy(fetchHeadersCommaSpace.span, to: &output, at: offset)
        }
        offset = fetchHeadersStoreValue(values[index], &output, offset)
    }
}

/// Stores the code units of `string` in `output` from `offset` on, and returns the offset after them.
private func fetchHeadersStoreValue<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ string: borrowing WTF.String,
    _ output: inout MutableSpan<CodeUnit>,
    _ offset: Int
) -> Int {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !characters.isEmpty {
        return crossOriginAccessControlCopy(characters, to: &output, at: offset)
    }
    return crossOriginAccessControlCopy(string.checkedSpan16(), to: &output, at: offset)
}

private func fetchHeadersTypeError(_ message: consuming WTF.String) -> WebCore.Exception {
    WebCore.Exception(WebCore.ExceptionCode.TypeError, message)
}

private func fetchHeadersInvalidNameMessage(_ name: borrowing WTF.String) -> WTF.String {
    fetchHeadersMakeString(
        fetchHeadersInvalidNamePrefix,
        name,
        WebCore.securityPoliciesSpan8(name),
        nil,
        fetchHeadersQuote,
        WTF.String(),
        Span(),
        nil,
        fetchHeadersNoCharacters
    )
}

private func fetchHeadersImmutableMessage() -> WTF.String {
    WTF.makeStringFromLatin1Characters(fetchHeadersImmutableMessageCharacters.span)
}

private let fetchHeadersNoCharacters: [UInt8] = []
private let fetchHeadersCommaSpace: [UInt8] = Array(", ".utf8)
private let fetchHeadersQuote: [UInt8] = Array("'".utf8)
private let fetchHeadersInvalidNamePrefix: [UInt8] = Array("Invalid header name: '".utf8)
private let fetchHeadersInvalidValuePrefix: [UInt8] = Array("Header '".utf8)
private let fetchHeadersInvalidValueMiddle: [UInt8] = Array("' has invalid value: '".utf8)
private let fetchHeadersInvalidSetCookieValuePrefix: [UInt8] = Array("Header 'Set-Cookie' has invalid value: '".utf8)
private let fetchHeadersImmutableMessageCharacters: [UInt8] = Array("Headers object's guard is 'immutable'".utf8)
