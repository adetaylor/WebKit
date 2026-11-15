// Copyright (C) 2008-2025 Apple Inc. All rights reserved.
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
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.CrossOriginAccessControl
internal import WebCore_Private.Core.HTTPHeaderMap
internal import WebCore_Private.Core.HTTPHeaderNames
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// `isSimpleCrossOriginAccessRequest()`: whether `method` is a CORS-safelisted method and every header in `headers` a
/// CORS-safelisted request header.
///
/// `headers` is the request's header map, which the caller passes by reference and does not change during the call.
/// This function reads it through its header spans and holds nothing of it past the call. The C++ functions it calls
/// are `HTTPHeaderMap::commonHeadersSpan()` and `uncommonHeadersSpan()`, `securityPoliciesSpan8()` and
/// `String::checkedSpan16()`, and none reaches the request.
@_expose(Cxx)
func crossOriginAccessControlIsSimpleRequest(_ method: consuming WTF.String, _ headers: borrowing WebCore.HTTPHeaderMap) -> Bool {
    if !crossOriginAccessControlIsSimpleMethod(method) {
        return false
    }
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
    for index in commonHeaders.indices {
        if !crossOriginAccessControlIsSafeRequestHeader(commonHeaders[index]) {
            return false
        }
    }
    // A header with no HTTPHeaderName is never CORS-safelisted.
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
    return uncommonHeaders.isEmpty
}

/// `httpHeadersToKeepFromCleaning()`: the `HTTPHeadersToKeepFromCleaning` bits of the headers that `headers` contains.
///
/// `headers` is the request's header map, which the caller passes by reference and does not change during the call.
/// Only `HTTPHeaderMap::contains()` reads it.
@_expose(Cxx)
func crossOriginAccessControlHeadersToKeep(_ headers: borrowing WebCore.HTTPHeaderMap) -> UInt8 {
    var headersToKeep: UInt8 = 0
    if headers.contains(WebCore.HTTPHeaderName.AcceptEncoding) {
        headersToKeep |= WebCore.HTTPHeadersToKeepFromCleaning.AcceptEncoding.rawValue
    }
    if headers.contains(WebCore.HTTPHeaderName.CacheControl) {
        headersToKeep |= WebCore.HTTPHeadersToKeepFromCleaning.CacheControl.rawValue
    }
    if headers.contains(WebCore.HTTPHeaderName.ContentType) {
        headersToKeep |= WebCore.HTTPHeadersToKeepFromCleaning.ContentType.rawValue
    }
    if headers.contains(WebCore.HTTPHeaderName.Origin) {
        headersToKeep |= WebCore.HTTPHeadersToKeepFromCleaning.Origin.rawValue
    }
    if headers.contains(WebCore.HTTPHeaderName.Pragma) {
        headersToKeep |= WebCore.HTTPHeadersToKeepFromCleaning.Pragma.rawValue
    }
    if headers.contains(WebCore.HTTPHeaderName.Referer) {
        headersToKeep |= WebCore.HTTPHeadersToKeepFromCleaning.Referer.rawValue
    }
    if headers.contains(WebCore.HTTPHeaderName.UserAgent) {
        headersToKeep |= WebCore.HTTPHeadersToKeepFromCleaning.UserAgent.rawValue
    }
    return headersToKeep
}

/// The `Access-Control-Request-Headers` value of `createAccessControlPreflightRequest()`: the names of the headers in
/// `headers` that are not CORS-safelisted request headers, ASCII-lowercased, sorted by code point and joined with
/// commas.
///
/// The null string when that is empty.
///
/// `headers` is the header map of the request the preflight is made for, which the caller passes by reference and does
/// not change during the call. This function reads it through its header spans and holds nothing of it past the call.
/// The C++ functions it calls are `HTTPHeaderMap::commonHeadersSpan()` and `uncommonHeadersSpan()`,
/// `securityPoliciesHTTPHeaderNameString()`, `securityPoliciesSpan8()`, `String`'s `checkedSpan16()`, `is8Bit()` and
/// `length()`, `makeStringFromLatin1Characters()` and `makeStringFromUTF16Characters()`, and none reaches the request.
@_expose(Cxx)
func crossOriginAccessControlRequestHeadersValue(_ headers: borrowing WebCore.HTTPHeaderMap) -> WTF.String {
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
    // Two Vector sizes, each below 2^32: far from overflowing.
    let maximumCount = commonHeaders.count &+ uncommonHeaders.count
    if maximumCount <= crossOriginAccessControlInlineNameCount {
        var names = InlineArray<16, CrossOriginAccessControlName>(repeating: CrossOriginAccessControlName())
        var namesSpan = names.mutableSpan
        return crossOriginAccessControlJoinedNames(commonHeaders, uncommonHeaders, &namesSpan)
    }
    var names = UniqueArray<CrossOriginAccessControlName>(repeating: CrossOriginAccessControlName(), count: maximumCount)
    var namesSpan = names.mutableSpan
    return crossOriginAccessControlJoinedNames(commonHeaders, uncommonHeaders, &namesSpan)
}

/// `passesAccessControlCheck()`: the null string when the response's `Access-Control-Allow-Origin` value `allowOrigin`
/// and `Access-Control-Allow-Credentials` value `allowCredentials` allow `origin`, the requesting origin's
/// serialization; otherwise the error message. `starAllowed` is whether a wildcard may allow the request, and
/// `usesCredentials` whether its stored credentials policy is `Use`.
@_expose(Cxx)
func crossOriginAccessControlCheckFailure(
    _ allowOrigin: consuming WTF.String,
    _ allowCredentials: consuming WTF.String,
    _ statusCode: Int32,
    _ origin: consuming WTF.String,
    _ starAllowed: Bool,
    _ usesCredentials: Bool
) -> WTF.String {
    let allowOriginBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(allowOrigin)
    if !allowOriginBytes.isEmpty {
        return crossOriginAccessControlCheckFailureForAllowOrigin(
            allowOriginBytes,
            allowOrigin,
            allowCredentials,
            statusCode,
            origin,
            starAllowed,
            usesCredentials
        )
    }
    let allowOriginUnits: Span<UInt16> = allowOrigin.checkedSpan16()
    return crossOriginAccessControlCheckFailureForAllowOrigin(
        allowOriginUnits,
        allowOrigin,
        allowCredentials,
        statusCode,
        origin,
        starAllowed,
        usesCredentials
    )
}

/// crossOriginAccessControlCheckFailure() once `allowOrigin` is read into `allowOriginCharacters`.
private func crossOriginAccessControlCheckFailureForAllowOrigin<AllowOriginCodeUnit: HTTPHeaderStringCodeUnit>(
    _ allowOriginCharacters: Span<AllowOriginCodeUnit>,
    _ allowOrigin: borrowing WTF.String,
    _ allowCredentials: borrowing WTF.String,
    _ statusCode: Int32,
    _ origin: borrowing WTF.String,
    _ starAllowed: Bool,
    _ usesCredentials: Bool
) -> WTF.String {
    let isWildcard = allowOriginCharacters.count == 1 && HTTPHeaderCodeUnits.value(allowOriginCharacters[0]) == 0x2A
    if isWildcard && starAllowed {
        return WTF.String()
    }
    let originBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(origin)
    if !originBytes.isEmpty {
        return crossOriginAccessControlCheckFailureForOrigins(
            allowOriginCharacters,
            originBytes,
            originIs8Bit: true,
            allowOrigin,
            allowCredentials,
            statusCode,
            origin,
            isWildcard,
            usesCredentials
        )
    }
    let originUnits: Span<UInt16> = origin.checkedSpan16()
    return crossOriginAccessControlCheckFailureForOrigins(
        allowOriginCharacters,
        originUnits,
        originIs8Bit: origin.is8Bit(),
        allowOrigin,
        allowCredentials,
        statusCode,
        origin,
        isWildcard,
        usesCredentials
    )
}

/// crossOriginAccessControlCheckFailure() once `allowOrigin` and `origin` are read into `allowOriginCharacters` and
/// `originCharacters`; `originIs8Bit` is whether `origin` is 8-bit.
private func crossOriginAccessControlCheckFailureForOrigins<
    AllowOriginCodeUnit: HTTPHeaderStringCodeUnit,
    OriginCodeUnit: HTTPHeaderStringCodeUnit
>(
    _ allowOriginCharacters: Span<AllowOriginCodeUnit>,
    _ originCharacters: Span<OriginCodeUnit>,
    originIs8Bit: Bool,
    _ allowOrigin: borrowing WTF.String,
    _ allowCredentials: borrowing WTF.String,
    _ statusCode: Int32,
    _ origin: borrowing WTF.String,
    _ isWildcard: Bool,
    _ usesCredentials: Bool
) -> WTF.String {
    var isSameOrigin = crossOriginAccessControlEquals(allowOriginCharacters, originCharacters)
    if isSameOrigin, allowOriginCharacters.isEmpty {
        // A null String equals only a null String.
        isSameOrigin = allowOrigin.isNull() == origin.isNull()
    }
    if !isSameOrigin {
        if isWildcard {
            return WTF.makeStringFromLatin1Characters(crossOriginAccessControlWildcardMessage.span)
        }
        if crossOriginAccessControlFindComma(allowOriginCharacters, from: 0) < allowOriginCharacters.count {
            return WTF.makeStringFromLatin1Characters(crossOriginAccessControlMultipleOriginsMessage.span)
        }
        return crossOriginAccessControlMessage(
            crossOriginAccessControlOriginPrefix.span,
            originCharacters.bytes,
            is8Bit: originIs8Bit,
            crossOriginAccessControlOriginSuffix.span,
            statusCode: statusCode
        )
    }

    if usesCredentials, !crossOriginAccessControlEquals(allowCredentials, "true") {
        return WTF.makeStringFromLatin1Characters(crossOriginAccessControlCredentialsMessage.span)
    }
    return WTF.String()
}

/// `"Cannot use wildcard in Access-Control-Allow-Origin when credentials flag is true."`.
private let crossOriginAccessControlWildcardMessage: [UInt8] = [
    0x43, 0x61, 0x6E, 0x6E, 0x6F, 0x74, 0x20, 0x75, 0x73, 0x65, 0x20, 0x77, 0x69, 0x6C, 0x64, 0x63, 0x61, 0x72, 0x64, 0x20,
    0x69, 0x6E, 0x20, 0x41, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x41, 0x6C,
    0x6C, 0x6F, 0x77, 0x2D, 0x4F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x20, 0x77, 0x68, 0x65, 0x6E, 0x20, 0x63, 0x72, 0x65, 0x64,
    0x65, 0x6E, 0x74, 0x69, 0x61, 0x6C, 0x73, 0x20, 0x66, 0x6C, 0x61, 0x67, 0x20, 0x69, 0x73, 0x20, 0x74, 0x72, 0x75, 0x65,
    0x2E,
]

/// `"Access-Control-Allow-Origin cannot contain more than one origin."`.
private let crossOriginAccessControlMultipleOriginsMessage: [UInt8] = [
    0x41, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x41, 0x6C, 0x6C, 0x6F, 0x77,
    0x2D, 0x4F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x20, 0x63, 0x61, 0x6E, 0x6E, 0x6F, 0x74, 0x20, 0x63, 0x6F, 0x6E, 0x74, 0x61,
    0x69, 0x6E, 0x20, 0x6D, 0x6F, 0x72, 0x65, 0x20, 0x74, 0x68, 0x61, 0x6E, 0x20, 0x6F, 0x6E, 0x65, 0x20, 0x6F, 0x72, 0x69,
    0x67, 0x69, 0x6E, 0x2E,
]

/// `"Credentials flag is true, but Access-Control-Allow-Credentials is not \"true\"."`.
private let crossOriginAccessControlCredentialsMessage: [UInt8] = [
    0x43, 0x72, 0x65, 0x64, 0x65, 0x6E, 0x74, 0x69, 0x61, 0x6C, 0x73, 0x20, 0x66, 0x6C, 0x61, 0x67, 0x20, 0x69, 0x73, 0x20,
    0x74, 0x72, 0x75, 0x65, 0x2C, 0x20, 0x62, 0x75, 0x74, 0x20, 0x41, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E,
    0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x41, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x43, 0x72, 0x65, 0x64, 0x65, 0x6E, 0x74, 0x69, 0x61,
    0x6C, 0x73, 0x20, 0x69, 0x73, 0x20, 0x6E, 0x6F, 0x74, 0x20, 0x22, 0x74, 0x72, 0x75, 0x65, 0x22, 0x2E,
]

/// `"Origin "`.
private let crossOriginAccessControlOriginPrefix: [UInt8] = [0x4F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x20]

/// `" is not allowed by Access-Control-Allow-Origin. Status code: "`.
private let crossOriginAccessControlOriginSuffix: [UInt8] = [
    0x20, 0x69, 0x73, 0x20, 0x6E, 0x6F, 0x74, 0x20, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x65, 0x64, 0x20, 0x62, 0x79, 0x20, 0x41,
    0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x41, 0x6C, 0x6C, 0x6F, 0x77, 0x2D,
    0x4F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2E, 0x20, 0x53, 0x74, 0x61, 0x74, 0x75, 0x73, 0x20, 0x63, 0x6F, 0x64, 0x65, 0x3A,
    0x20,
]

// MARK: Helpers the other security policy checks share

/// `isOnAccessControlSimpleRequestMethodAllowlist()`: `GET`, `HEAD` or `POST`, case-sensitively.
func crossOriginAccessControlIsSimpleMethod(_ method: borrowing WTF.String) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(method)
    if !bytes.isEmpty {
        return crossOriginAccessControlIsSimpleMethod(bytes)
    }
    let units: Span<UInt16> = method.checkedSpan16()
    return crossOriginAccessControlIsSimpleMethod(units)
}

/// `isOnAccessControlSimpleRequestMethodAllowlist()` of a method's characters.
func crossOriginAccessControlIsSimpleMethod<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ method: Span<CodeUnit>) -> Bool {
    if crossOriginAccessControlEquals(method, "GET") {
        return true
    }
    if crossOriginAccessControlEquals(method, "HEAD") {
        return true
    }
    return crossOriginAccessControlEquals(method, "POST")
}

/// `isCrossOriginSafeRequestHeader()` for a header of the request's header map.
func crossOriginAccessControlIsSafeRequestHeader(_ header: borrowing WebCore.HTTPHeaderMap.CommonHeader) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(header.value)
    if !bytes.isEmpty {
        return isCrossOriginSafeRequestHeaderBody(header.key, bytes)
    }
    // The empty value's result does not depend on its width.
    let units: Span<UInt16> = header.value.checkedSpan16()
    return isCrossOriginSafeRequestHeaderBody(header.key, units)
}

/// Whether `string` has the code units of the ASCII `literal`, as a String compares with an ASCIILiteral.
func crossOriginAccessControlEquals(_ string: borrowing WTF.String, _ literal: Swift.String) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !bytes.isEmpty {
        return crossOriginAccessControlEquals(bytes, literal)
    }
    let units: Span<UInt16> = string.checkedSpan16()
    return crossOriginAccessControlEquals(units, literal)
}

/// Whether `characters` are the code units of `string`, as a StringView compares with a String.
func crossOriginAccessControlEquals<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ string: borrowing WTF.String
) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !bytes.isEmpty {
        return crossOriginAccessControlEquals(characters, bytes)
    }
    let units: Span<UInt16> = string.checkedSpan16()
    return crossOriginAccessControlEquals(characters, units)
}

/// Whether `first` and `second` have the same code units, whatever their widths.
///
/// Code units of the same width are compared by their bytes.
func crossOriginAccessControlEquals<First: HTTPHeaderStringCodeUnit, Second: HTTPHeaderStringCodeUnit>(
    _ first: Span<First>,
    _ second: Span<Second>
) -> Bool {
    guard first.count == second.count else {
        return false
    }
    if First.bitWidth == Second.bitWidth {
        return crossOriginAccessControlEqualBytes(first.bytes, second.bytes)
    }
    for index in first.indices {
        if HTTPHeaderCodeUnits.value(first[index]) != HTTPHeaderCodeUnits.value(second[index]) {
            return false
        }
    }
    return true
}

/// Whether `first` and `second`, which have the same number of bytes, have the same bytes: eight at a time, the last
/// eight overlapping the ones before them, and fewer than eight in two overlapping loads of four or two, or in one.
private func crossOriginAccessControlEqualBytes(_ first: RawSpan, _ second: RawSpan) -> Bool {
    let byteCount = first.byteCount
    if byteCount >= 8 {
        // At least eight bytes.
        let last = byteCount &- 8
        var offset = 0
        while offset < last {
            if first.load(fromByteOffset: offset, as: UInt64.self) != second.load(fromByteOffset: offset, as: UInt64.self) {
                return false
            }
            // Below last, so within both.
            offset &+= 8
        }
        return first.load(fromByteOffset: last, as: UInt64.self) == second.load(fromByteOffset: last, as: UInt64.self)
    }
    if byteCount >= 4 {
        // At least four bytes.
        let last = byteCount &- 4
        return first.load(fromByteOffset: 0, as: UInt32.self) == second.load(fromByteOffset: 0, as: UInt32.self)
            && first.load(fromByteOffset: last, as: UInt32.self) == second.load(fromByteOffset: last, as: UInt32.self)
    }
    if byteCount >= 2 {
        // At least two bytes.
        let last = byteCount &- 2
        return first.load(fromByteOffset: 0, as: UInt16.self) == second.load(fromByteOffset: 0, as: UInt16.self)
            && first.load(fromByteOffset: last, as: UInt16.self) == second.load(fromByteOffset: last, as: UInt16.self)
    }
    if byteCount == 1 {
        return first.load(fromByteOffset: 0, as: UInt8.self) == second.load(fromByteOffset: 0, as: UInt8.self)
    }
    return true
}

/// Whether `first` and `second` have the same code units once both have their ASCII upper-case letters lowered, as
/// `equalIgnoringASCIICase()` compares them.
func crossOriginAccessControlEqualsIgnoringASCIICase<
    First: FixedWidthInteger & UnsignedInteger,
    Second: FixedWidthInteger & UnsignedInteger
>(
    _ first: Span<First>,
    _ second: Span<Second>
) -> Bool {
    typealias Units = HTTPHeaderCodeUnits
    guard first.count == second.count else {
        return false
    }
    for index in first.indices {
        if Units.toASCIILower(Units.value(first[index])) != Units.toASCIILower(Units.value(second[index])) {
            return false
        }
    }
    return true
}

/// Whether `characters` are the code units of the ASCII `literal`.
func crossOriginAccessControlEquals<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ literal: Swift.String
) -> Bool {
    let literalCodeUnits = literal.utf8
    guard characters.count == literalCodeUnits.count else {
        return false
    }
    var index = 0
    for codeUnit in literalCodeUnits {
        if HTTPHeaderCodeUnits.value(characters[index]) != UInt32(codeUnit) {
            return false
        }
        index += 1
    }
    return true
}

/// `makeString()` of the ASCII `prefix`, `string` and the ASCII `suffix`: 8-bit unless `string` is 16-bit.
func crossOriginAccessControlMessage(_ prefix: Span<UInt8>, _ string: borrowing WTF.String, _ suffix: Span<UInt8>) -> WTF.String {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !bytes.isEmpty {
        return crossOriginAccessControlMessage(prefix, bytes.bytes, is8Bit: true, suffix)
    }
    let units: Span<UInt16> = string.checkedSpan16()
    return crossOriginAccessControlMessage(prefix, units.bytes, is8Bit: string.is8Bit(), suffix)
}

/// `makeString()` of the ASCII `prefix`, a String's code units, whose bytes are `characters`, the ASCII `suffix` and,
/// when there is one, `statusCode`. `is8Bit` is whether that String, and so the message, is 8-bit; its code units have
/// the message's width when there are any.
@inline(never)
func crossOriginAccessControlMessage(
    _ prefix: Span<UInt8>,
    _ characters: RawSpan,
    is8Bit: Bool,
    _ suffix: Span<UInt8>,
    statusCode: Int32? = nil
) -> WTF.String {
    var decimalLength = 0
    if let statusCode {
        decimalLength = crossOriginAccessControlDecimalLength(statusCode)
    }
    if is8Bit {
        // Two literals, a String's characters and eleven code units at most: far from overflowing.
        let length = prefix.count &+ characters.byteCount &+ suffix.count &+ decimalLength
        return crossOriginAccessControlMakeString(UInt8.self, length) { text in
            do {
                var bytes = text.mutableBytes
                crossOriginAccessControlCopyBytes(prefix.bytes, to: &bytes, at: 0)
                crossOriginAccessControlCopyBytes(characters, to: &bytes, at: prefix.count)
                // The end of the characters, within the text.
                crossOriginAccessControlCopyBytes(suffix.bytes, to: &bytes, at: prefix.count &+ characters.byteCount)
            }
            if let statusCode {
                crossOriginAccessControlWriteDecimal(statusCode, to: &text, endingAt: length)
            }
        }
    }
    // Two bytes per code unit.
    let characterCount = characters.byteCount / 2
    // Two literals, a String's characters and eleven code units at most: far from overflowing.
    let length = prefix.count &+ characterCount &+ suffix.count &+ decimalLength
    return crossOriginAccessControlMakeString(UInt16.self, length) { text in
        crossOriginAccessControlWiden(prefix, to: &text, at: 0)
        do {
            var bytes = text.mutableBytes
            // The prefix's end within the text, in bytes.
            crossOriginAccessControlCopyBytes(characters, to: &bytes, at: prefix.count &* 2)
        }
        // The end of the characters, within the text.
        crossOriginAccessControlWiden(suffix, to: &text, at: prefix.count &+ characterCount)
        if let statusCode {
            crossOriginAccessControlWriteDecimal(statusCode, to: &text, endingAt: length)
        }
    }
}

/// The index of the first comma in `characters` at or after `start`, or `characters.count` if there is none, as
/// `HTTPHeaderCodeUnits.find()` gives it.
///
/// Eight bytes are searched at a time when there are eight, the last eight overlapping the ones before them.
func crossOriginAccessControlFindComma<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>, from start: Int) -> Int {
    let bytes = characters.bytes
    let byteCount = bytes.byteCount
    if byteCount < 8 {
        return HTTPHeaderCodeUnits.find(0x2C, in: characters, from: start)
    }
    let unitSize = MemoryLayout<CodeUnit>.stride
    // A comma in each code unit of a word, and each code unit's bits but its highest.
    let commas: UInt64 = unitSize == 1 ? 0x2C2C_2C2C_2C2C_2C2C : 0x002C_002C_002C_002C
    let lowBits: UInt64 = unitSize == 1 ? 0x7F7F_7F7F_7F7F_7F7F : 0x7FFF_7FFF_7FFF_7FFF
    // A position within the characters, in bytes.
    var offset = start &* unitSize
    while offset < byteCount {
        // The last eight bytes, when fewer are left, which byteCount has.
        let wordOffset = min(offset, byteCount &- 8)
        let differences = bytes.load(fromByteOffset: wordOffset, as: UInt64.self) ^ commas
        // Code units whose bits but the highest are at most lowBits, plus lowBits: no carry leaves a code unit.
        let sums = (differences & lowBits) &+ lowBits
        // The highest bit of each code unit that is a comma, then without the ones before offset.
        var found = ~(sums | differences | lowBits)
        // Fewer than eight bytes before offset.
        found &= UInt64.max << ((offset &- wordOffset) &* 8)
        if found != 0 {
            // A byte within the word, which lies within the characters.
            return (wordOffset &+ found.trailingZeroBitCount / 8) / unitSize
        }
        // The word's end, within the characters.
        offset = wordOffset &+ 8
    }
    return characters.count
}

/// The String of the `length` code units `fill` writes from the start of the span it is given, 8-bit when `CodeUnit` is
/// `UInt8`: written on the stack when there are at most 256, else on the heap.
@inline(always)
func crossOriginAccessControlMakeString<CodeUnit: HTTPHeaderStringCodeUnit>(
    _: CodeUnit.Type,
    _ length: Int,
    _ fill: (inout MutableSpan<CodeUnit>) -> Void
) -> WTF.String {
    if length <= 256 {
        var buffer = InlineArray<256, CodeUnit>(repeating: 0)
        do {
            var text = buffer.mutableSpan
            fill(&text)
        }
        return CodeUnit.httpHeaderString(buffer.span.extracting(first: length))
    }
    var buffer = UniqueArray<CodeUnit>(repeating: 0, count: length)
    do {
        var text = buffer.mutableSpan
        fill(&text)
    }
    return CodeUnit.httpHeaderString(buffer.span)
}

/// Copies `characters` into `text` from `position`, each code unit in the width of `Output`, which holds it, and
/// returns the position after them.
///
/// Code units of the same width are copied by their bytes.
func crossOriginAccessControlCopy<Input: HTTPHeaderStringCodeUnit, Output: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ characters: Span<Input>,
    to text: inout MutableSpan<Output>,
    at position: Int
) -> Int {
    if Input.bitWidth == Output.bitWidth {
        var destination = text.mutableBytes
        // A position within the text, in bytes.
        crossOriginAccessControlCopyBytes(characters.bytes, to: &destination, at: position &* MemoryLayout<Output>.stride)
    } else {
        crossOriginAccessControlWiden(characters, to: &text, at: position)
    }
    // A position within the text, which has room for the characters.
    return position &+ characters.count
}

/// `WTF::codePointCompareLessThan()` of two runs of code units: whether `first` sorts before `second` by code unit
/// value, a run before any longer one it begins.
func crossOriginAccessControlCodePointLessThan<First: FixedWidthInteger & UnsignedInteger, Second: FixedWidthInteger & UnsignedInteger>(
    _ first: Span<First>,
    _ second: Span<Second>
) -> Bool {
    for index in 0..<min(first.count, second.count) {
        let firstCodeUnit = HTTPHeaderCodeUnits.value(first[index])
        let secondCodeUnit = HTTPHeaderCodeUnits.value(second[index])
        if firstCodeUnit != secondCodeUnit {
            return firstCodeUnit < secondCodeUnit
        }
    }
    return first.count < second.count
}

// MARK: Private helpers

/// Copies `characters` into `text` from `position`, each code unit in the width of `Output`, which holds it.
private func crossOriginAccessControlWiden<Input: HTTPHeaderStringCodeUnit, Output: HTTPHeaderStringCodeUnit>(
    _ characters: Span<Input>,
    to text: inout MutableSpan<Output>,
    at position: Int
) {
    for index in characters.indices {
        // A position within the text, which has room for the characters.
        text[position &+ index] = Output(truncatingIfNeeded: characters[index])
    }
}

/// Copies `source` into `destination` from `offset`, which has room for it: eight bytes at a time, the last eight
/// overlapping the ones before them, and fewer than eight in two overlapping stores of four or two, or in one.
@inline(always)
private func crossOriginAccessControlCopyBytes(_ source: RawSpan, to destination: inout MutableRawSpan, at offset: Int) {
    let byteCount = source.byteCount
    if byteCount >= 8 {
        // At least eight bytes.
        let last = byteCount &- 8
        var position = 0
        while position < last {
            // Positions within the source, which the destination has room for after offset.
            destination.storeBytes(
                of: source.load(fromByteOffset: position, as: UInt64.self),
                toByteOffset: offset &+ position,
                as: UInt64.self
            )
            // Below last, so within the source.
            position &+= 8
        }
        // A position within the source, which the destination has room for after offset.
        destination.storeBytes(of: source.load(fromByteOffset: last, as: UInt64.self), toByteOffset: offset &+ last, as: UInt64.self)
    } else if byteCount >= 4 {
        // At least four bytes.
        let last = byteCount &- 4
        let head = source.load(fromByteOffset: 0, as: UInt32.self)
        let tail = source.load(fromByteOffset: last, as: UInt32.self)
        destination.storeBytes(of: head, toByteOffset: offset, as: UInt32.self)
        // A position within the source, which the destination has room for after offset.
        destination.storeBytes(of: tail, toByteOffset: offset &+ last, as: UInt32.self)
    } else if byteCount >= 2 {
        // At least two bytes.
        let last = byteCount &- 2
        let head = source.load(fromByteOffset: 0, as: UInt16.self)
        let tail = source.load(fromByteOffset: last, as: UInt16.self)
        destination.storeBytes(of: head, toByteOffset: offset, as: UInt16.self)
        // A position within the source, which the destination has room for after offset.
        destination.storeBytes(of: tail, toByteOffset: offset &+ last, as: UInt16.self)
    } else if byteCount == 1 {
        destination.storeBytes(of: source.load(fromByteOffset: 0, as: UInt8.self), toByteOffset: offset, as: UInt8.self)
    }
}

/// The number of code units `makeString()` writes for `value`: its decimal digits, after a `-` when it is negative.
private func crossOriginAccessControlDecimalLength(_ value: Int32) -> Int {
    var magnitude = value.magnitude
    var length = value < 0 ? 2 : 1
    while magnitude >= 10 {
        magnitude /= 10
        // At most a sign and ten digits.
        length &+= 1
    }
    return length
}

/// Writes `value` in decimal, after a `-` when it is negative, as `makeString()` writes an integer, into `text`, ending
/// before `end`, after room for crossOriginAccessControlDecimalLength() code units.
private func crossOriginAccessControlWriteDecimal<Output: HTTPHeaderStringCodeUnit>(
    _ value: Int32,
    to text: inout MutableSpan<Output>,
    endingAt end: Int
) {
    var position = end
    var magnitude = value.magnitude
    repeat {
        // At most ten digits, written backwards from end, with room for them and a sign before it.
        position &-= 1
        text[position] = Output(truncatingIfNeeded: 0x30 | magnitude % 10)
        magnitude /= 10
    } while magnitude != 0
    if value < 0 {
        // The sign's place, before the digits.
        position &-= 1
        text[position] = 0x2D
    }
}

// MARK: The Access-Control-Request-Headers value

/// The names crossOriginAccessControlRequestHeadersValue() sorts on the stack; more are sorted on the heap.
private let crossOriginAccessControlInlineNameCount = 16

/// A name the Access-Control-Request-Headers value joins: its ASCII-lowercased code units are `length` code units of a
/// pool from `start`, and `is8Bit` is whether its String is 8-bit.
private struct CrossOriginAccessControlName: BitwiseCopyable {
    var start = 0
    var length = 0
    var is8Bit = true
}

/// The Access-Control-Request-Headers value of the headers in `commonHeaders` and `uncommonHeaders`, with `names` room
/// for each of their names.
///
/// Each name is ASCII-lowercased once into a pool of 8-bit code units, or of 16-bit ones when a name is 16-bit, which
/// holds 256 code units on the stack and the rest on the heap.
private func crossOriginAccessControlJoinedNames(
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ names: inout MutableSpan<CrossOriginAccessControlName>
) -> WTF.String {
    do {
        var pool = InlineArray<256, UInt8>(repeating: 0)
        var poolSpan = pool.mutableSpan
        if let count = crossOriginAccessControlCollectNames(commonHeaders, uncommonHeaders, &names, &poolSpan) {
            return crossOriginAccessControlSortedNames(&names, count, poolSpan.span)
        }
    }
    do {
        var pool = InlineArray<256, UInt16>(repeating: 0)
        var poolSpan = pool.mutableSpan
        if let count = crossOriginAccessControlCollectNames(commonHeaders, uncommonHeaders, &names, &poolSpan) {
            return crossOriginAccessControlSortedNames(&names, count, poolSpan.span)
        }
    }
    var poolLength = 0
    for index in commonHeaders.indices where !crossOriginAccessControlIsSafeRequestHeader(commonHeaders[index]) {
        // Lengths of Strings in one map: far from overflowing.
        poolLength &+= Int(WebCore.securityPoliciesHTTPHeaderNameString(commonHeaders[index].key).length())
    }
    for index in uncommonHeaders.indices {
        // Lengths of Strings in one map: far from overflowing.
        poolLength &+= crossOriginAccessControlLength(uncommonHeaders[index].key)
    }
    var pool = UniqueArray<UInt16>(repeating: 0, count: poolLength)
    var poolSpan = pool.mutableSpan
    // The pool has room for every name in either width.
    let count = crossOriginAccessControlCollectNames(commonHeaders, uncommonHeaders, &names, &poolSpan) ?? 0
    return crossOriginAccessControlSortedNames(&names, count, poolSpan.span)
}

/// The length of `string`.
private func crossOriginAccessControlLength(_ string: borrowing WTF.String) -> Int {
    Int(string.length())
}

/// Records in `names`, and copies ASCII-lowercased into `pool`, the names of the headers in `commonHeaders` that are
/// not CORS-safelisted request headers, then those of every header in `uncommonHeaders`, in that order, and returns how
/// many there are.
///
/// Nil when `pool` is too short for them, or has 8-bit code units and a name is 16-bit.
private func crossOriginAccessControlCollectNames<PoolCodeUnit: HTTPHeaderStringCodeUnit>(
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ names: inout MutableSpan<CrossOriginAccessControlName>,
    _ pool: inout MutableSpan<PoolCodeUnit>
) -> Int? {
    var count = 0
    var poolLength = 0
    for index in commonHeaders.indices {
        if crossOriginAccessControlIsSafeRequestHeader(commonHeaders[index]) {
            continue
        }
        let name = WebCore.securityPoliciesHTTPHeaderNameString(commonHeaders[index].key)
        guard let name = crossOriginAccessControlCollectName(name, &pool, &poolLength) else {
            return nil
        }
        names[count] = name
        // At most one name per header of the map, which names has room for.
        count &+= 1
    }
    for index in uncommonHeaders.indices {
        guard let name = crossOriginAccessControlCollectName(uncommonHeaders[index].key, &pool, &poolLength) else {
            return nil
        }
        names[count] = name
        // At most one name per header of the map, which names has room for.
        count &+= 1
    }
    return count
}

/// Copies `string` ASCII-lowercased into `pool` from `poolLength`, which it moves past it, and returns where it is.
///
/// Nil when `pool` is too short for it, or has 8-bit code units and `string` is 16-bit and not empty.
private func crossOriginAccessControlCollectName<PoolCodeUnit: HTTPHeaderStringCodeUnit>(
    _ string: borrowing WTF.String,
    _ pool: inout MutableSpan<PoolCodeUnit>,
    _ poolLength: inout Int
) -> CrossOriginAccessControlName? {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !bytes.isEmpty {
        return crossOriginAccessControlCollectName(bytes, is8Bit: true, &pool, &poolLength)
    }
    let units: Span<UInt16> = string.checkedSpan16()
    if units.isEmpty {
        return CrossOriginAccessControlName(start: poolLength, length: 0, is8Bit: string.is8Bit())
    }
    if PoolCodeUnit.bitWidth < 16 {
        return nil
    }
    return crossOriginAccessControlCollectName(units, is8Bit: false, &pool, &poolLength)
}

private func crossOriginAccessControlCollectName<CodeUnit: HTTPHeaderStringCodeUnit, PoolCodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    is8Bit: Bool,
    _ pool: inout MutableSpan<PoolCodeUnit>,
    _ poolLength: inout Int
) -> CrossOriginAccessControlName? {
    let start = poolLength
    // poolLength is within the pool.
    guard characters.count <= pool.count &- start else {
        return nil
    }
    for index in characters.indices {
        let codeUnit = HTTPHeaderCodeUnits.toASCIILower(HTTPHeaderCodeUnits.value(characters[index]))
        // Below the pool's count, checked above.
        pool[start &+ index] = PoolCodeUnit(truncatingIfNeeded: codeUnit)
    }
    // Within the pool, checked above.
    poolLength = start &+ characters.count
    return CrossOriginAccessControlName(start: start, length: characters.count, is8Bit: is8Bit)
}

/// The first `count` of `names`, sorted by code point with equal names in the order they were collected, joined with
/// commas in the text a StringBuilder gives: the first name alone is kept as it is, the null string when it is empty;
/// once more is appended, the text is 16-bit if the first name is, or if a later one is 16-bit with more than one
/// character or one above U+00FF.
///
/// The null string when there is no name.
private func crossOriginAccessControlSortedNames<PoolCodeUnit: HTTPHeaderStringCodeUnit>(
    _ names: inout MutableSpan<CrossOriginAccessControlName>,
    _ count: Int,
    _ pool: Span<PoolCodeUnit>
) -> WTF.String {
    // Binary insertion: each name goes after every name it does not sort before.
    var sorted = 1
    while sorted < count {
        let name = names[sorted]
        // Each name lies within the pool, so its end cannot overflow.
        let characters = pool.extracting(name.start..<name.start &+ name.length)
        var low = 0
        var high = sorted
        while low < high {
            // Two indices below count.
            let middle = low &+ (high &- low) / 2
            let other = names[middle]
            // Within the pool.
            if crossOriginAccessControlCodePointLessThan(characters, pool.extracting(other.start..<other.start &+ other.length)) {
                high = middle
            } else {
                // Below high.
                low = middle &+ 1
            }
        }
        var index = sorted
        while index > low {
            // Above low, which is at least 0.
            names[index] = names[index &- 1]
            index &-= 1
        }
        names[low] = name
        // Below count.
        sorted &+= 1
    }

    if count == 0 {
        return WTF.String()
    }
    var is8Bit = names[0].is8Bit
    // The commas between the names.
    var length = count &- 1
    for index in 0..<count {
        let name = names[index]
        // Lengths of Strings in one map: far from overflowing.
        length &+= name.length
        if index > 0 && !name.is8Bit && name.length != 0 {
            if name.length != 1 || pool[name.start] > 0xFF {
                is8Bit = false
            }
        }
    }
    if length == 0 {
        return WTF.String()
    }
    let sortedNames = names.span
    if is8Bit {
        return crossOriginAccessControlMakeString(UInt8.self, length) { text in
            crossOriginAccessControlJoin(sortedNames, count, pool, &text)
        }
    }
    return crossOriginAccessControlMakeString(UInt16.self, length) { text in
        crossOriginAccessControlJoin(sortedNames, count, pool, &text)
    }
}

/// Writes the first `count` of `names` into `text` with a comma between each two.
private func crossOriginAccessControlJoin<PoolCodeUnit: HTTPHeaderStringCodeUnit, Output: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ names: Span<CrossOriginAccessControlName>,
    _ count: Int,
    _ pool: Span<PoolCodeUnit>,
    _ text: inout MutableSpan<Output>
) {
    var position = 0
    for index in 0..<count {
        if index > 0 {
            text[position] = 0x2C
            // Below the text's length, which counts the commas.
            position &+= 1
        }
        let name = names[index]
        // Within the pool.
        position = crossOriginAccessControlCopy(pool.extracting(name.start..<name.start &+ name.length), to: &text, at: position)
    }
}
