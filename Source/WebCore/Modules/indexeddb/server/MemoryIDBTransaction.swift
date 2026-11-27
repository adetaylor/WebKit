//
// Copyright (C) 2015 Apple Inc. All rights reserved.
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

// A transaction of the memory store and what it restores on abort.

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBGetAllResult
internal import WebCore_Private.Core.IDBGetResult
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IDBTransactionMode
internal import WebCore_Private.Core.IndexKey
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes
internal import WebCore_Private.Core.ThreadSafeDataBuffer

struct MemoryIDBTransactionState: ~Copyable {
    let identifier: WebCore.IDBResourceIdentifier
    let isVersionChange: Bool
    let isWriting: Bool
    var originalDatabaseInfo: WebCore.IDBDatabaseInfo?

    /// The object stores it writes, by identifier.
    var objectStores: ContiguousArray<UInt64> = []
    var versionChangeAddedObjectStores: ContiguousArray<UInt64> = []
    /// The indexes it added, by serial, each once.
    var indexes: ContiguousArray<UInt64> = []
    /// The indexes it deleted, by serial, each once: still held by their object stores (unregistered), to be put back if
    /// it aborts.
    var deletedIndexes: ContiguousArray<UInt64> = []
    /// Object stores it deleted, to restore on abort; a second one under a name already here is dropped.
    var deletedObjectStores = UniqueArray<MemoryIDBObjectStoreState>()
    /// The indexes of the object stores it dropped (deleteObjectStore) that its changes still name: an abort finds their
    /// names here, and restores none of them.
    var detachedIndexes = UniqueArray<MemoryIDBIndexState>()
    /// By serial: the name each renamed index had before its first rename in this transaction.
    var originalIndexNames: [(index: UInt64, name: WTF.String)] = []
    var originalObjectStoreNames: [(objectStore: UInt64, name: WTF.String)] = []
    /// A read-only transaction's object store names: its finish ends the cursors of the stores the name table gives.
    var objectStoreNames: [WTF.String] = []

    init(_ identifier: WebCore.IDBResourceIdentifier, _ isVersionChange: Bool, _ isWriting: Bool) {
        self.identifier = identifier
        self.isVersionChange = isVersionChange
        self.isWriting = isWriting
    }

    mutating func indexAdded(_ serial: UInt64) {
        if !indexes.contains(serial) {
            indexes.append(serial)
        }
    }

    mutating func indexDeleted(_ serial: UInt64) {
        indexes.removeAll { $0 == serial }
        if !deletedIndexes.contains(serial) {
            deletedIndexes.append(serial)
        }
    }

    /// The indexes `indexes`, `deletedIndexes` and `originalIndexNames` name.
    var loggedIndexes: [UInt64] {
        Array(indexes) + Array(deletedIndexes) + originalIndexNames.map { $0.index }
    }

    /// Keeps the indexes of an object store being dropped that `loggedIndexes` names, and drops the others.
    mutating func detachIndexes(_ objectStore: inout MemoryIDBObjectStoreState) {
        let logged = loggedIndexes
        while !objectStore.indexes.isEmpty {
            let index = objectStore.indexes.removeLast()
            if logged.contains(index.serial) {
                detachedIndexes.append(index)
            }
        }
        while !objectStore.unregisteredIndexes.isEmpty {
            let index = objectStore.unregisteredIndexes.removeLast()
            if logged.contains(index.serial) {
                detachedIndexes.append(index)
            }
        }
    }

    mutating func objectStoreRenamed(_ objectStoreIdentifier: UInt64, _ oldName: WTF.String) {
        // Only the first rename in a transaction matters: an abort goes back to the first old name.
        if !originalObjectStoreNames.contains(where: { $0.objectStore == objectStoreIdentifier }) {
            originalObjectStoreNames.append((objectStore: objectStoreIdentifier, name: oldName))
        }
    }

    mutating func indexRenamed(_ serial: UInt64, _ oldName: WTF.String) {
        if !originalIndexNames.contains(where: { $0.index == serial }) {
            originalIndexNames.append((index: serial, name: oldName))
        }
    }

    func hasDeletedObjectStore(named name: WTF.String) -> Bool {
        for i in 0..<deletedObjectStores.count where WebCore.idbStringEqual(deletedObjectStores[i].info.copiedName, name) {
            return true
        }
        return false
    }
}
