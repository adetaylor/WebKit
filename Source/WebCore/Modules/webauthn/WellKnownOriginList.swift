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

// ENABLE(WEB_AUTHN) (PlatformEnableCocoa.h): every Cocoa platform but watchOS and Mac Catalyst.
#if !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST

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
internal import wtf
internal import WebCore_Private.Core.CBORBytes
internal import WebCore_Private.Core.WellKnownOriginList

// The related-origins list of https://w3c.github.io/webauthn/#sctn-related-origins: a JSON object whose member holds an
// array of origins, parsed by `WellKnownCandidates::parse`.

/// Calls `visit` with the index and the candidate of each listed origin the policy examines, until it returns true.
///
/// A candidate that is not a valid URL, or whose host has no registrable label, is skipped without counting. At most
/// `maxCandidates` are examined, and an origin of a new label is skipped once `maxRegistrableOriginLabels` labels have been
/// seen, so a list of many origins under one label is still read to its end.
private func forEachValidOrigin(
    _ candidates: WebCore.WellKnownCandidates,
    _ policy: WebCore.WellKnownOriginListPolicy,
    _ visit: (Int, WebCore.WellKnownCandidate) -> Bool
) {
    var labelsSeen: [WTF.String] = []
    labelsSeen.reserveCapacity(min(policy.maxRegistrableOriginLabels, candidates.size()))
    var examined = 0

    for index in 0..<candidates.size() {
        if examined >= policy.maxCandidates {
            break
        }

        let candidate = candidates.candidate(index)
        let label = candidate.label
        if label.isEmpty() {
            continue
        }

        examined += 1

        let alreadySeen = labelsSeen.contains { $0 == label }
        if labelsSeen.count >= policy.maxRegistrableOriginLabels && !alreadySeen {
            continue
        }

        if visit(index, candidate) {
            return
        }

        if !alreadySeen {
            labelsSeen.append(label)
        }
    }
}

/// Whether `callerOrigin` is listed in the array `resource` holds as `memberName`; `.Malformed` when the resource is not
/// such a list.
public func wellKnownFindOrigin(
    _ callerOrigin: WebCore.SecurityOriginData,
    _ resource: Span<UInt8>,
    _ memberName: WTF.String,
    _ policy: WebCore.WellKnownOriginListPolicy
) -> WebCore.WellKnownOriginListResult {
    // An empty Span cannot cross to the std::span parameter: it traps.
    var candidates = WebCore.WellKnownCandidates()
    guard !resource.isEmpty, candidates.parse(resource, memberName, policy.maxResourceSize) else {
        return .Malformed
    }

    var result = WebCore.WellKnownOriginListResult.NotFound
    forEachValidOrigin(candidates, policy) { _, candidate in
        if candidate.isOrigin(callerOrigin) {
            result = .Found
            return true
        }
        return false
    }
    return result
}

/// The origins the array `resource` holds as `memberName` lists, as written, within the policy; none when the resource is
/// not such a list.
public func wellKnownListedOrigins(
    _ resource: Span<UInt8>,
    _ memberName: WTF.String,
    _ policy: WebCore.WellKnownOriginListPolicy
) -> WebCore.WellKnownStringVector {
    var candidates = WebCore.WellKnownCandidates()
    guard !resource.isEmpty, candidates.parse(resource, memberName, policy.maxResourceSize) else {
        return WebCore.WellKnownStringVector()
    }

    var accepted = WebCore.WellKnownStringVector()
    forEachValidOrigin(candidates, policy) { index, _ in
        accepted.append(consuming: candidates.strings[index])
        return false
    }
    return accepted
}

/// The body of `findOriginInWellKnownList`, which forwards here.
///
/// `resource` is the caller's buffer (a response body or a test's string): it stays allocated, at its length, for the
/// call, nothing here or in the C++ it calls writes it, and its bytes have no invalid bit patterns.
/// FIXME: Take a `Span<UInt8>` parameter once a `std::span` can cross safely (rdar://186723514).
@_expose(Cxx)
func webAuthnFindOriginInWellKnownList(
    _ callerOrigin: consuming WebCore.SecurityOriginData,
    _ resource: cbor.ByteSpan,
    _ memberName: consuming WTF.String,
    _ policy: WebCore.WellKnownOriginListPolicy
) -> WebCore.WellKnownOriginListResult {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: resource)
    return wellKnownFindOrigin(callerOrigin, bytes, memberName, policy)
}

/// The body of `parseOriginsFromWellKnownList`, which forwards here.
///
/// `resource` is the caller's buffer: it stays allocated, at its length, for the call, nothing here or in the C++ it
/// calls writes it, and its bytes have no invalid bit patterns.
/// FIXME: Take a `Span<UInt8>` parameter once a `std::span` can cross safely (rdar://186723514).
@_expose(Cxx)
func webAuthnParseOriginsFromWellKnownList(
    _ resource: cbor.ByteSpan,
    _ memberName: consuming WTF.String,
    _ policy: WebCore.WellKnownOriginListPolicy
) -> WebCore.WellKnownStringVector {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: resource)
    return wellKnownListedOrigins(bytes, memberName, policy)
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
