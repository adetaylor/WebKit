//
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
//

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// those operators take, so they are imported for the operator lookup to resolve (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
internal import WebCore_Private.Core.IDBOpenRequestData
internal import WebCore_Private.Core.IDBResultData

/// A reference type, as `UniqueIDBDatabaseConnection` is, so reading a request out of the database's dictionary copies
/// one reference, not its open request data and its set of connections.
final class ServerOpenDBRequest {
    /// The database's references to the request; it is removed when none is left.
    struct Holders: OptionSet {
        let rawValue: UInt8
        static let pending = Holders(rawValue: 1 << 0)
        static let current = Holders(rawValue: 1 << 1)
    }

    let serial: IDBEntitySerial
    let connectionToClient: IDBConnectionToClient
    let requestData: WebCore.IDBOpenRequestData
    var notifiedBlocked = false
    var notifiedConnectionsOfVersionChange = false
    var connectionsPendingVersionChangeEvent: IDBIdentifierSet<WebCore.IDBDatabaseConnectionIdentifier> = []
    var versionChangeTransaction: IDBEntitySerial?
    var holders: Holders = []

    init(
        serial: IDBEntitySerial,
        connectionToClient: IDBConnectionToClient,
        requestData: __owned WebCore.IDBOpenRequestData,
        holders: Holders
    ) {
        self.serial = serial
        self.connectionToClient = connectionToClient
        self.requestData = requestData
        self.holders = holders
    }
}

extension ServerOpenDBRequest {
    var isOpenRequest: Bool {
        requestData.isOpenRequest()
    }

    var isDeleteRequest: Bool {
        requestData.isDeleteRequest()
    }

    func setConnectionsPendingVersionChangeEvent(_ connections: IDBIdentifierSet<WebCore.IDBDatabaseConnectionIdentifier>) {
        assert(!notifiedConnectionsOfVersionChange)
        notifiedConnectionsOfVersionChange = true
        connectionsPendingVersionChangeEvent = connections
    }

    func connectionClosedOrFiredVersionChangeEvent(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        connectionsPendingVersionChangeEvent.remove(connection)
    }

    var hasConnectionsPendingVersionChangeEvent: Bool {
        !connectionsPendingVersionChangeEvent.isEmpty
    }
}

extension UniqueIDBDatabase {
    /// Tells the client its request is blocked, once per request.
    func maybeNotifyRequestBlocked(openRequest serial: IDBEntitySerial, currentVersion: UInt64) {
        guard let request = openRequests[serial], !request.notifiedBlocked else {
            return
        }

        let requestedVersion = request.isOpenRequest ? request.requestData.requestedVersion() : 0
        request.connectionToClient.notifyOpenDBRequestBlocked(
            request.requestData.requestIdentifier(),
            oldVersion: currentVersion,
            newVersion: requestedVersion
        )
        openRequests[serial]?.notifiedBlocked = true
    }

    /// Delivers an open request's result, and adds its error to the request's version change transaction.
    func didOpenDatabase(openRequest serial: IDBEntitySerial, _ result: WebCore.IDBResultData, error: WebCore.IDBError) {
        guard let request = openRequests[serial] else {
            return
        }

        // Read before delivering: the request is shared, and the delivery can run client code.
        let versionChangeTransaction = request.versionChangeTransaction
        request.connectionToClient.didOpenDatabase(result)
        if let versionChangeTransaction {
            transactions[versionChangeTransaction]?.addOpenRequestResult(error)
        }
    }

    /// Gives the open request its version change transaction, which the request then holds.
    func holdVersionChangeTransaction(_ transaction: IDBEntitySerial, inOpenRequest serial: IDBEntitySerial) {
        let previous = openRequests[serial]?.versionChangeTransaction
        openRequests[serial]?.versionChangeTransaction = transaction
        transactions[transaction]?.holders.insert(.openRequest)
        if let previous, previous != transaction {
            release(transaction: previous, from: .openRequest)
        }
    }
}
