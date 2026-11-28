//
// Copyright (C) 2015-2021 Apple Inc. All rights reserved.
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

// Everything one memory database holds: its info, object stores, transactions and cursors.

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

/// Where an object store is: registered, or among a transaction's deleted object stores (still reached by its cursors).
enum MemoryIDBObjectStoreLocation {
    case live(Int)
    case deleted(transaction: Int, slot: Int)
}

/// Where an index is: registered in its registered object store, or unregistered (a deleted index among them) in a
/// registered object store or in one of a transaction's deleted object stores.
enum MemoryIDBIndexLocation {
    case live(objectStore: Int, index: Int)
    case unregistered(objectStore: Int, index: Int)
    case deleted(transaction: Int, objectStore: Int, index: Int)
}

/// Which object store holds an index an aborting transaction's changes name: a registered one, one of the transaction's
/// deleted object stores, or none (the index is among the transaction's detached indexes).
private enum MemoryIDBAbortingIndexOwner {
    case registered(Int)
    case deleted(Int)
    case detached(Int)

    var isDetached: Bool {
        if case .detached = self {
            return true
        }
        return false
    }
}

/// What an abort reads to order the restores of renamed indexes, found once: a restore changes only the restored
/// index's name and the added indexes it deletes, and each is kept up to date as it changes.
///
/// Names are compared by key: the position of the first renamed index with that original name.
private struct MemoryIDBIndexRestoreOrder {
    /// The renamed indexes still to restore, in the order first renamed, with their original names.
    private(set) var renamedIndexes: [(index: UInt64, name: WTF.String)]
    private var pendingIndexes: Set<UInt64>
    /// The renamed indexes still to restore, by the key of their original name.
    private var pendingCounts: [Int: Int] = [:]
    /// The key of each renamed index's original name.
    private var nameKeys: [UInt64: Int] = [:]
    /// Where each renamed index is and its identifier, for those an object store or the detached indexes hold.
    let owners: [UInt64: (owner: MemoryIDBAbortingIndexOwner, identifier: UInt64)]
    /// The added indexes an object store or the detached indexes hold, in the order added, with the key of their name
    /// (nil where it is no renamed index's original name).
    private var addedIndexes: [(index: UInt64, owner: MemoryIDBAbortingIndexOwner, identifier: UInt64, nameKey: Int?)] = []
    /// The positions in `addedIndexes` of those the transaction still adds.
    private var addedSlots: [UInt64: Int] = [:]
    /// The positions in `addedIndexes` of those the transaction still adds, ascending, by the key of their name.
    private var addedSlotsByName: [Int: [Int]] = [:]

    init(
        _ renamedIndexes: [(index: UInt64, name: WTF.String)],
        _ owners: [UInt64: (owner: MemoryIDBAbortingIndexOwner, identifier: UInt64)],
        _ addedIndexes: [(index: UInt64, owner: MemoryIDBAbortingIndexOwner, identifier: UInt64, name: WTF.String)]
    ) {
        self.renamedIndexes = renamedIndexes
        pendingIndexes = Set(renamedIndexes.map { $0.index })
        self.owners = owners
        for (k, renamed) in renamedIndexes.enumerated() {
            let key = renamedIndexes.firstIndex { WebCore.idbStringEqual($0.name, renamed.name) } ?? k
            nameKeys[renamed.index] = key
            pendingCounts[key, default: 0] += 1
        }
        for added in addedIndexes {
            let key = renamedIndexes.firstIndex { WebCore.idbStringEqual($0.name, added.name) }
            if let key {
                addedSlotsByName[key, default: []].append(self.addedIndexes.count)
            }
            addedSlots[added.index] = self.addedIndexes.count
            self.addedIndexes.append((index: added.index, owner: added.owner, identifier: added.identifier, nameKey: key))
        }
    }

    func isPending(_ index: UInt64?) -> Bool {
        index.map { pendingIndexes.contains($0) } ?? false
    }

    /// The index the abort deletes before giving `index` its original name back: the last added index with that name
    /// and another identifier, unless its object store was dropped (then none is).
    func indexToDelete(restoring index: UInt64) -> (index: UInt64, owner: MemoryIDBAbortingIndexOwner, identifier: UInt64)? {
        guard let identifier = owners[index]?.identifier, let key = nameKeys[index] else {
            return nil
        }
        for slot in addedSlotsByName[key, default: []].reversed() where addedIndexes[slot].identifier != identifier {
            let added = addedIndexes[slot]
            return added.owner.isDetached ? nil : (index: added.index, owner: added.owner, identifier: added.identifier)
        }
        return nil
    }

    /// Whether `index` is an added index and another renamed index still to restore has the same original name.
    func sharesOriginalName(_ index: UInt64) -> Bool {
        guard addedSlots[index] != nil, let key = nameKeys[index] else {
            return false
        }
        return pendingCounts[key, default: 0] > 1
    }

    mutating func takeRenamedIndex(at position: Int) -> (index: UInt64, name: WTF.String) {
        let renamed = renamedIndexes.remove(at: position)
        pendingIndexes.remove(renamed.index)
        if let key = nameKeys[renamed.index] {
            pendingCounts[key, default: 0] -= 1
        }
        return renamed
    }

    mutating func indexDeleted(_ index: UInt64) {
        guard let slot = addedSlots.removeValue(forKey: index) else {
            return
        }
        removeName(at: slot)
    }

    mutating func originalNameRestored(_ index: UInt64) {
        guard let slot = addedSlots[index], let key = nameKeys[index] else {
            return
        }
        removeName(at: slot)
        addedIndexes[slot].nameKey = key
        let position = addedSlotsByName[key, default: []].firstIndex { $0 > slot } ?? addedSlotsByName[key, default: []].count
        addedSlotsByName[key, default: []].insert(slot, at: position)
    }

    private mutating func removeName(at slot: Int) {
        if let key = addedIndexes[slot].nameKey {
            addedSlotsByName[key]?.removeAll { $0 == slot }
        }
        addedIndexes[slot].nameKey = nil
    }
}

struct MemoryIDBDatabaseState: ~Copyable {
    let databaseName: WTF.String
    /// Not Optional: unwrapping a C++ optional copies the info.
    var databaseInfo = WebCore.IDBDatabaseInfo()
    var hasDatabaseInfo = false
    var transactions = UniqueArray<MemoryIDBTransactionState>()
    /// The transactions' identifiers, in the same order: a lookup scans values, touching no transaction.
    var transactionIdentifiers: ContiguousArray<WebCore.IDBResourceIdentifier> = []
    /// Where the last lookup found its transaction, checked first: consecutive calls name the same one.
    var lastTransactionIndex = 0
    var objectStores = UniqueArray<MemoryIDBObjectStoreState>()
    /// The object stores by name, by identifier: a rename onto a taken name replaces the store under it,
    /// and taking a store out takes whichever store is under its name.
    var objectStoreNames: [(name: WTF.String, objectStore: UInt64)] = []
    var cursors = UniqueArray<MemoryIDBCursorEntry>()
    /// The result of the last openCursorError that succeeded, taken once by SwiftIDBBackingStore.
    var openedCursorResult = WebCore.makeEmptyIDBGetResult()
    /// The error of the last iterateCursor call, read once by SwiftIDBBackingStore after it.
    var iterateCursorError = WebCore.MemoryIDBStoreError.None

    /// Counts the object stores and indexes created; each starts its generations at the count times 2^32, so two
    /// containers' generations meet only after 2^32 mutations.
    var generationSeed: UInt64 = 0

    init(_ databaseName: WTF.String) {
        self.databaseName = databaseName
    }

    mutating func nextGenerationSeed() -> UInt64 {
        generationSeed &+= 1
        return generationSeed << 32
    }

    mutating func transactionIndex(_ identifier: WebCore.IDBResourceIdentifier) -> Int? {
        let last = lastTransactionIndex
        // Not `&&`: its right side is an autoclosure, which cannot capture a borrowed parameter.
        if last < transactionIdentifiers.count {
            if WebCore.idbResourceIdentifierEqual(transactionIdentifiers[last], identifier) {
                return last
            }
        }
        for i in transactionIdentifiers.indices where WebCore.idbResourceIdentifierEqual(transactionIdentifiers[i], identifier) {
            lastTransactionIndex = i
            return i
        }
        return nil
    }

    func objectStoreSlot(_ identifier: UInt64) -> Int? {
        for i in 0..<objectStores.count where objectStores[i].identifier == identifier {
            return i
        }
        return nil
    }

    /// The object store registered under `name`.
    func objectStoreSlot(named name: WTF.String) -> Int? {
        for entry in objectStoreNames where WebCore.idbStringEqual(entry.name, name) {
            return objectStoreSlot(entry.objectStore)
        }
        return nil
    }

    /// Removes the object store name `name`.
    mutating func takeObjectStoreName(_ name: WTF.String) {
        for i in objectStoreNames.indices where WebCore.idbStringEqual(objectStoreNames[i].name, name) {
            objectStoreNames.remove(at: i)
            return
        }
    }

    /// Registers `objectStore` under `name`, replacing an entry of that name.
    mutating func setObjectStoreName(_ name: WTF.String, _ objectStore: UInt64) {
        for i in objectStoreNames.indices where WebCore.idbStringEqual(objectStoreNames[i].name, name) {
            objectStoreNames[i].objectStore = objectStore
            return
        }
        objectStoreNames.append((name: name, objectStore: objectStore))
    }

    func objectStoreLocation(_ identifier: UInt64) -> MemoryIDBObjectStoreLocation? {
        if let slot = objectStoreSlot(identifier) {
            return .live(slot)
        }
        for t in 0..<transactions.count {
            for k in 0..<transactions[t].deletedObjectStores.count where transactions[t].deletedObjectStores[k].identifier == identifier {
                return .deleted(transaction: t, slot: k)
            }
        }
        return nil
    }

    func indexLocation(_ objectStoreIdentifier: UInt64, _ indexIdentifier: UInt64) -> MemoryIDBIndexLocation? {
        if let s = objectStoreSlot(objectStoreIdentifier) {
            if let x = objectStores[s].indexSlot(indexIdentifier) {
                return .live(objectStore: s, index: x)
            }
            if let x = objectStores[s].unregisteredIndexSlot(identifier: indexIdentifier) {
                return .unregistered(objectStore: s, index: x)
            }
        }
        for t in 0..<transactions.count {
            for k in 0..<transactions[t].deletedObjectStores.count {
                if transactions[t].deletedObjectStores[k].identifier != objectStoreIdentifier {
                    continue
                }
                if let x = transactions[t].deletedObjectStores[k].unregisteredIndexSlot(identifier: indexIdentifier) {
                    return .deleted(transaction: t, objectStore: k, index: x)
                }
            }
        }
        return nil
    }

    private func indexOwner(serial: UInt64, _ transaction: borrowing MemoryIDBTransactionState) -> MemoryIDBAbortingIndexOwner? {
        for s in 0..<objectStores.count where objectStores[s].holdsIndex(serial: serial) {
            return .registered(s)
        }
        for k in 0..<transaction.deletedObjectStores.count where transaction.deletedObjectStores[k].holdsIndex(serial: serial) {
            return .deleted(k)
        }
        for k in 0..<transaction.detachedIndexes.count where transaction.detachedIndexes[k].serial == serial {
            return .detached(k)
        }
        return nil
    }

    private func indexInfo(
        _ owner: MemoryIDBAbortingIndexOwner,
        serial: UInt64,
        _ transaction: borrowing MemoryIDBTransactionState
    ) -> WebCore.IDBIndexInfo {
        switch owner {
        case .registered(let s):
            return objectStores[s].indexInfo(serial: serial)
        case .deleted(let k):
            return transaction.deletedObjectStores[k].indexInfo(serial: serial)
        case .detached(let k):
            return transaction.detachedIndexes[k].info
        }
    }

    // MARK: Database info

    mutating func establishDatabaseInfo() -> WebCore.IDBDatabaseInfo {
        if hasDatabaseInfo {
            return databaseInfo
        }
        let info = WebCore.makeMemoryIDBDatabaseInfo(databaseName)
        databaseInfo = info
        hasDatabaseInfo = true
        return info
    }

    mutating func hasObjectStoreInfo(_ identifier: WebCore.IDBObjectStoreIdentifier) -> Bool {
        guard hasDatabaseInfo else {
            return false
        }
        return WebCore.idbDatabaseInfoHasObjectStore(&databaseInfo, identifier)
    }

    // MARK: Transactions

    mutating func beginTransaction(
        _ identifier: WebCore.IDBResourceIdentifier,
        _ isVersionChange: Bool,
        _ isWriting: Bool,
        _ names: [WTF.String]
    ) -> WebCore.MemoryIDBStoreError {
        if transactionIndex(identifier) != nil {
            return .TransactionExists
        }
        var transaction = MemoryIDBTransactionState(identifier, isVersionChange, isWriting)
        if transaction.isVersionChange {
            transaction.originalDatabaseInfo = establishDatabaseInfo()
        }
        // A version change transaction covers every object store.
        if transaction.isVersionChange {
            for s in 0..<objectStores.count {
                transaction.objectStores.append(objectStores[s].identifier)
                objectStores[s].writeTransactionStarted(transaction.identifier)
            }
        } else if transaction.isWriting {
            // The stores of the name table whose name the transaction names.
            for entry in objectStoreNames where names.contains(where: { WebCore.idbStringEqual($0, entry.name) }) {
                if let s = objectStoreSlot(entry.objectStore) {
                    transaction.objectStores.append(objectStores[s].identifier)
                    objectStores[s].writeTransactionStarted(transaction.identifier)
                }
            }
        } else {
            transaction.objectStoreNames = names
        }
        transactionIdentifiers.append(transaction.identifier)
        transactions.append(transaction)
        return .None
    }

    mutating func abortTransaction(_ identifier: WebCore.IDBResourceIdentifier) -> WebCore.MemoryIDBStoreError {
        guard let t = transactionIndex(identifier) else {
            return .AbortUnknownTransaction
        }
        transactionIdentifiers.remove(at: t)
        let transaction = transactions.remove(at: t)
        abort(transaction)
        return .None
    }

    mutating func commitTransaction(_ identifier: WebCore.IDBResourceIdentifier) -> WebCore.MemoryIDBStoreError {
        guard let t = transactionIndex(identifier) else {
            return .CommitUnknownTransaction
        }
        transactionIdentifiers.remove(at: t)
        let transaction = transactions.remove(at: t)
        finish(transaction)
        return .None
    }

    private mutating func abort(_ abortingTransaction: consuming MemoryIDBTransactionState) {
        var transaction = abortingTransaction
        let identifier = transaction.identifier

        // Restore renamed indexes, last renamed first, except that a renamed index waits for one still to restore that
        // holds its original name (nextRenamedIndex). Where every one left waits, the last renamed goes.
        var order = restoreOrder(transaction)
        while !order.renamedIndexes.isEmpty {
            let (serial, originalName) = order.takeRenamedIndex(at: nextRenamedIndex(order, transaction))
            // Every index the transaction's changes name is held, by an object store or among the detached indexes.
            guard let owner = order.owners[serial]?.owner else {
                WTFCrash()
            }
            if let added = order.indexToDelete(restoring: serial) {
                switch added.owner {
                case .registered(let s):
                    if let deleted = objectStores[s].deleteIndex(identifier, added.identifier) {
                        transaction.indexDeleted(deleted)
                        order.indexDeleted(deleted)
                    }
                case .deleted(let k):
                    if let deleted = transaction.deletedObjectStores[k].deleteIndex(identifier, added.identifier) {
                        transaction.indexDeleted(deleted)
                        order.indexDeleted(deleted)
                    }
                case .detached:
                    break
                }
            }
            // Traps where no index is registered under its identifier or no entry holds that one's name: there is no
            // index to register under the original name.
            switch owner {
            case .registered(let s):
                if !objectStores[s].restoreIndexName(serial: serial, originalName) {
                    WTFCrash()
                }
                order.originalNameRestored(serial)
            case .deleted(let k):
                if !transaction.deletedObjectStores[k].restoreIndexName(serial: serial, originalName) {
                    WTFCrash()
                }
                order.originalNameRestored(serial)
            case .detached:
                break
            }
        }
        transaction.originalIndexNames = []

        // Restore renamed object stores.
        for (objectStoreIdentifier, oldName) in transaction.originalObjectStoreNames {
            guard let s = objectStoreSlot(objectStoreIdentifier) else {
                continue
            }
            if hasDatabaseInfo {
                databaseInfo.renameObjectStore(objectStores[s].info.identifier(), oldName)
            }
            takeObjectStoreName(objectStores[s].info.copiedName)
            setObjectStoreName(oldName, objectStoreIdentifier)
            objectStores[s].rename(oldName)
        }
        transaction.originalObjectStoreNames = []

        // Remove added object stores, with their cursors and the deleted indexes that were theirs (not those of a
        // deleted store with the same identifier, which are restored with it below).
        for objectStoreIdentifier in transaction.versionChangeAddedObjectStores {
            if let s = objectStoreSlot(objectStoreIdentifier) {
                takeObjectStoreName(objectStores[s].info.copiedName)
                _ = objectStores.remove(at: s)
                memoryIDBRemoveCursors(&cursors, objectStore: objectStoreIdentifier)
            }
        }
        // The deleted indexes those stores held went with them.
        var k = 0
        while k < transaction.deletedIndexes.count {
            if indexOwner(serial: transaction.deletedIndexes[k], transaction) == nil {
                transaction.deletedIndexes.remove(at: k)
            } else {
                k += 1
            }
        }
        transaction.versionChangeAddedObjectStores = []

        // Restore deleted object stores.
        while !transaction.deletedObjectStores.isEmpty {
            let objectStore = transaction.deletedObjectStores.remove(at: 0)
            transaction.objectStores.append(objectStore.identifier)
            registerObjectStore(objectStore)
        }

        // Restore the database info.
        if let originalDatabaseInfo = transaction.originalDatabaseInfo {
            databaseInfo = originalDatabaseInfo
            hasDatabaseInfo = true
        }

        for serial in transaction.deletedIndexes.reversed() {
            guard let owner = indexOwner(serial: serial, transaction) else {
                WTFCrash()
            }
            // Traps where no object store is registered under its object store's identifier, or its own object store
            // was dropped: there is no store to restore it to.
            let objectStoreIdentifier = indexInfo(owner, serial: serial, transaction).objectStoreIdentifier().toUInt64()
            guard objectStoreSlot(objectStoreIdentifier) != nil, case .registered(let s) = owner else {
                WTFCrash()
            }
            objectStores[s].maybeRestoreDeletedIndex(serial: serial)
        }
        transaction.deletedIndexes = []

        // Restore object store records.
        for objectStoreIdentifier in transaction.objectStores {
            if let s = objectStoreSlot(objectStoreIdentifier) {
                objectStores[s].transactionAborted(identifier, &cursors)
            }
        }
        finish(transaction)
    }

    private func restoreOrder(_ transaction: borrowing MemoryIDBTransactionState) -> MemoryIDBIndexRestoreOrder {
        var owners: [UInt64: (owner: MemoryIDBAbortingIndexOwner, identifier: UInt64)] = [:]
        for (serial, _) in transaction.originalIndexNames {
            if let owner = indexOwner(serial: serial, transaction) {
                owners[serial] = (owner: owner, identifier: indexInfo(owner, serial: serial, transaction).identifier().toUInt64())
            }
        }
        var addedIndexes: [(index: UInt64, owner: MemoryIDBAbortingIndexOwner, identifier: UInt64, name: WTF.String)] = []
        for serial in transaction.indexes {
            if let owner = indexOwner(serial: serial, transaction) {
                let info = indexInfo(owner, serial: serial, transaction)
                addedIndexes.append((index: serial, owner: owner, identifier: info.identifier().toUInt64(), name: info.copiedName))
            }
        }
        return MemoryIDBIndexRestoreOrder(transaction.originalIndexNames, owners, addedIndexes)
    }

    /// The position in `order` of the renamed index to restore next: the last renamed one that does not wait, else the
    /// last renamed.
    ///
    /// A renamed index waits for one still to restore that holds its original name, since going first would leave that
    /// one no index to restore:
    /// - The other is the added index its restore deletes.
    /// - The other is the entry under that name in the same object store, and the waiting index is an added index that
    ///   another one's restore can delete (one with the same original name): the waiting index would be registered by
    ///   identifier only, and deleting it would take that entry.
    private func nextRenamedIndex(
        _ order: MemoryIDBIndexRestoreOrder,
        _ transaction: borrowing MemoryIDBTransactionState
    ) -> Int {
        for k in order.renamedIndexes.indices.reversed() {
            let (serial, originalName) = order.renamedIndexes[k]
            if order.isPending(order.indexToDelete(restoring: serial)?.index) {
                continue
            }
            if order.sharesOriginalName(serial),
                order.isPending(indexNamed(originalName, besides: serial, in: order.owners[serial]?.owner, transaction))
            {
                continue
            }
            return k
        }
        return order.renamedIndexes.count - 1
    }

    /// The index other than `serial` that the entry under `name` holds in the object store holding `serial` (`owner`).
    private func indexNamed(
        _ name: WTF.String,
        besides serial: UInt64,
        in owner: MemoryIDBAbortingIndexOwner?,
        _ transaction: borrowing MemoryIDBTransactionState
    ) -> UInt64? {
        let entry: UInt64?
        switch owner {
        case .registered(let s):
            entry = objectStores[s].indexesByName.first { WebCore.idbStringEqual($0.name, name) }?.index
        case .deleted(let k):
            entry = transaction.deletedObjectStores[k].indexesByName.first { WebCore.idbStringEqual($0.name, name) }?.index
        case .detached, nil:
            entry = nil
        }
        return entry == serial ? nil : entry
    }

    private mutating func finish(_ transaction: consuming MemoryIDBTransactionState) {
        let identifier = transaction.identifier
        // A read-only transaction does not track its object stores: the cursors that end are those of the stores the
        // name table gives for its names, and of their registered indexes. Any other is left behind, reached by no transaction.
        if transaction.isWriting {
            for objectStoreIdentifier in transaction.objectStores {
                if let s = objectStoreSlot(objectStoreIdentifier) {
                    objectStores[s].writeTransactionFinished()
                }
            }
        } else {
            for name in transaction.objectStoreNames {
                guard let s = objectStoreSlot(named: name) else {
                    continue
                }
                var i = 0
                while i < cursors.count {
                    var ends = false
                    if !cursors[i].isFinished, cursors[i].objectStoreIdentifier == objectStores[s].identifier {
                        ends = true
                        if cursors[i].isIndexCursor {
                            ends = objectStores[s].indexSlot(cursors[i].indexIdentifier) != nil
                        }
                    }
                    if ends, WebCore.idbResourceIdentifierEqual(cursors[i].transactionIdentifier, identifier) {
                        _ = cursors.remove(at: i)
                    } else {
                        i += 1
                    }
                }
            }
        }
        var i = 0
        while i < cursors.count {
            if !cursors[i].isFinished, WebCore.idbResourceIdentifierEqual(cursors[i].transactionIdentifier, identifier) {
                if transaction.isWriting {
                    _ = cursors.remove(at: i)
                    continue
                }
                cursors[i].isFinished = true
            }
            i += 1
        }
        // The transaction's deleted object stores and indexes (those not restored) end here, with the cursors on them.
        for k in 0..<transaction.deletedObjectStores.count {
            memoryIDBRemoveCursors(&cursors, objectStore: transaction.deletedObjectStores[k].identifier)
        }
        // The indexes only the transaction's changes reached end here too.
        if transaction.isVersionChange {
            for s in 0..<objectStores.count {
                objectStores[s].dropUnreachedIndexes([], &cursors)
            }
        }
    }

    // MARK: Schema

    mutating func createObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ info: WebCore.IDBObjectStoreInfo
    ) -> WebCore.MemoryIDBStoreError {
        if !hasDatabaseInfo {
            WTFCrash()
        }
        if WebCore.idbDatabaseInfoHasObjectStoreNamed(&databaseInfo, WebCore.idbObjectStoreInfoName(info)) {
            return .Constraint
        }
        var objectStore = MemoryIDBObjectStoreState(info, generation: nextGenerationSeed())
        databaseInfo.addExistingObjectStore(info)
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            WTFCrash()
        }
        transactions[t].versionChangeAddedObjectStores.append(objectStore.identifier)
        transactions[t].objectStores.append(objectStore.identifier)
        objectStore.writeTransactionStarted(transactions[t].identifier)
        registerObjectStore(objectStore)
        return .None
    }

    mutating func deleteObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.MemoryIDBStoreError {
        if !hasObjectStoreInfo(copy objectStoreIdentifier) {
            return .Constraint
        }
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            WTFCrash()
        }
        let identifier = objectStoreIdentifier.toUInt64()
        guard let s = objectStoreSlot(identifier) else {
            return .Constraint
        }
        var objectStore = objectStores.remove(at: s)
        takeObjectStoreName(objectStore.info.copiedName)
        databaseInfo.deleteObjectStore(objectStore.info.copiedName)

        transactions[t].objectStores.removeAll { $0 == identifier }
        transactions[t].originalObjectStoreNames.removeAll { $0.objectStore == identifier }
        // Every index `indexesByName` holds is deleted, in its order.
        let named = objectStore.indexesByName.map { $0.index }
        for entry in named {
            // Traps on a null entry, which names no index.
            guard let serial = entry else {
                WTFCrash()
            }
            let indexIdentifier = objectStore.indexInfo(serial: serial).identifier().toUInt64()
            if let deleted = objectStore.deleteIndex(transactions[t].identifier, indexIdentifier) {
                transactions[t].indexDeleted(deleted)
            }
        }
        // A store the transaction added, or a second one deleted under a name already in `deletedObjectStores`, is not
        // restored on abort: it is dropped with its cursors, keeping only the indexes the transaction's changes still name.
        // The deleted indexes dropped with an added store are those of every store under its identifier, so a deleted
        // store that took the same identifier loses its deleted indexes too. The C++ (objectStoreDeleted) reads each deleted
        // index's store to compare identifiers and crashes on one it has freed (a second store deleted under one name); Swift
        // reads the identifier from the index's info, so such an index is dropped or kept like any other.
        if let position = transactions[t].versionChangeAddedObjectStores.firstIndex(of: identifier) {
            transactions[t].versionChangeAddedObjectStores.remove(at: position)
            var dropped: [UInt64] = []
            for serial in transactions[t].deletedIndexes {
                if objectStore.holdsIndex(serial: serial) {
                    dropped.append(serial)
                } else if let owner = indexOwner(serial: serial, transactions[t]),
                    indexInfo(owner, serial: serial, transactions[t]).objectStoreIdentifier().toUInt64() == identifier
                {
                    dropped.append(serial)
                }
            }
            transactions[t].deletedIndexes.removeAll { dropped.contains($0) }
            transactions[t].detachIndexes(&objectStore)
            memoryIDBRemoveCursors(&cursors, objectStore: identifier)
            return .None
        }
        if transactions[t].hasDeletedObjectStore(named: objectStore.info.copiedName) {
            transactions[t].detachIndexes(&objectStore)
            memoryIDBRemoveCursors(&cursors, objectStore: identifier)
            return .None
        }
        transactions[t].deletedObjectStores.append(objectStore)
        return .None
    }

    mutating func renameObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ newName: WTF.String
    ) -> WebCore.MemoryIDBStoreError {
        if !hasObjectStoreInfo(copy objectStoreIdentifier) {
            return .Constraint
        }
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            WTFCrash()
        }
        guard let s = objectStoreSlot(objectStoreIdentifier.toUInt64()) else {
            return .Constraint
        }
        let oldName = objectStores[s].info.copiedName
        objectStores[s].rename(newName)
        transactions[t].objectStoreRenamed(objectStores[s].identifier, oldName)
        takeObjectStoreName(oldName)
        setObjectStoreName(newName, objectStores[s].identifier)
        databaseInfo.renameObjectStore(objectStoreIdentifier, newName)
        return .None
    }

    mutating func clearObjectStore(_ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier) -> WebCore.MemoryIDBStoreError {
        guard let s = objectStoreSlot(objectStoreIdentifier.toUInt64()) else {
            return .Constraint
        }
        objectStores[s].clear(&cursors)
        return .None
    }

    mutating func deleteIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier
    ) -> WebCore.MemoryIDBStoreError {
        if !hasDatabaseInfo {
            WTFCrash()
        }
        if !hasObjectStoreInfo(copy objectStoreIdentifier)
            || !WebCore.idbDatabaseInfoHasIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier)
        {
            return .Constraint
        }
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            WTFCrash()
        }
        guard let s = objectStoreSlot(objectStoreIdentifier.toUInt64()) else {
            return .Constraint
        }
        let deleted = objectStores[s].deleteIndex(transactions[t].identifier, indexIdentifier.toUInt64())
        if let deleted {
            transactions[t].indexDeleted(deleted)
        }
        objectStores[s].dropUnreachedIndexes(transactions[t].loggedIndexes, &cursors)
        if deleted == nil {
            return .Constraint
        }
        WebCore.idbDatabaseInfoDeleteIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier)
        return .None
    }

    mutating func renameIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        _ newName: WTF.String
    ) -> WebCore.MemoryIDBStoreError {
        if !hasDatabaseInfo {
            WTFCrash()
        }
        if !hasObjectStoreInfo(copy objectStoreIdentifier)
            || !WebCore.idbDatabaseInfoHasIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier)
        {
            return .Constraint
        }
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            WTFCrash()
        }
        guard let s = objectStoreSlot(objectStoreIdentifier.toUInt64()), let x = objectStores[s].indexSlot(indexIdentifier.toUInt64())
        else {
            return .Constraint
        }
        let oldName = objectStores[s].indexes[x].info.copiedName
        // Onto a name another index has in the database info. Traps: the web process guarantees unique names.
        if !WebCore.idbStringEqual(oldName, newName),
            WebCore.idbDatabaseInfoObjectStore(&databaseInfo, objectStoreIdentifier).hasIndex(newName)
        {
            WTFCrash()
        }
        objectStores[s].renameIndex(x, newName)
        transactions[t].indexRenamed(objectStores[s].indexes[x].serial, oldName)
        objectStores[s].dropUnreachedIndexes(transactions[t].loggedIndexes, &cursors)
        WebCore.idbDatabaseInfoRenameIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier, newName)
        return .None
    }

    mutating func addIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ indexInfo: WebCore.IDBIndexInfo
    ) -> WebCore.MemoryIDBStoreError {
        guard hasDatabaseInfo else {
            return .DatabaseInfoInvalid
        }
        let objectStoreIdentifier = indexInfo.objectStoreIdentifier()
        if !hasObjectStoreInfo(objectStoreIdentifier) {
            return .ObjectStoreNotInDatabaseInfo
        }
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            return .NotVersionChange
        }
        guard let s = objectStoreSlot(indexInfo.objectStoreIdentifier().toUInt64()) else {
            return .ObjectStoreNotInBackingStore
        }
        let isNameInUse = WebCore.idbDatabaseInfoObjectStore(&databaseInfo, objectStoreIdentifier).hasIndex(indexInfo.copiedName)
        let error = objectStores[s].addIndex(&transactions[t], indexInfo, isNameInUse: isNameInUse, generation: nextGenerationSeed())
        if error == .None {
            WebCore.idbDatabaseInfoAddIndex(&databaseInfo, indexInfo)
            databaseInfo.setMaxIndexID(indexInfo.identifier().toUInt64())
        }
        return error
    }

    mutating func revertAddIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier
    ) {
        if !hasDatabaseInfo {
            WTFCrash()
        }
        if !hasObjectStoreInfo(copy objectStoreIdentifier)
            || !WebCore.idbDatabaseInfoHasIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier)
        {
            return
        }
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            return
        }
        // The object store cannot be missing while its info exists.
        guard let s = objectStoreSlot(objectStoreIdentifier.toUInt64()) else {
            WTFCrash()
        }
        WebCore.idbDatabaseInfoDeleteIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier)
        objectStores[s].revertAddIndex(&transactions[t], indexIdentifier, &cursors)
    }

    mutating func updateIndexRecordsWithIndexKey(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ indexInfo: WebCore.IDBIndexInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKey: WebCore.IndexKey
    ) -> WebCore.MemoryIDBStoreError {
        guard let t = transactionIndex(transactionIdentifier), transactions[t].isVersionChange else {
            return .NotVersionChange
        }
        guard let s = objectStoreSlot(indexInfo.objectStoreIdentifier().toUInt64()) else {
            return .ObjectStoreNotInBackingStore
        }
        if indexKey.isNull() {
            return .None
        }
        return objectStores[s].updateIndexRecordsWithIndexKey(transactions[t], indexInfo, key, indexKey, &cursors)
    }

    private mutating func registerObjectStore(_ objectStore: consuming MemoryIDBObjectStoreState) {
        if objectStoreSlot(objectStore.identifier) != nil {
            WTFCrash()
        }
        if objectStoreSlot(named: objectStore.info.copiedName) != nil {
            WTFCrash()
        }
        setObjectStoreName(objectStore.info.copiedName, objectStore.identifier)
        objectStores.append(objectStore)
    }

    // MARK: Cursors

    func hasCursor(
        _ objectStoreIdentifier: UInt64,
        _ isIndexCursor: Bool,
        _ indexIdentifier: UInt64,
        _ identifier: WebCore.IDBResourceIdentifier
    ) -> Bool {
        for i in 0..<cursors.count where cursors[i].isIndexCursor == isIndexCursor {
            let sameSource =
                isIndexCursor ? cursors[i].indexIdentifier == indexIdentifier : cursors[i].objectStoreIdentifier == objectStoreIdentifier
            if sameSource {
                if WebCore.idbResourceIdentifierEqual(cursors[i].identifier, identifier) {
                    return true
                }
            }
        }
        return false
    }

    /// The transaction's cursor: the first opened with that identifier.
    func cursorSlot(_ transactionIdentifier: WebCore.IDBResourceIdentifier, _ identifier: WebCore.IDBResourceIdentifier) -> Int? {
        for i in 0..<cursors.count where !cursors[i].isFinished {
            if WebCore.idbResourceIdentifierEqual(cursors[i].identifier, identifier) {
                if WebCore.idbResourceIdentifierEqual(cursors[i].transactionIdentifier, transactionIdentifier) {
                    return i
                }
            }
        }
        return nil
    }

    mutating func openCursorError(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ info: WebCore.IDBCursorInfo
    ) -> WebCore.MemoryIDBStoreError {
        guard let t = transactionIndex(transactionIdentifier) else {
            return .NoTransactionToOpenCursor
        }
        let identifier = info.identifier()
        switch info.cursorSource() {
        case .ObjectStore:
            guard let s = objectStoreSlot(WebCore.idbCursorInfoSourceIdentifier(info)) else {
                return .NoObjectStore
            }
            if transactions[t].isWriting && !objectStores[s].isWriteTransaction(transactions[t].identifier) {
                return .CannotCreateObjectStoreCursor
            }
            let objectStoreIdentifier = objectStores[s].identifier
            if hasCursor(objectStoreIdentifier, false, 0, identifier) {
                return .CannotCreateObjectStoreCursor
            }
            objectStores[s].orderKeys()
            var state = MemoryIDBCursorState.objectStore(MemoryIDBObjectStoreCursor(info, objectStores[s]))
            openedCursorResult = state.currentData(&objectStores[s])
            cursors.append(
                MemoryIDBCursorEntry(
                    identifier: identifier,
                    transactionIdentifier: transactions[t].identifier,
                    objectStoreIdentifier: objectStoreIdentifier,
                    isIndexCursor: false,
                    indexIdentifier: 0,
                    state: state
                )
            )
        case .Index:
            guard let s = objectStoreSlot(info.objectStoreIdentifier().toUInt64()) else {
                return .NoObjectStore
            }
            guard let x = objectStores[s].indexSlot(WebCore.idbCursorInfoSourceIdentifier(info)) else {
                return .NoIndex
            }
            if transactions[t].isWriting && !objectStores[s].isWriteTransaction(transactions[t].identifier) {
                return .CannotCreateIndexCursor
            }
            let objectStoreIdentifier = objectStores[s].identifier
            let indexIdentifier = objectStores[s].indexes[x].identifier
            if hasCursor(objectStoreIdentifier, true, indexIdentifier, identifier) {
                return .CannotCreateIndexCursor
            }
            objectStores[s].orderIndexRecords(x)
            var state = MemoryIDBCursorState.index(MemoryIDBIndexCursor(info, objectStores[s].indexes[x]))
            openedCursorResult = state.currentData(&objectStores[s])
            cursors.append(
                MemoryIDBCursorEntry(
                    identifier: identifier,
                    transactionIdentifier: transactions[t].identifier,
                    objectStoreIdentifier: objectStoreIdentifier,
                    isIndexCursor: true,
                    indexIdentifier: indexIdentifier,
                    state: state
                )
            )
        @unknown default:
            WTFCrash()
        }
        return .None
    }

    mutating func iterateCursor(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ cursorIdentifier: WebCore.IDBResourceIdentifier,
        _ key: WebCore.IDBKeyData,
        _ primaryKey: WebCore.IDBKeyData,
        _ count: UInt32
    ) -> WebCore.IDBGetResult {
        if transactionIndex(transactionIdentifier) == nil {
            iterateCursorError = .NoTransactionToIterateCursor
            return WebCore.makeEmptyIDBGetResult()
        }
        guard let c = cursorSlot(transactionIdentifier, cursorIdentifier),
            let location = objectStoreLocation(cursors[c].objectStoreIdentifier)
        else {
            iterateCursorError = .NoCursorToIterate
            return WebCore.makeEmptyIDBGetResult()
        }
        iterateCursorError = .None
        if !cursors[c].isIndexCursor {
            switch location {
            case .live(let s):
                return cursors[c].state.iterateObjectStoreCursor(&objectStores[s], MemoryIDBKey(key), count)
            case .deleted(let t, let k):
                return cursors[c].state.iterateObjectStoreCursor(&transactions[t].deletedObjectStores[k], MemoryIDBKey(key), count)
            }
        }
        guard let indexLocation = indexLocation(cursors[c].objectStoreIdentifier, cursors[c].indexIdentifier) else {
            return WebCore.makeEmptyIDBGetResult()
        }
        let hasResult: Bool
        switch indexLocation {
        case .live(let s, let x):
            objectStores[s].orderIndexRecords(x)
            hasResult = cursors[c].state.iterateIndexCursor(objectStores[s].indexes[x], MemoryIDBKey(key), MemoryIDBKey(primaryKey), count)
        case .unregistered(let s, let x):
            objectStores[s].unregisteredIndexes[x].orderRecords()
            hasResult = cursors[c].state
                .iterateIndexCursor(objectStores[s].unregisteredIndexes[x], MemoryIDBKey(key), MemoryIDBKey(primaryKey), count)
        case .deleted(let t, let k, let x):
            transactions[t].deletedObjectStores[k].unregisteredIndexes[x].orderRecords()
            hasResult = cursors[c].state
                .iterateIndexCursor(
                    transactions[t].deletedObjectStores[k].unregisteredIndexes[x],
                    MemoryIDBKey(key),
                    MemoryIDBKey(primaryKey),
                    count
                )
        }
        if !hasResult {
            return WebCore.makeEmptyIDBGetResult()
        }
        switch location {
        case .live(let s):
            return cursors[c].state.currentData(&objectStores[s])
        case .deleted(let t, let k):
            return cursors[c].state.currentData(&transactions[t].deletedObjectStores[k])
        }
    }
}

// MARK: - Record entries on the state

extension MemoryIDBDatabaseState {
    mutating func recordError(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: UInt64,
        _ noTransaction: WebCore.MemoryIDBStoreError,
        _ noObjectStore: WebCore.MemoryIDBStoreError
    ) -> WebCore.MemoryIDBStoreError {
        if transactionIndex(transactionIdentifier) == nil {
            return noTransaction
        }
        if objectStoreSlot(objectStoreIdentifier) == nil {
            return noObjectStore
        }
        return .None
    }

    mutating func deleteRange(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: UInt64,
        _ range: WebCore.IDBKeyRangeData
    ) -> WebCore.MemoryIDBStoreError {
        if transactionIndex(transactionIdentifier) == nil {
            return .NoTransactionToDeleteFrom
        }
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            return .NoObjectStore
        }
        objectStores[s].deleteRange(range, &cursors)
        return .None
    }

    mutating func overwriteRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: UInt64,
        _ key: WebCore.IDBKeyData,
        _ indexKeys: WebCore.IDBIndexKeyMapEntries,
        _ value: WebCore.ThreadSafeDataBuffer
    ) -> WebCore.MemoryIDBStoreError {
        if transactionIndex(transactionIdentifier) == nil {
            return .NoTransactionToPutRecord
        }
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            return .NoObjectStoreToPutRecord
        }
        return objectStores[s].overwriteRecord(key, indexKeys, value, &cursors)
    }

    mutating func getRecord(_ objectStoreIdentifier: UInt64, _ range: WebCore.IDBKeyRangeData, _ keyAndValue: Bool) -> WebCore.IDBGetResult
    {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            return WebCore.makeEmptyIDBGetResult()
        }
        guard let (recordKey, rangeKeySlot) = objectStores[s].lowestRecordInRange(range) else {
            if !keyAndValue {
                return WebCore.makeIDBGetResultKey(WebCore.IDBKeyData())
            }
            return WebCore.makeIDBGetResultKeyValue(WebCore.IDBKeyData(), WebCore.ThreadSafeDataBuffer(), &objectStores[s].info)
        }
        // The table holds the record for an equal key.
        if let rangeKeySlot {
            if !keyAndValue {
                return WebCore.makeIDBGetResultKey(range.lowerKey)
            }
            return objectStores[s].getResultKeyValue(range.lowerKey, rangeKeySlot)
        }
        if !keyAndValue {
            return WebCore.makeIDBGetResultKey(recordKey.makeIDBKeyData())
        }
        guard let slot = objectStores[s].values.find(recordKey, recordKey.hash) else {
            let key = recordKey.makeIDBKeyData()
            return WebCore.makeIDBGetResultKeyValue(key, WebCore.ThreadSafeDataBuffer(), &objectStores[s].info)
        }
        return objectStores[s].getResultKeyValue(recordKey.makeIDBKeyData(), slot)
    }

    mutating func getAllRecordsError(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: UInt64,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64
    ) -> WebCore.MemoryIDBStoreError {
        if transactionIndex(transactionIdentifier) == nil {
            return .NoTransactionToGetAllRecords
        }
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            return .NoObjectStore
        }
        if hasIndex && objectStores[s].indexSlot(indexIdentifier) == nil {
            return .NoIndex
        }
        return .None
    }

    mutating func getAllRecords(
        _ objectStoreIdentifier: UInt64,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64,
        _ range: WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ type: WebCore.IndexedDB.GetAllType
    ) -> WebCore.IDBGetAllResult {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            WTFCrash()
        }
        if hasIndex {
            guard let x = objectStores[s].indexSlot(indexIdentifier) else {
                WTFCrash()
            }
            return objectStores[s].indexGetAllRecords(x, range, count, type)
        }
        return objectStores[s].getAllRecords(range, count, type)
    }

    mutating func getIndexRecord(
        _ objectStoreIdentifier: UInt64,
        _ indexIdentifier: UInt64,
        _ keyOnly: Bool,
        _ range: WebCore.IDBKeyRangeData
    ) -> WebCore.IDBGetResult {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            return WebCore.makeEmptyIDBGetResult()
        }
        // An unknown index is a caller bug: trap.
        guard let x = objectStores[s].indexSlot(indexIdentifier) else {
            WTFCrash()
        }
        return objectStores[s].indexGetRecord(x, keyOnly, range)
    }

    mutating func getCount(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: UInt64,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64,
        _ range: WebCore.IDBKeyRangeData,
        _ count: inout UInt64
    ) -> WebCore.MemoryIDBStoreError {
        if transactionIndex(transactionIdentifier) == nil {
            return .NoTransactionToGetCount
        }
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            return .NoObjectStore
        }
        count = objectStores[s].countForKeyRange(hasIndex ? indexIdentifier : nil, range)
        return .None
    }

    mutating func generateKeyNumber(_ objectStoreIdentifier: UInt64, _ keyNumber: inout UInt64) -> WebCore.MemoryIDBStoreError {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            WTFCrash()
        }
        keyNumber = objectStores[s].keyGeneratorValue
        if keyNumber > MemoryIDBObjectStoreState.maxGeneratedKeyValue {
            return .KeyGeneratorOverflow
        }
        objectStores[s].keyGeneratorValue = keyNumber + 1
        return .None
    }

    mutating func revertGeneratedKeyNumber(_ objectStoreIdentifier: UInt64, _ keyNumber: UInt64) {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            WTFCrash()
        }
        objectStores[s].keyGeneratorValue = keyNumber
    }

    mutating func maybeUpdateKeyGeneratorNumber(_ objectStoreIdentifier: UInt64, _ newKeyNumber: Double) {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            WTFCrash()
        }
        if newKeyNumber < Double(objectStores[s].keyGeneratorValue) {
            return
        }
        if newKeyNumber >= Double(MemoryIDBObjectStoreState.maxGeneratedKeyValue) {
            objectStores[s].keyGeneratorValue = MemoryIDBObjectStoreState.maxGeneratedKeyValue + 1
            return
        }
        // Here 0 <= newKeyNumber < 2^53, or NaN, which converts to 0.
        let truncated: UInt64 = newKeyNumber.isNaN ? 0 : UInt64(newKeyNumber)
        objectStores[s].keyGeneratorValue = truncated + 1
    }

    mutating func objectStoreRecordKeys(_ objectStoreIdentifier: UInt64) -> WebCore.IDBKeyDataVector {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            WTFCrash()
        }
        objectStores[s].orderKeys()
        var result = WebCore.makeIDBKeyDataVector(objectStores[s].keys.count)
        for key in objectStores[s].keys.keys {
            WebCore.appendIDBKeyData(&result, key.makeIDBKeyData())
        }
        return result
    }

    mutating func objectStoreRecordValues(_ objectStoreIdentifier: UInt64) -> WebCore.ThreadSafeDataBufferVector {
        guard let s = objectStoreSlot(objectStoreIdentifier) else {
            WTFCrash()
        }
        objectStores[s].orderKeys()
        var result = WebCore.makeThreadSafeDataBufferVector(objectStores[s].keys.count)
        // In key order, each value read in place in the table.
        for key in objectStores[s].keys.keys {
            if let slot = objectStores[s].values.find(key, key.hash) {
                WebCore.appendThreadSafeDataBuffer(&result, objectStores[s].values.values[slot])
            }
        }
        return result
    }
}
