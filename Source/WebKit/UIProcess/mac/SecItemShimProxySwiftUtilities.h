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

#include "SecItemRequestData.h"
#include "SecItemResponseData.h"
#include "SecItemShimProxyMessages.h"
#include <wtf/RefCountable.h>
#include <wtf/SwiftBridging.h>

#if ENABLE(SEC_ITEM_SHIM_PROXY_SWIFT)

// Workaround for rdar://170233903: invoke the completion handler from C++ to avoid Swift needing
// to construct or move SecItemResponseData (non-trivially-moveable). Only trivially-safe types
// (OSStatus, CFTypeRef?) cross the Swift/C++ boundary here.
// Both SecItemRequestSyncCompletionHandler and SecItemRequestCompletionHandler resolve to
// the same underlying type, so one overload covers both.
inline void callCompletionHandlerWithStatus(CompletionHandlers::SecItemShimProxy::SecItemRequestCompletionHandler& fn, OSStatus status)
{
    (*fn)(WebKit::SecItemResponseData { status, nullptr });
}

// For CopyMatching: inspects result type to build the correct SecItemResponseData variant.
void callCompletionHandlerWithCopyMatchingResult(CompletionHandlers::SecItemShimProxy::SecItemRequestCompletionHandler& fn, OSStatus resultCode, CFTypeRef _Nullable result);

// Accessors for SecItemRequestData with explicit nullability and no-retain annotation (for Swift interop)
inline CF_RETURNS_NOT_RETAINED CFDictionaryRef _Nullable secItemRequestQuery(const WebKit::SecItemRequestData& request)
{
    return request.query();
}

inline CF_RETURNS_NOT_RETAINED CFDictionaryRef _Nullable secItemRequestAttributesToMatch(const WebKit::SecItemRequestData& request)
{
    return request.attributesToMatch();
}

inline WebKit::SecItemRequestData::Type secItemRequestType(const WebKit::SecItemRequestData& request)
{
    return request.type();
}

// Validates that a dictionary received over IPC doesn't contain in-memory objects
// that would be unsafe to act on (rdar://104253249).
bool secItemDictionaryContainsInMemoryObject(CFDictionaryRef _Nullable);

// Workaround for rdar://162357139
template<typename T>
inline bool secItemContentsMatch(const T& lhs, const T& rhs)
{
    return lhs == rhs;
}

#endif // ENABLE(SEC_ITEM_SHIM_PROXY_SWIFT)

#endif // ENABLE(SEC_ITEM_SHIM)
