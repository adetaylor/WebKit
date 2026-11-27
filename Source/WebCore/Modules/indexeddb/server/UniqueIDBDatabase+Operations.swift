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
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBGetAllRecordsData
internal import WebCore_Private.Core.IDBGetRecordData
internal import WebCore_Private.Core.IDBIndexIdentifier
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBIterateCursorData
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyPath
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBRequestData
internal import WebCore_Private.Core.IDBResultData
internal import WebCore_Private.Core.IDBValue
internal import WebCore_Private.Core.IndexKey
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes

extension UniqueIDBDatabase {
    static func idbError(_ code: WebCore.ExceptionCode, _ message: Swift.String? = nil) -> WebCore.IDBError {
        let text = message.map(sqliteIDBString) ?? WTF.String()
        return WebCore.makeIDBServerError(code, text)
    }

    static func quotaError(_ taskName: Swift.String) -> WebCore.IDBError {
        idbError(.QuotaExceededError, "Failed to \(taskName) in database because not enough space for domain")
    }
}

private func spaceCheckResult(granted: Bool) -> IDBSpaceCheckResult {
    granted ? .pass : .fail
}

extension UniqueIDBDatabase {
    static let defaultWriteOperationCost: UInt64 = 4

    private func transactionIdentifier(_ serial: IDBEntitySerial) -> WebCore.IDBResourceIdentifier? {
        transactions[serial]?.identifier
    }

    private func existingObjectStoreIdentifier(named name: WTF.String) -> WebCore.IDBObjectStoreIdentifier? {
        withInfo { WebCore.idbDatabaseInfoObjectStoreIdentifierNamed(&$0, name).value }
    }

    private func hasExistingObjectStore(_ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier) -> Bool {
        withInfo { WebCore.idbDatabaseInfoHasObjectStore(&$0, objectStoreIdentifier) }
    }

    private func existingIndexIdentifier(
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        named name: WTF.String
    ) -> WebCore.IDBIndexIdentifier? {
        withInfo { WebCore.idbDatabaseInfoIndexIdentifierNamed(&$0, objectStoreIdentifier, name).value }
    }

    private func hasExistingIndex(
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier
    ) -> Bool {
        withInfo { WebCore.idbDatabaseInfoHasIndex(&$0, objectStoreIdentifier, indexIdentifier) }
    }

    /// Asks the core for `size` bytes for this database's origin; false when the core is gone.
    private func requestSpace(_ size: UInt64, _ completion: @escaping (Bool) -> Void) -> Bool {
        guard let core else {
            return false
        }
        core.requestSpace(origin: WebCore.idbDatabaseIdentifierOrigin(identifier), size: size, completion)
        return true
    }

    func createObjectStore(
        serial: IDBEntitySerial,
        _ info: WebCore.IDBObjectStoreInfo,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let taskSize = Self.defaultWriteOperationCost &+ Self.estimateSize(info)
            let requested = requestSpace(taskSize) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }
                self.createObjectStore(serial: serial, info, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        if spaceCheck != .pass {
            callback(Self.quotaError("CreateObjectStore"))
            return
        }

        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return callback(Self.idbError(.InvalidStateError, "Backing store has closed"))
        }

        let error = store.createObjectStore(transactionIdentifier, info)
        if error.isNull() {
            withInfo { $0.addExistingObjectStore(info) }
        }

        callback(error)
    }

    func deleteObjectStore(
        serial: IDBEntitySerial,
        _ objectStoreName: WTF.String,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }

                self.deleteObjectStore(serial: serial, objectStoreName, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let objectStoreIdentifier = existingObjectStoreIdentifier(named: objectStoreName) else {
            callback(Self.idbError(.UnknownError, "Attempt to delete non-existant object store"))
            return
        }

        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"))
        }

        let error = store.deleteObjectStore(transactionIdentifier, objectStoreIdentifier)
        if error.isNull() {
            withInfo { $0.deleteObjectStore(objectStoreIdentifier) }
        }

        callback(error)
    }

    func renameObjectStore(
        serial: IDBEntitySerial,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        newName: WTF.String,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let taskSize = Self.defaultWriteOperationCost &+ UInt64(newName.sizeInBytes())
            let requested = requestSpace(taskSize) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }

                self.renameObjectStore(
                    serial: serial,
                    objectStoreIdentifier,
                    newName: newName,
                    callback: callback,
                    spaceCheck: spaceCheckResult(granted: granted)
                )
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        if spaceCheck != .pass {
            callback(Self.quotaError("RenameObjectStore"))
            return
        }

        guard hasExistingObjectStore(objectStoreIdentifier) else {
            callback(Self.idbError(.UnknownError, "Attempt to rename non-existant object store"))
            return
        }

        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"))
        }

        let error = store.renameObjectStore(transactionIdentifier, objectStoreIdentifier, newName: newName)
        if error.isNull() {
            withInfo { $0.renameObjectStore(objectStoreIdentifier, newName) }
        }

        callback(error)
    }

    func clearObjectStore(
        serial: IDBEntitySerial,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }

                self.clearObjectStore(
                    serial: serial,
                    objectStoreIdentifier,
                    callback: callback,
                    spaceCheck: spaceCheckResult(granted: granted)
                )
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"))
        }

        let error = store.clearObjectStore(transactionIdentifier, objectStoreIdentifier)
        callback(error)
    }

    func createIndexAsync(serial: IDBEntitySerial, _ info: WebCore.IDBIndexInfo) {
        let taskSize = Self.defaultWriteOperationCost &+ Self.estimateSize(info)
        let requested = requestSpace(taskSize) { [reference = self.reference] granted in
            // A closed database has nobody to tell.
            guard let self = reference.database, self.transactions.keys.contains(serial) else {
                return
            }

            self.createIndexAsyncAfterQuotaCheck(serial: serial, info, spaceCheck: spaceCheckResult(granted: granted))
        }
        if !requested {
            didCreateIndexAsync(serial: serial, error: Self.idbError(.InvalidStateError))
        }
    }

    private func createIndexAsyncAfterQuotaCheck(serial: IDBEntitySerial, _ info: WebCore.IDBIndexInfo, spaceCheck: IDBSpaceCheckResult) {
        if spaceCheck != .pass {
            return didCreateIndexAsyncForTransaction(
                serial: serial,
                info,
                error: Self.quotaError("CreateIndex"),
                didCreateIndexInBackingStore: false
            )
        }

        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return didCreateIndexAsyncForTransaction(
                serial: serial,
                info,
                error: Self.idbError(.InvalidStateError, "Backing store is closed."),
                didCreateIndexInBackingStore: false
            )
        }

        if !hasInfo {
            return didCreateIndexAsyncForTransaction(
                serial: serial,
                info,
                error: Self.idbError(.InvalidStateError, "Database info is invalid."),
                didCreateIndexInBackingStore: false
            )
        }

        var createIndexError = store.addIndex(transactionIdentifier, info)
        if !createIndexError.isNull() {
            return didCreateIndexAsyncForTransaction(serial: serial, info, error: createIndexError, didCreateIndexInBackingStore: false)
        }

        let objectStoreIdentifier = info.objectStoreIdentifier()
        guard hasExistingObjectStore(objectStoreIdentifier) else {
            return didCreateIndexAsyncForTransaction(
                serial: serial,
                info,
                error: Self.idbError(.InvalidStateError, "Object store does not exist.")
            )
        }

        withInfo { WebCore.idbDatabaseInfoAddIndex(&$0, info) }
        withInfo { $0.setMaxIndexID(info.identifier().toUInt64()) }
        let keyPath = objectStoreKeyPath(objectStoreIdentifier)

        var needsToWaitGenerateIndexKey = false
        store.forEachObjectStoreRecord(transactionIdentifier, objectStoreIdentifier) { recordOrError in
            if !createIndexError.isNull() {
                return
            }

            switch recordOrError {
            case .error(let error):
                createIndexError = error
            case .record(let record):
                if !generateIndexKeyForRecord(serial: serial, info, keyPath: keyPath, record.key, record.value, recordID: record.recordID) {
                    createIndexError = Self.idbError(.UnknownError, "Failed to generate index key for record.")
                    return
                }
                needsToWaitGenerateIndexKey = true
            }
        }

        if !createIndexError.isNull() || !needsToWaitGenerateIndexKey {
            didCreateIndexAsync(serial: serial, error: createIndexError)
        }
    }

    /// The object store's key path, read once for every record of an index being created.
    private func objectStoreKeyPath(_ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier) -> WebCore.IDBKeyPath? {
        let objectStoreInfo = withInfo { WebCore.idbDatabaseInfoObjectStore(&$0, objectStoreIdentifier) }
        return WebCore.idbObjectStoreInfoKeyPath(objectStoreInfo).value
    }

    func didGenerateIndexKeyForRecord(
        serial: IDBEntitySerial,
        _ info: WebCore.IDBIndexInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKey: WebCore.IndexKey,
        recordID: Int64?
    ) {
        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return didCreateIndexAsyncForTransaction(
                serial: serial,
                info,
                error: Self.idbError(.InvalidStateError, "Backing store is closed.")
            )
        }

        let error = store.updateIndexRecordsWithIndexKey(transactionIdentifier, info, key, indexKey, recordID: recordID)
        if !error.isNull() {
            return didCreateIndexAsyncForTransaction(serial: serial, info, error: error)
        }

        if transactions[serial]?.pendingGenerateIndexKeyRequests == 0 {
            didCreateIndexAsyncForTransaction(serial: serial, info, error: WebCore.makeIDBServerNoError())
        }
    }

    private func didCreateIndexAsyncForTransaction(
        serial: IDBEntitySerial,
        _ info: WebCore.IDBIndexInfo,
        error: WebCore.IDBError,
        didCreateIndexInBackingStore: Bool = true
    ) {
        if let store, !error.isNull(), didCreateIndexInBackingStore, let transactionIdentifier = transactionIdentifier(serial) {
            store.revertAddIndex(transactionIdentifier, info.objectStoreIdentifier(), info.identifier())
        }

        didCreateIndexAsync(serial: serial, error: error)
    }

    func deleteIndex(
        serial: IDBEntitySerial,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        indexName: WTF.String,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }

                self.deleteIndex(
                    serial: serial,
                    objectStoreIdentifier,
                    indexName: indexName,
                    callback: callback,
                    spaceCheck: spaceCheckResult(granted: granted)
                )
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"))
        }

        guard hasExistingObjectStore(objectStoreIdentifier) else {
            callback(Self.idbError(.UnknownError, "Attempt to delete index from non-existant object store"))
            return
        }

        guard let indexIdentifier = existingIndexIdentifier(objectStoreIdentifier, named: indexName) else {
            callback(Self.idbError(.UnknownError, "Attempt to delete non-existant index"))
            return
        }

        let error = store.deleteIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier)
        if error.isNull() {
            withInfo { WebCore.idbDatabaseInfoDeleteIndex(&$0, objectStoreIdentifier, indexIdentifier) }
        }

        callback(error)
    }

    func renameIndex(
        serial: IDBEntitySerial,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        newName: WTF.String,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let taskSize = Self.defaultWriteOperationCost &+ UInt64(newName.sizeInBytes())
            let requested = requestSpace(taskSize) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }

                self.renameIndex(
                    serial: serial,
                    objectStoreIdentifier,
                    indexIdentifier,
                    newName: newName,
                    callback: callback,
                    spaceCheck: spaceCheckResult(granted: granted)
                )
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        if spaceCheck != .pass {
            callback(Self.quotaError("RenameIndex"))
            return
        }

        guard let store, let transactionIdentifier = transactionIdentifier(serial) else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"))
        }

        guard hasExistingObjectStore(objectStoreIdentifier) else {
            callback(Self.idbError(.UnknownError, "Attempt to rename index in non-existant object store"))
            return
        }

        guard hasExistingIndex(objectStoreIdentifier, indexIdentifier) else {
            callback(Self.idbError(.UnknownError, "Attempt to rename non-existant index"))
            return
        }

        let error = store.renameIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier, newName: newName)
        if error.isNull() {
            withInfo { WebCore.idbDatabaseInfoRenameIndex(&$0, objectStoreIdentifier, indexIdentifier, newName) }
        }

        callback(error)
    }
}

/// One client putOrAdd request from its space check to its result.
///
/// The space check's continuation captures only this object, so the object is the closure's context: one allocation
/// per put, which both stages read. It names the database through its reference, so a pending space check does not
/// keep the database alive.
final class IDBPutOrAddRequest {
    let reference: IDBDatabaseReference
    let serial: IDBEntitySerial
    let requestData: WebCore.IDBRequestData
    let key: WebCore.IDBKeyData
    let isKeyGenerated: Bool
    let value: WebCore.IDBValue
    let indexKeys: WebCore.IndexIDToIndexKeyMap
    let objectStoreInfo: WebCore.IDBObjectStoreInfo
    let overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode

    init(
        reference: IDBDatabaseReference,
        serial: IDBEntitySerial,
        requestData: WebCore.IDBRequestData,
        key: WebCore.IDBKeyData,
        isKeyGenerated: Bool,
        value: WebCore.IDBValue,
        indexKeys: WebCore.IndexIDToIndexKeyMap,
        objectStoreInfo: WebCore.IDBObjectStoreInfo,
        overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode
    ) {
        self.reference = reference
        self.serial = serial
        self.requestData = requestData
        self.key = key
        self.isKeyGenerated = isKeyGenerated
        self.value = value
        self.indexKeys = indexKeys
        self.objectStoreInfo = objectStoreInfo
        self.overwriteMode = overwriteMode
    }

    /// The space check's answer: the put, if the database is still open.
    func spaceChecked(granted: Bool) {
        // A closed database has nobody to tell.
        guard let database = reference.database else {
            return
        }
        database.putOrAddAfterSpaceCheck(self, spaceCheck: spaceCheckResult(granted: granted))
    }
}

extension UniqueIDBDatabase {
    /// The transaction's putOrAdd up to its space check; the result goes to the transaction's connection.
    func putOrAdd(
        serial: IDBEntitySerial,
        _ requestData: consuming WebCore.IDBRequestData,
        _ key: consuming WebCore.IDBKeyData,
        _ value: consuming WebCore.IDBValue,
        _ indexKeys: WebCore.IndexIDToIndexKeyMap,
        _ overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode
    ) {
        assert(hasInfo)

        let requestIdentifier = requestData.requestIdentifier()
        guard let store else {
            return reportPutOrAdd(
                ofTransaction: serial,
                requestIdentifier,
                Self.idbError(.InvalidStateError, "Backing store is closed"),
                key
            )
        }

        let objectStoreIdentifier = requestData.objectStoreIdentifier()
        guard let objectStoreInfo = store.infoForObjectStore(objectStoreIdentifier) else {
            return reportPutOrAdd(
                ofTransaction: serial,
                requestIdentifier,
                Self.idbError(.InvalidStateError, "Object store cannot be found in the backing store"),
                key
            )
        }

        guard let core else {
            return reportPutOrAdd(ofTransaction: serial, requestIdentifier, Self.idbError(.InvalidStateError), key)
        }

        var usedKeyIsGenerated = false
        var keyNumber: UInt64 = 0
        var revertsGeneratedKey = true
        let transactionIdentifier = requestData.transactionIdentifier()
        defer {
            if revertsGeneratedKey && usedKeyIsGenerated {
                _ = self.store?.revertGeneratedKeyNumber(transactionIdentifier, objectStoreIdentifier, keyNumber)
            }
        }

        let usedKey: WebCore.IDBKeyData
        if objectStoreInfo.autoIncrement() && !key.isValid() {
            let error: WebCore.IDBError
            (error, keyNumber) = store.generateKeyNumber(transactionIdentifier, objectStoreIdentifier)
            if !error.isNull() {
                return reportPutOrAdd(ofTransaction: serial, requestIdentifier, error, WebCore.IDBKeyData())
            }

            var generatedKey = WebCore.IDBKeyData()
            generatedKey.setNumberValue(Double(keyNumber))
            usedKey = generatedKey
            usedKeyIsGenerated = true
        } else {
            usedKey = key
        }

        if overwriteMode == .NoOverwrite {
            let (keyError, keyExists) = store.keyExistsInObjectStore(transactionIdentifier, objectStoreIdentifier, usedKey)
            let error =
                keyError.isNull() && keyExists
                ? Self.idbError(.ConstraintError, "Key already exists in the object store") : keyError

            if !error.isNull() {
                return reportPutOrAdd(ofTransaction: serial, requestIdentifier, error, usedKey)
            }
        }

        var usedIndexKeys = indexKeys
        if usedKeyIsGenerated {
            // If key is generated on server, client does not know about that and uses placeholder in index keys.
            WebCore.idbIndexKeyMapUpdatePlaceholderKeys(&usedIndexKeys, usedKey)
        }

        revertsGeneratedKey = false
        let keySize = Self.estimateSize(usedKey)
        let valueSize = Self.estimateSize(value)
        let indexSize = Self.estimateSize(objectStoreInfo, indexKeys: usedIndexKeys, primaryKeySize: keySize)
        let taskSize = Self.defaultWriteOperationCost &+ keySize &+ valueSize &+ indexSize

        let request = IDBPutOrAddRequest(
            reference: reference,
            serial: serial,
            requestData: requestData,
            key: usedKey,
            isKeyGenerated: usedKeyIsGenerated,
            value: value,
            indexKeys: usedIndexKeys,
            objectStoreInfo: objectStoreInfo,
            overwriteMode: overwriteMode
        )
        core.requestSpace(origin: WebCore.idbDatabaseIdentifierOrigin(identifier), size: taskSize) { granted in
            request.spaceChecked(granted: granted)
        }
    }

    fileprivate func putOrAddAfterSpaceCheck(_ request: IDBPutOrAddRequest, spaceCheck: IDBSpaceCheckResult) {
        assert(hasInfo)

        let requestIdentifier = request.requestData.requestIdentifier()
        guard let store else {
            return reportPutOrAdd(
                ofTransaction: request.serial,
                requestIdentifier,
                Self.idbError(.InvalidStateError, "Backing store is closed"),
                request.key
            )
        }

        let isKeyGenerated = request.isKeyGenerated
        // A generated key is at most 2^53, the key generator's limit, so the conversion cannot trap.
        assert(!isKeyGenerated || request.key.number() <= 0x1p53)
        let keyNumber: UInt64 = isKeyGenerated ? UInt64(request.key.number()) : 0
        let objectStoreIdentifier = request.objectStoreInfo.identifier()
        let transactionIdentifier = request.requestData.transactionIdentifier()
        var revertsGeneratedKey = isKeyGenerated
        defer {
            if revertsGeneratedKey {
                _ = self.store?.revertGeneratedKeyNumber(transactionIdentifier, objectStoreIdentifier, keyNumber)
            }
        }

        if spaceCheck != .pass {
            return reportPutOrAdd(ofTransaction: request.serial, requestIdentifier, Self.quotaError("PutOrAdd"), request.key)
        }

        var error = store.overwriteRecord(transactionIdentifier, request.objectStoreInfo, request.key, request.indexKeys, request.value)
        if !error.isNull() {
            return reportPutOrAdd(ofTransaction: request.serial, requestIdentifier, error, request.key)
        }

        if request.overwriteMode != .OverwriteForCursor && request.objectStoreInfo.autoIncrement() && request.key.type() == .Number {
            error = store.maybeUpdateKeyGeneratorNumber(transactionIdentifier, objectStoreIdentifier, request.key.number())
        }

        revertsGeneratedKey = false
        reportPutOrAdd(ofTransaction: request.serial, requestIdentifier, error, request.key)
    }

    func getRecord(
        _ requestData: WebCore.IDBRequestData,
        _ data: WebCore.IDBGetRecordData,
        callback: @escaping IDBGetResultCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database else {
                    return callback(Self.idbError(.InvalidStateError, "Database is closed"), WebCore.IDBGetResult())
                }

                self.getRecord(requestData, data, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError), WebCore.IDBGetResult())
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"), WebCore.IDBGetResult())
        }

        let transactionIdentifier = requestData.transactionIdentifier()
        let (error, result) =
            if let indexIdentifier = requestData.indexIdentifier().value {
                store.getIndexRecord(
                    transactionIdentifier,
                    requestData.objectStoreIdentifier(),
                    indexIdentifier,
                    requestData.indexRecordType(),
                    data.keyRangeData
                )
            } else {
                store.getRecord(transactionIdentifier, requestData.objectStoreIdentifier(), data.keyRangeData, data.type)
            }

        callback(error, result)
    }

    func getAllRecords(
        _ requestData: WebCore.IDBRequestData,
        _ data: WebCore.IDBGetAllRecordsData,
        callback: @escaping IDBGetAllResultsCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database else {
                    return callback(Self.idbError(.InvalidStateError, "Database is closed"), WebCore.IDBGetAllResult())
                }

                self.getAllRecords(requestData, data, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError), WebCore.IDBGetAllResult())
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"), WebCore.IDBGetAllResult())
        }

        let (error, result) = store.getAllRecords(requestData.transactionIdentifier(), data)

        callback(error, result)
    }

    func getCount(
        _ requestData: WebCore.IDBRequestData,
        _ range: WebCore.IDBKeyRangeData,
        callback: @escaping IDBCountCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database else {
                    return callback(Self.idbError(.InvalidStateError, "Database is closed"), 0)
                }

                self.getCount(requestData, range, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError), 0)
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"), 0)
        }

        let (error, count) = store.getCount(
            requestData.transactionIdentifier(),
            requestData.objectStoreIdentifier(),
            requestData.indexIdentifier().value,
            range
        )

        callback(error, count)
    }

    func deleteRecord(
        _ requestData: WebCore.IDBRequestData,
        _ range: WebCore.IDBKeyRangeData,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database else {
                    return callback(Self.idbError(.InvalidStateError, "Database is closed"))
                }

                self.deleteRecord(requestData, range, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"))
        }

        let error = store.deleteRange(requestData.transactionIdentifier(), requestData.objectStoreIdentifier(), range)

        callback(error)
    }

    func openCursor(
        _ requestData: WebCore.IDBRequestData,
        _ info: WebCore.IDBCursorInfo,
        callback: @escaping IDBGetResultCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"), WebCore.IDBGetResult())
                }

                self.openCursor(requestData, info, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError), WebCore.IDBGetResult())
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"), WebCore.IDBGetResult())
        }

        let (error, result) = store.openCursor(requestData.transactionIdentifier(), info)

        callback(error, result)
    }

    func iterateCursor(
        _ requestData: WebCore.IDBRequestData,
        _ data: WebCore.IDBIterateCursorData,
        callback: @escaping IDBGetResultCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"), WebCore.IDBGetResult())
                }

                self.iterateCursor(requestData, data, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError), WebCore.IDBGetResult())
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let store else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"), WebCore.IDBGetResult())
        }

        let (error, result) = store.iterateCursor(requestData.transactionIdentifier(), requestData.cursorIdentifier(), data)

        callback(error, result)
    }
}

extension UniqueIDBDatabase {
    func commitTransaction(
        serial: IDBEntitySerial,
        handledRequestResultsCount: UInt64,
        callback: @escaping IDBErrorCallback,
        spaceCheck: IDBSpaceCheckResult = .unknown
    ) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }

                self.commitTransaction(
                    serial: serial,
                    handledRequestResultsCount: handledRequestResultsCount,
                    callback: callback,
                    spaceCheck: spaceCheckResult(granted: granted)
                )
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let transaction = transactions[serial] else {
            return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
        }

        if transaction.shouldAbortDueToUnhandledRequestError(handledRequestResultsCount: handledRequestResultsCount) {
            abortTransaction(
                serial: serial,
                callback: { error in
                    if !error.isNull() {
                        return callback(error)
                    }

                    callback(Self.idbError(.UnknownError, "Transaction is aborted due to unhandled failed request"))
                },
                spaceCheck: spaceCheck
            )
            return
        }

        guard let store else {
            return callback(Self.idbError(.InvalidStateError, "Backing store is closed"))
        }

        let transactionIdentifier = transaction.identifier
        guard let takenSerial = inProgressTransactions.removeValue(forKey: transactionIdentifier) else {
            // The transaction may have been aborted and completed on the server while its client
            // process was suspended; fail the commit with that abort result.
            if let existingAbortResult = transaction.suspensionAbortResult {
                return callback(
                    existingAbortResult.isNull()
                        ? Self.idbError(.UnknownError, "Transaction was aborted while its process was suspended")
                        : existingAbortResult
                )
            }

            if !isOpenConnection(transaction.databaseConnection) {
                return
            }

            callback(Self.idbError(.UnknownError, "Attempt to commit transaction that is not running"))
            return
        }

        let error = store.commitTransaction(transactionIdentifier)

        callback(error)
        completeTakenTransaction(takenSerial)
    }

    func abortTransaction(serial: IDBEntitySerial, callback: @escaping IDBErrorCallback, spaceCheck: IDBSpaceCheckResult = .unknown) {
        if spaceCheck == .unknown {
            let requested = requestSpace(0) { [reference = self.reference] granted in
                guard let self = reference.database, self.transactions.keys.contains(serial) else {
                    return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
                }

                self.abortTransaction(serial: serial, callback: callback, spaceCheck: spaceCheckResult(granted: granted))
            }
            if !requested {
                callback(Self.idbError(.InvalidStateError))
            }
            return
        }

        assert(spaceCheck == .pass)
        guard let transaction = transactions[serial] else {
            return callback(Self.idbError(.InvalidStateError, "Database or transaction is closed"))
        }

        let transactionIdentifier = transaction.identifier
        guard let takenSerial = inProgressTransactions.removeValue(forKey: transactionIdentifier) else {
            // The transaction may have been aborted and completed on the server while its client
            // process was suspended; tell the client about that abort now.
            if let existingAbortResult = transaction.suspensionAbortResult {
                return callback(existingAbortResult)
            }

            guard isOpenConnection(transaction.databaseConnection) else {
                return
            }

            callback(Self.idbError(.UnknownError, "Attempt to abort transaction that is not running"))
            return
        }

        // If transaction is already aborted for suspension, return the result of that abort.
        if let existingAbortResult = transactions[takenSerial]?.suspensionAbortResult {
            callback(existingAbortResult)
            completeTakenTransaction(takenSerial)
            return
        }

        if let versionChangeSerial = versionChangeTransaction,
            let versionChange = transactions[versionChangeSerial],
            versionChange.identifier == transactionIdentifier
        {
            guard let originalDatabaseInfo = versionChange.originalDatabaseInfo else {
                preconditionFailure()
            }
            databaseInfo = originalDatabaseInfo
        }

        let error = store?.abortTransaction(transactionIdentifier) ?? Self.idbError(.InvalidStateError, "Backing store is closed")

        callback(error)
        completeTakenTransaction(takenSerial)
    }

    /// Completes a transaction taken out of the in-progress ones, then drops that reference to it.
    private func completeTakenTransaction(_ serial: IDBEntitySerial) {
        transactionCompleted(serial: serial)
        release(transaction: serial, from: .inProgress)
    }
}
