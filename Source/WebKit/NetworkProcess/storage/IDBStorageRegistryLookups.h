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

// Included after WebKit-Swift.h: the IPC message checks on identifiers that came from the web process.

#include "Connection.h"
#include "IDBStorageConnectionToClient.h"
#include "IDBStorageEndpointHolder.h"
#include <WebCore/IDBResourceIdentifier.h>
#include <optional>

#define IDB_LOOKUP_MESSAGE_CHECK(assertion, connection) MESSAGE_CHECK_WITH_RETURN_VALUE_BASE(assertion, connection, std::nullopt)

namespace WebKit {

class NetworkStorageManager;

// The client connection a request names, made with its endpoint on first use; the endpoint must send on this IPC
// connection.
inline std::optional<WebCore::IDBConnectionIdentifier> idbEnsureConnectionToClient(IDBStorageRegistry& registry, IPC::Connection& ipcConnection, const WebCore::IDBResourceIdentifier& requestIdentifier, NetworkStorageManager& networkStorageManager)
{
    IDB_LOOKUP_MESSAGE_CHECK(requestIdentifier.connectionIdentifier(), ipcConnection);
    auto identifier = *requestIdentifier.connectionIdentifier();
    auto ipcConnectionIdentifier = ipcConnection.uniqueID().toUInt64();
    auto endpointConnection = registry.endpointIPCConnection(identifier);
    if (!endpointConnection) {
        registry.addEndpoint(IDBStorageEndpointHolder::create(makeUnique<IDBStorageConnectionToClient>(ipcConnection.uniqueID(), identifier, networkStorageManager)).ptr(), ipcConnectionIdentifier, identifier);
        return identifier;
    }

    IDB_LOOKUP_MESSAGE_CHECK(endpointConnection.get() == ipcConnectionIdentifier, ipcConnection);
    return identifier;
}

inline std::optional<IDBDatabaseConnectionRoute> idbDatabaseConnectionRoute(IDBStorageRegistry& registry, WebCore::IDBDatabaseConnectionIdentifier identifier, IPC::Connection& ipcConnection)
{
    auto lookup = registry.connection(identifier, ipcConnection.uniqueID().toUInt64());
    IDB_LOOKUP_MESSAGE_CHECK(!lookup.isInvalidMessage(), ipcConnection);
    if (!lookup.isFound())
        return std::nullopt;
    return lookup.getFound();
}

inline std::optional<IDBTransactionRoute> idbTransactionRoute(IDBStorageRegistry& registry, const WebCore::IDBResourceIdentifier& identifier, IPC::Connection& ipcConnection)
{
    auto lookup = registry.transaction(identifier, ipcConnection.uniqueID().toUInt64());
    IDB_LOOKUP_MESSAGE_CHECK(!lookup.isInvalidMessage(), ipcConnection);
    if (!lookup.isFound())
        return std::nullopt;
    return lookup.getFound();
}

} // namespace WebKit

#undef IDB_LOOKUP_MESSAGE_CHECK
