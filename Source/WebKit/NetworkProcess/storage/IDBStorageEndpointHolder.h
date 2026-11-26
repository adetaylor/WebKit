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

#include "IDBStorageConnectionToClient.h"
#include <WebCore/IDBConnectionToClientDelegate.h>
#include <memory>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>

namespace WebKit {

// Keeps a web process connection's IDBStorageConnectionToClient alive for the Swift registry, which hands its delegate
// to the router.
class IDBStorageEndpointHolder : public RefCounted<IDBStorageEndpointHolder> {
public:
    static Ref<IDBStorageEndpointHolder> create(std::unique_ptr<IDBStorageConnectionToClient>&& endpoint)
    {
        return adoptRef(*new IDBStorageEndpointHolder(WTF::move(endpoint)));
    }

    WebCore::IDBServer::IDBConnectionToClientDelegate* delegate() const { return m_endpoint.get(); }

private:
    explicit IDBStorageEndpointHolder(std::unique_ptr<IDBStorageConnectionToClient>&& endpoint)
        : m_endpoint(WTF::move(endpoint))
    {
    }

    const std::unique_ptr<IDBStorageConnectionToClient> m_endpoint;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(refIDBStorageEndpointHolder, derefIDBStorageEndpointHolder);

#if !ENABLE(SWIFT_BASE_CLASS_ANNOTATIONS)
SWIFT_UNSAFE inline void refIDBStorageEndpointHolder(IDBStorageEndpointHolder* holder) { holder->ref(); }
SWIFT_UNSAFE inline void derefIDBStorageEndpointHolder(IDBStorageEndpointHolder* holder) { holder->deref(); }
#endif

} // namespace WebKit
