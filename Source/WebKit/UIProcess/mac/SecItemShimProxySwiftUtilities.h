/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#if ENABLE(SEC_ITEM_SHIM)

#include <Security/SecCertificate.h>
#include "Connection.h"
#include "SecItemRequestData.h"
#include "SecItemResponseData.h"
#include "SecItemShimProxyMessages.h"
#include <wtf/RefCountable.h>
#include <wtf/SwiftBridging.h>

#if ENABLE(SEC_ITEM_SHIM_PROXY_SWIFT)

// Factories that construct optional<SecItemResponseData> for the simple result cases, so Swift
// can call completionHandler.pointee(consuming:) directly. Returns optional<> to match the
// completion handler's parameter type (CompletionHandler<void(std::optional<SecItemResponseData>&&)>).

// For error/status-only results (no result item: Add, Update, Delete, and error paths).
inline std::optional<WebKit::SecItemResponseData> makeSecItemResponseDataWithStatus(OSStatus status)
{
    return WebKit::SecItemResponseData { status, nullptr };
}

// For CopyMatching when result is a plain CFTypeRef (not a typed certificate/keychain array).
inline std::optional<WebKit::SecItemResponseData> makeSecItemResponseDataWithCFTypeRef(OSStatus status, CFTypeRef _Nonnull result)
{
    return WebKit::SecItemResponseData { status, RetainPtr<CFTypeRef> { result } };
}

// For CopyMatching when result is an array of SecCertificateRefs.
inline std::optional<WebKit::SecItemResponseData> makeSecItemResponseDataWithCertCFArray(OSStatus status, CFArrayRef _Nonnull certs)
{
    CFIndex count = CFArrayGetCount(certs);
    Vector<RetainPtr<SecCertificateRef>> v;
    v.reserveInitialCapacity(count);
    for (CFIndex i = 0; i < count; ++i)
        v.append(static_cast<SecCertificateRef>(const_cast<void*>(CFArrayGetValueAtIndex(certs, i))));
    return WebKit::SecItemResponseData { status, WTF::move(v) };
}

#if HAVE(SEC_KEYCHAIN)
#import <Security/SecKeychainItem.h>
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
// For CopyMatching when result is an array of SecKeychainItemRefs.
inline std::optional<WebKit::SecItemResponseData> makeSecItemResponseDataWithKeychainCFArray(OSStatus status, CFArrayRef _Nonnull items)
{
    CFIndex count = CFArrayGetCount(items);
    Vector<RetainPtr<SecKeychainItemRef>> v;
    v.reserveInitialCapacity(count);
    for (CFIndex i = 0; i < count; ++i)
        v.append(static_cast<SecKeychainItemRef>(const_cast<void*>(CFArrayGetValueAtIndex(items, i))));
    return WebKit::SecItemResponseData { status, WTF::move(v) };
}
ALLOW_DEPRECATED_DECLARATIONS_END
#endif

// FIXME(rdar://168139740): need idiomatic Swift MESSAGE_CHECK equivalents
// Terminates the connection for a message that failed validation.
inline void secItemMarkConnectionInvalid(IPC::Connection* _Nonnull connection)
{
    if (connection)
        connection->markCurrentlyDispatchedMessageAsInvalid("SecItemShimProxy: received IPC message with invalid data"_s);
}

#endif // ENABLE(SEC_ITEM_SHIM_PROXY_SWIFT)

#endif // ENABLE(SEC_ITEM_SHIM)
