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
// those operators take, so they are imported for the operator lookup to resolve.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IDBConnectionToClientDelegate
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
internal import WebCore_Private.Core.IDBDatabaseNameAndVersion
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyPath
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBResultData
internal import WebCore_Private.Core.IDBValue

/// The server's side of one client's connection: the delegate that carries results back through IPC or the client's queue,
/// and the identifiers of the database connections the client opened, so that they can be closed together when it goes away.
@_spi(IDBServer)
public final class IDBConnectionToClient {
    /// The identifier the client chose, which every request from that client carries.
    public let identifier: WebCore.IDBConnectionIdentifier
    private(set) var delegate: WebCore.IDBServer.IDBConnectionToClientDelegate?
    var databaseConnections: IDBIdentifierSet<WebCore.IDBDatabaseConnectionIdentifier> = []
    var isClosed = false
    var isClientSuspended = false

    init(identifier: WebCore.IDBConnectionIdentifier, delegate: WebCore.IDBServer.IDBConnectionToClientDelegate) {
        self.identifier = identifier
        self.delegate = delegate
    }

    /// Stops delivering results, for a client that is going away; later results are dropped.
    ///
    /// The C++ delegate may be destroyed after this call, so nothing sends to it again.
    public func clearDelegate() {
        delegate = nil
    }
}

// The server's results, sent to the client through its delegate. A result for a client whose delegate is gone is
// dropped.
extension IDBConnectionToClient {
    func didDeleteDatabase(_ result: WebCore.IDBResultData) { delegate?.didDeleteDatabase(result) }
    func didOpenDatabase(_ result: WebCore.IDBResultData) { delegate?.didOpenDatabase(result) }

    func didAbortTransaction(_ transactionIdentifier: WebCore.IDBResourceIdentifier, error: WebCore.IDBError) {
        delegate?.didAbortTransaction(transactionIdentifier, error)
    }

    func didCommitTransaction(_ transactionIdentifier: WebCore.IDBResourceIdentifier, error: WebCore.IDBError) {
        delegate?.didCommitTransaction(transactionIdentifier, error)
    }

    func didCreateObjectStore(_ result: WebCore.IDBResultData) { delegate?.didCreateObjectStore(result) }
    func didDeleteObjectStore(_ result: WebCore.IDBResultData) { delegate?.didDeleteObjectStore(result) }
    func didRenameObjectStore(_ result: WebCore.IDBResultData) { delegate?.didRenameObjectStore(result) }
    func didClearObjectStore(_ result: WebCore.IDBResultData) { delegate?.didClearObjectStore(result) }
    func didCreateIndex(_ result: WebCore.IDBResultData) { delegate?.didCreateIndex(result) }
    func didDeleteIndex(_ result: WebCore.IDBResultData) { delegate?.didDeleteIndex(result) }
    func didRenameIndex(_ result: WebCore.IDBResultData) { delegate?.didRenameIndex(result) }
    func didPutOrAdd(_ result: WebCore.IDBResultData) { delegate?.didPutOrAdd(result) }
    func didGetRecord(_ result: WebCore.IDBResultData) { delegate?.didGetRecord(result) }
    func didGetAllRecords(_ result: WebCore.IDBResultData) { delegate?.didGetAllRecords(result) }
    func didGetCount(_ result: WebCore.IDBResultData) { delegate?.didGetCount(result) }
    func didDeleteRecord(_ result: WebCore.IDBResultData) { delegate?.didDeleteRecord(result) }
    func didOpenCursor(_ result: WebCore.IDBResultData) { delegate?.didOpenCursor(result) }
    func didIterateCursor(_ result: WebCore.IDBResultData) { delegate?.didIterateCursor(result) }

    func fireVersionChangeEvent(
        _ connection: WebCore.IDBDatabaseConnectionIdentifier,
        requestIdentifier: WebCore.IDBResourceIdentifier,
        requestedVersion: UInt64
    ) {
        delegate?.fireVersionChangeEvent(connection, requestIdentifier, requestedVersion)
    }

    func generateIndexKeyForRecord(
        _ requestIdentifier: WebCore.IDBResourceIdentifier,
        indexInfo: WebCore.IDBIndexInfo,
        keyPath: WebCore.IDBKeyPath?,
        key: WebCore.IDBKeyData,
        value: WebCore.IDBValue,
        recordID: Int64?
    ) {
        let cxxKeyPath = keyPath.map { WebCore.idbOptionalKeyPath($0) } ?? WebCore.idbNoKeyPath()
        let cxxRecordID = recordID.map { WebCore.idbOptionalInt64($0) } ?? WebCore.idbNoInt64()
        delegate?.generateIndexKeyForRecord(requestIdentifier, indexInfo, cxxKeyPath, key, value, cxxRecordID)
    }

    func didStartTransaction(_ transactionIdentifier: WebCore.IDBResourceIdentifier, error: WebCore.IDBError) {
        delegate?.didStartTransaction(transactionIdentifier, error)
    }

    func didCloseFromServer(_ connection: WebCore.IDBDatabaseConnectionIdentifier, error: WebCore.IDBError) {
        delegate?.didCloseFromServer(connection, error)
    }

    func notifyOpenDBRequestBlocked(_ requestIdentifier: WebCore.IDBResourceIdentifier, oldVersion: UInt64, newVersion: UInt64) {
        delegate?.notifyOpenDBRequestBlocked(requestIdentifier, oldVersion, newVersion)
    }

    /// Sends the names and versions that answer `requestIdentifier` to the client, as the vector type its delegate takes.
    ///
    /// Dropped when the client's delegate is gone, like every other result.
    public func didGetAllDatabaseNamesAndVersions(
        _ requestIdentifier: WebCore.IDBResourceIdentifier,
        _ namesAndVersions: [WebCore.IDBDatabaseNameAndVersion]
    ) {
        guard let delegate else {
            return
        }
        var databases = WebCore.makeIDBDatabaseNameAndVersionVector(namesAndVersions.count)
        for nameAndVersion in namesAndVersions {
            WebCore.appendIDBDatabaseNameAndVersion(&databases, nameAndVersion)
        }
        delegate.didGetAllDatabaseNamesAndVersions(requestIdentifier, consuming: databases)
    }

    func registerDatabaseConnection(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        assert(!databaseConnections.contains(connection))
        databaseConnections.insert(connection)
    }

    func unregisterDatabaseConnection(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        databaseConnections.remove(connection)
    }
}
