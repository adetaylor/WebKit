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

#if USE_SWIFT_CONTENT_SECURITY_POLICY

#include <wtf/text/WTFString.h>

namespace WebCore {

// The offsets of a URL's parts in URL::string(), and its length and width.
struct ContentSecurityPolicyURLBounds {
    unsigned length;
    bool is8Bit;
    unsigned protocolEnd;
    unsigned hostStart;
    unsigned hostEnd;
    unsigned pathStart;
    unsigned pathEnd;
    uint16_t port;
    bool hasPort;
    bool isValid;
    bool protocolIsInHTTPFamily;
    // defaultPortForProtocol(protocol()).
    uint16_t defaultPort;
    bool hasDefaultPort;
};

// A hash source, a hash of inline content or an integrity digest, with its bytes in little-endian words.
// A length above 64 matches no hash source.
struct ContentSecurityPolicyDigest {
    uint8_t algorithm;
    uint8_t length;
    uint64_t words[8];
};

// The hashes of inline content: one per algorithm the policies use.
struct ContentSecurityPolicyContentHashes {
    ContentSecurityPolicyDigest digests[3];
    uint8_t count;
};

// What ContentSecurityPolicy's Swift implementation asks of the policy it is called for, on the calling thread.
struct ContentSecurityPolicyCallbacks {
    static void logToConsole(String message);
    static String enforceSandboxPolicy(String policy);
    static bool isPublicSuffix(String host);
    static bool isLocalHostOrLoopbackIPAddress(String host);
    static bool decodedPathSegmentsMatch(String a, String b);
    static uint16_t defaultPort(bool isSecure);
    static ContentSecurityPolicyDigest parseHashSource(String source);

    static ContentSecurityPolicyDigest integrityDigest(unsigned index);
    // The URL of the ancestor at `index`, nearest first, made from its origin, or false past the last one.
    static bool frameAncestorURL(unsigned index, String& url, ContentSecurityPolicyURLBounds&);
    static String blockedURLForConsole();
    static void reportViolation(const String& directive, const String& header, bool isReportOnly, bool shouldReportSample, std::span<const String> reportToTokens NOESCAPE, std::span<const String> reportURIs NOESCAPE, const String& consoleMessage, const String& sample, const String& directiveTextForInspector);
};

} // namespace WebCore

#endif // USE_SWIFT_CONTENT_SECURITY_POLICY
