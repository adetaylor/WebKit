/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "CrossOriginEmbedderPolicy.h"
#include "CrossOriginOpenerPolicy.h"
#include "DocumentIsolationPolicy.h"
#include "ExceptionOr.h"
#include "FetchHeadersGuard.h"
#include "HTTPHeaderMap.h"
#include "HTTPHeaderParsersTypes.h"
#include "IntegrityPolicy.h"
#include "OriginAgentClusterPolicy.h"
#include "ReferrerPolicy.h"
#include "ResourceCryptographicDigest.h"
#include "ResourceResponse.h"
#include "SandboxFlags.h"
#include "StoredCredentialsPolicy.h"
#include <optional>
#include <wtf/Function.h>
#include <wtf/KeyValuePair.h>
#include <wtf/Markable.h>
#include <wtf/Seconds.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/WTFString.h>

// The types that the Swift security policies, Fetch headers and response checks exchange with their C++ callers.

namespace WebCore {

using SecurityPoliciesOptionalString = std::optional<String>;
using SecurityPoliciesStringVector = Vector<String>;
using SecurityPoliciesStringVectorVector = Vector<Vector<String>>;
using SecurityPoliciesOptionalStringPair = std::optional<KeyValuePair<String, String>>;
using SecurityPoliciesOptionalIntegrityPolicy = std::optional<IntegrityPolicy>;
using SecurityPoliciesExceptionOrVoid = ExceptionOr<void>;
using SecurityPoliciesExceptionOrString = ExceptionOr<String>;
using SecurityPoliciesExceptionOrBool = ExceptionOr<bool>;
using SecurityPoliciesMarkableWallTime = Markable<WallTime>;
using SecurityPoliciesMarkableSeconds = Markable<Seconds>;
using SecurityPoliciesOptionalWallTime = std::optional<WallTime>;
using SecurityPoliciesOptionalSeconds = std::optional<Seconds>;
using SecurityPoliciesVaryingHeaders = Vector<std::pair<String, String>>;
using SecurityPoliciesHeaderValueFunction = Function<String(const String&)>;

// The headers a filtered or sanitized response keeps: every header when removesHeaders is false, and otherwise each common
// header whose name's bit is set in commonNamesLow or commonNamesHigh, each of the first 64 uncommon headers whose
// position's bit is set in uncommonPositions, and each later uncommon header whose byte in laterUncommonPositions is not 0.
struct SecurityPoliciesKeepMask {
    uint64_t commonNamesLow { 0 };
    uint64_t commonNamesHigh { 0 };
    uint64_t uncommonPositions { 0 };
    Vector<uint8_t> laterUncommonPositions;
    bool removesHeaders { false };
};

// What generateReferrerHeader() and generateOriginHeader() send. None is the null String, NeedsCanRequest asks again
// with the result of the origin's canRequest(), and NeedsSchemes asks again with the schemes read.
enum class SecurityPolicyReferrerOutcome : uint8_t { None, Origin, Full, NeedsCanRequest, NeedsSchemes };

// A policy's two header values. A null String is no header.
struct SecurityPoliciesPolicyHeaderValues {
    String value;
    String reportOnlyValue;
};

// Sets each of a policy's two headers whose value is not null.
SWIFT_UNSAFE inline void securityPoliciesSetPolicyHeaders(ResourceResponse& response, HTTPHeaderName name, HTTPHeaderName reportOnlyName, SecurityPoliciesPolicyHeaderValues values)
{
    if (!values.value.isNull())
        response.setHTTPHeaderField(name, WTF::move(values.value));
    if (!values.reportOnlyValue.isNull())
        response.setHTTPHeaderField(reportOnlyName, WTF::move(values.reportOnlyValue));
}

// The message is the null String when every token is valid.
struct SandboxPolicyParseResult {
    String invalidTokensErrorMessage;
    uint16_t flags;
};

// The strongest metadata's algorithm in ResourceCryptographicDigest::Algorithm's values. None is empty parsed metadata.
enum class SubresourceIntegrityStrongestAlgorithm : uint8_t { None = 0, SHA256 = std::to_underlying(ResourceCryptographicDigest::Algorithm::SHA256), SHA384 = std::to_underlying(ResourceCryptographicDigest::Algorithm::SHA384), SHA512 = std::to_underlying(ResourceCryptographicDigest::Algorithm::SHA512) };

// The characters after the feature name, which hold its allowlist, are [remainingStart, remainingStart + remainingLength).
struct PermissionsPolicyFeatureIdentifier {
    uint32_t remainingStart;
    uint32_t remainingLength;
    uint8_t feature;
};

// The groups of PermissionsPolicy::Feature that the build enables.
#if ENABLE(DEVICE_ORIENTATION)
constexpr bool permissionsPolicyHasDeviceOrientationFeatures = true;
#else
constexpr bool permissionsPolicyHasDeviceOrientationFeatures = false;
#endif
#if ENABLE(WEB_AUTHN)
constexpr bool permissionsPolicyHasWebAuthenticationFeatures = true;
#else
constexpr bool permissionsPolicyHasWebAuthenticationFeatures = false;
#endif
#if ENABLE(WEBXR)
constexpr bool permissionsPolicyHasWebXRFeatures = true;
#else
constexpr bool permissionsPolicyHasWebXRFeatures = false;
#endif

// findHTTPHeaderName() takes a StringView and httpHeaderNameString() returns an ASCIILiteral, which Swift cannot use.
inline bool securityPoliciesFindHTTPHeaderName(const String& name, HTTPHeaderName& headerName)
{
    return findHTTPHeaderName(name, headerName);
}

inline String securityPoliciesHTTPHeaderNameString(HTTPHeaderName name)
{
    // Swift can make an HTTPHeaderName of any value, and httpHeaderNameString() checks the name only in debug builds.
    RELEASE_ASSERT(static_cast<unsigned>(name) < numHTTPHeaderNames);
    return httpHeaderNameString(name);
}

// An 8-bit String's characters as bytes, and no bytes for a 16-bit or null String, so Swift reads them in one call.
inline std::span<const uint8_t> securityPoliciesSpan8(const String& string LIFETIME_BOUND) { return string.is8Bit() ? byteCast<uint8_t>(string.span8()) : std::span<const uint8_t> { }; }

// The pair FetchHeaders::Iterator::next() returns, with the key and the value moved in: Swift's std::optional initializer copies.
inline SecurityPoliciesOptionalStringPair securityPoliciesOptionalStringPair(String&& key, String&& value) { return KeyValuePair<String, String> { WTF::move(key), WTF::move(value) }; }

} // namespace WebCore
