//
// Copyright (C) 2015 Apple Inc. All rights reserved.
// Copyright (C) 2015-2025 Apple Inc. All rights reserved.
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

// The memory store's cursors over an object store's records or an index's, and the cursors a database holds.

internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
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

/// The position of an object store cursor, keys only: `iteratorIndex` is used only while the store's generation is still
/// `iteratorGeneration`, else the iterator is re-found by its key.
struct MemoryIDBObjectStoreCursor {
    let range: MemoryIDBKeyRange
    let isForward: Bool
    let isKeyOnly: Bool
    var remainingRange: MemoryIDBKeyRange
    /// The iterator: the key of the record it designates (nil: not set), and where that record was at
    /// `iteratorGeneration`.
    var iterator: MemoryIDBKey?
    var iteratorIndex = 0
    var iteratorGeneration: UInt64 = 0
    /// The current position's key (nil: the null key).
    var currentPosition: MemoryIDBKey?

    init(_ info: WebCore.IDBCursorInfo, _ objectStore: borrowing MemoryIDBObjectStoreState) {
        range = MemoryIDBKeyRange(WebCore.idbCursorInfoRange(info))
        remainingRange = range
        isForward = info.isDirectionForward()
        isKeyOnly = info.cursorType() == .KeyOnly
        if objectStore.hasOrderedKeys {
            setFirstInRemainingRange(objectStore)
        }
    }

    var hasIterator: Bool {
        iterator != nil
    }

    private mutating func setIterator(_ objectStore: borrowing MemoryIDBObjectStoreState, _ index: Int) {
        iterator = objectStore.keys.key(index)
        iteratorIndex = index
        iteratorGeneration = objectStore.generation
    }

    /// The iterator's index in the store's keys now, re-found by its key if the store changed since.
    mutating func resolvedIterator(_ objectStore: borrowing MemoryIDBObjectStoreState) -> Int? {
        guard let iterator else {
            return nil
        }
        if iteratorGeneration != objectStore.generation {
            guard let index = memoryIDBFind(objectStore.keys, iterator) else {
                self.iterator = nil
                return nil
            }
            iteratorIndex = index
            iteratorGeneration = objectStore.generation
        }
        return iteratorIndex
    }

    mutating func keyDeleted(_ key: MemoryIDBKey) {
        guard let currentPosition, currentPosition == key else {
            return
        }
        iterator = nil
    }

    mutating func keyAdded(_ objectStore: borrowing MemoryIDBObjectStoreState, _ index: Int) {
        if hasIterator {
            return
        }
        guard let currentPosition else {
            return
        }
        if objectStore.keys.key(index) == currentPosition {
            setIterator(objectStore, index)
        }
    }

    private mutating func setFirstInRemainingRange(_ objectStore: borrowing MemoryIDBObjectStoreState) {
        iterator = nil
        if isForward {
            setForwardIteratorFromRemainingRange(objectStore)
            if let iterator {
                remainingRange.lowerKey = iterator
                remainingRange.lowerOpen = true
            }
        } else {
            setReverseIteratorFromRemainingRange(objectStore)
            if let iterator {
                remainingRange.upperKey = iterator
                remainingRange.upperOpen = true
            }
        }
    }

    private mutating func setForwardIteratorFromRemainingRange(_ objectStore: borrowing MemoryIDBObjectStoreState) {
        iterator = nil
        let keys = objectStore.keys
        if keys.isEmpty {
            return
        }
        if remainingRange.isExactlyOneKey {
            if let index = memoryIDBFind(keys, remainingRange.lowerKey) {
                setIterator(objectStore, index)
            }
            return
        }
        var lowest = memoryIDBLowerBound(keys, remainingRange.lowerKey)
        if lowest == keys.count {
            return
        }
        if remainingRange.lowerOpen && keys.key(lowest) == remainingRange.lowerKey {
            lowest += 1
            if lowest == keys.count {
                return
            }
        }
        if !remainingRange.upperKey.isNull {
            if keys.compare(lowest, remainingRange.upperKey) > 0 {
                return
            }
            if remainingRange.upperOpen && keys.key(lowest) == remainingRange.upperKey {
                return
            }
        }
        setIterator(objectStore, lowest)
    }

    private mutating func setReverseIteratorFromRemainingRange(_ objectStore: borrowing MemoryIDBObjectStoreState) {
        iterator = nil
        let keys = objectStore.keys
        if keys.isEmpty {
            return
        }
        if remainingRange.isExactlyOneKey {
            if let index = memoryIDBFind(keys, remainingRange.lowerKey) {
                setIterator(objectStore, index)
            }
            return
        }
        if !remainingRange.upperKey.isValid {
            let last = keys.count - 1
            if remainingRange.contains(keys.key(last)) {
                setIterator(objectStore, last)
            }
            return
        }
        // One record past the key looked for.
        var highest = memoryIDBUpperBound(keys, remainingRange.upperKey)
        if highest == 0 {
            return
        }
        // The one before it, which is the key looked for.
        highest -= 1
        if remainingRange.upperOpen && keys.key(highest) == remainingRange.upperKey {
            if highest == 0 {
                return
            }
            highest -= 1
        }
        if !remainingRange.lowerKey.isNull {
            if keys.compare(highest, remainingRange.lowerKey) < 0 {
                return
            }
            if remainingRange.lowerOpen && keys.key(highest) == remainingRange.lowerKey {
                return
            }
        }
        setIterator(objectStore, highest)
    }

    mutating func currentData(_ objectStore: inout MemoryIDBObjectStoreState) -> WebCore.IDBGetResult {
        objectStore.orderKeys()
        guard resolvedIterator(objectStore) != nil, let recordKey = iterator else {
            currentPosition = nil
            return WebCore.makeEmptyIDBGetResult()
        }
        currentPosition = recordKey
        let key = recordKey.makeIDBKeyData()
        if isKeyOnly {
            return WebCore.makeIDBCursorResultKeys(key, key)
        }
        return objectStore.cursorResult(key, key, recordKey)
    }

    private mutating func incrementForwardIterator(
        _ objectStore: borrowing MemoryIDBObjectStoreState,
        _ key: MemoryIDBKey,
        _ inputCount: UInt32
    ) {
        var count = inputCount
        // The iterator is re-found when the record it designated was deleted.
        var didResetIterator = false
        if resolvedIterator(objectStore) == nil {
            guard let currentPosition else {
                return
            }
            remainingRange.lowerKey = currentPosition
            remainingRange.lowerOpen = false
            setFirstInRemainingRange(objectStore)
            didResetIterator = true
        }
        guard var index = resolvedIterator(objectStore) else {
            return
        }
        if key.isValid {
            // Iterating to a key: the count is zero.
            if !range.contains(key) {
                return
            }
            if objectStore.keys.compare(index, key) < 0 {
                remainingRange.lowerKey = key
                remainingRange.lowerOpen = false
                setFirstInRemainingRange(objectStore)
            }
            return
        }
        if count == 0 {
            count = 1
        }
        // A re-found iterator may already be past the current position, which uses up one step.
        if didResetIterator, let currentPosition, objectStore.keys.compare(index, currentPosition) > 0 {
            count -= 1
        }
        while count > 0 {
            count -= 1
            index += 1
            if index == objectStore.keys.count || !range.contains(objectStore.keys.key(index)) {
                iterator = nil
                return
            }
            setIterator(objectStore, index)
        }
    }

    private mutating func incrementReverseIterator(
        _ objectStore: borrowing MemoryIDBObjectStoreState,
        _ key: MemoryIDBKey,
        _ inputCount: UInt32
    ) {
        var count = inputCount
        var didResetIterator = false
        if resolvedIterator(objectStore) == nil {
            guard let currentPosition else {
                return
            }
            remainingRange.upperKey = currentPosition
            remainingRange.upperOpen = false
            setFirstInRemainingRange(objectStore)
            didResetIterator = true
        }
        guard var index = resolvedIterator(objectStore) else {
            return
        }
        if key.isValid {
            if !range.contains(key) {
                return
            }
            if objectStore.keys.compare(index, key) > 0 {
                remainingRange.upperKey = key
                remainingRange.upperOpen = false
                setFirstInRemainingRange(objectStore)
            }
            return
        }
        if count == 0 {
            count = 1
        }
        if didResetIterator, let currentPosition, objectStore.keys.compare(index, currentPosition) < 0 {
            count -= 1
        }
        while count > 0 {
            if index == 0 {
                iterator = nil
                return
            }
            count -= 1
            index -= 1
            if !range.contains(objectStore.keys.key(index)) {
                iterator = nil
                return
            }
            setIterator(objectStore, index)
        }
    }

    mutating func iterate(
        _ objectStore: inout MemoryIDBObjectStoreState,
        _ targetKey: MemoryIDBKey,
        _ count: UInt32
    ) -> WebCore.IDBGetResult {
        objectStore.orderKeys()
        if !objectStore.hasOrderedKeys {
            currentPosition = nil
            iterator = nil
            return WebCore.makeEmptyIDBGetResult()
        }
        if targetKey.isValid && !range.contains(targetKey) {
            currentPosition = nil
            iterator = nil
            return WebCore.makeEmptyIDBGetResult()
        }
        if isForward {
            incrementForwardIterator(objectStore, targetKey, count)
        } else {
            incrementReverseIterator(objectStore, targetKey, count)
        }
        currentPosition = nil
        if resolvedIterator(objectStore) == nil {
            return WebCore.makeEmptyIDBGetResult()
        }
        return currentData(&objectStore)
    }
}

/// The position of an index cursor, keys only.
struct MemoryIDBIndexCursor {
    let isForward: Bool
    let isKeyOnly: Bool
    var position = MemoryIndexValueStorePosition()
    var currentKey = MemoryIDBKey.null
    var currentPrimaryKey = MemoryIDBKey.null
    /// Whether the cursor is clean: told of every change to the index.
    var isClean = false

    init(_ info: WebCore.IDBCursorInfo, _ index: borrowing MemoryIDBIndexState) {
        let range = MemoryIDBKeyRange(WebCore.idbCursorInfoRange(info))
        let direction = info.cursorDirection()
        isForward = info.isDirectionForward()
        isKeyOnly = info.cursorType() == .KeyOnly
        position.rangeLowerKey = range.lowerKey
        position.rangeUpperKey = range.upperKey
        position.rangeLowerOpen = range.lowerOpen
        position.rangeUpperOpen = range.upperOpen
        position.cursorForward = isForward
        position.cursorUnique = direction == .Nextunique || direction == .Prevunique
        position.cursorNoDuplicates = info.duplicity() == .NoDuplicates
        if let records = index.records {
            isClean = records.openCursor(&position, &currentKey, &currentPrimaryKey)
        }
    }

    /// The step; false when the cursor is at its end (no result).
    mutating func iterate(_ index: borrowing MemoryIDBIndexState, _ key: MemoryIDBKey, _ primaryKey: MemoryIDBKey, _ count: UInt32) -> Bool
    {
        var outcome: UInt8 = 0
        // The store read in place, not copied out of the index.
        if let result = index.records?.iterateCursor(key, primaryKey, count, &currentKey, &currentPrimaryKey, &position) {
            outcome = result
        } else if !key.isValid {
            position.invalidate()
        }
        if outcome & 1 != 0 {
            isClean = true
        }
        // No valid position after an iteration: the cursor is at its end.
        if outcome & 2 == 0 {
            currentKey = .null
            currentPrimaryKey = .null
            return false
        }
        return true
    }

    func currentData(_ objectStore: inout MemoryIDBObjectStoreState) -> WebCore.IDBGetResult {
        if !position.isValid {
            return WebCore.makeEmptyIDBGetResult()
        }
        let key = currentKey.makeIDBKeyData()
        let primaryKey = currentPrimaryKey.makeIDBKeyData()
        if isKeyOnly {
            return WebCore.makeIDBCursorResultKeys(key, primaryKey)
        }
        return objectStore.cursorResult(key, primaryKey, currentPrimaryKey)
    }

    mutating func indexRecordsAllChanged() {
        position.invalidate()
        isClean = false
    }

    mutating func indexValueChanged(_ key: MemoryIDBKey, _ primaryKey: MemoryIDBKey) {
        // A reverse cursor re-seeks after any change to the index; a forward one only when its own record changed.
        let atOtherRecord = currentKey != key || currentPrimaryKey != primaryKey
        if isForward && atOtherRecord {
            return
        }
        position.invalidate()
        isClean = false
    }
}

/// The two cursor kinds, a closed set.
///
/// Each step consumes the payload and puts it back (a move, not a copy).
enum MemoryIDBCursorState: ~Copyable {
    case objectStore(MemoryIDBObjectStoreCursor)
    case index(MemoryIDBIndexCursor)

    mutating func objectStoreCleared() {
        switch consume self {
        case .objectStore(var cursor):
            cursor.iterator = nil
            self = .objectStore(cursor)
        case .index(let cursor):
            self = .index(cursor)
        }
    }

    mutating func keyDeleted(_ key: MemoryIDBKey) {
        switch consume self {
        case .objectStore(var cursor):
            cursor.keyDeleted(key)
            self = .objectStore(cursor)
        case .index(let cursor):
            self = .index(cursor)
        }
    }

    mutating func keyAdded(_ objectStore: borrowing MemoryIDBObjectStoreState, _ position: Int) {
        switch consume self {
        case .objectStore(var cursor):
            cursor.keyAdded(objectStore, position)
            self = .objectStore(cursor)
        case .index(let cursor):
            self = .index(cursor)
        }
    }

    mutating func indexRecordsAllChanged() {
        switch consume self {
        case .objectStore(let cursor):
            self = .objectStore(cursor)
        case .index(var cursor):
            if cursor.isClean {
                cursor.indexRecordsAllChanged()
            }
            self = .index(cursor)
        }
    }

    mutating func indexValueChanged(_ key: MemoryIDBKey, _ primaryKey: MemoryIDBKey) {
        switch consume self {
        case .objectStore(let cursor):
            self = .objectStore(cursor)
        case .index(var cursor):
            if cursor.isClean {
                cursor.indexValueChanged(key, primaryKey)
            }
            self = .index(cursor)
        }
    }

    mutating func currentData(_ objectStore: inout MemoryIDBObjectStoreState) -> WebCore.IDBGetResult {
        switch consume self {
        case .objectStore(var cursor):
            let result = cursor.currentData(&objectStore)
            self = .objectStore(cursor)
            return result
        case .index(let cursor):
            let result = cursor.currentData(&objectStore)
            self = .index(cursor)
            return result
        }
    }

    mutating func iterateObjectStoreCursor(
        _ objectStore: inout MemoryIDBObjectStoreState,
        _ key: MemoryIDBKey,
        _ count: UInt32
    ) -> WebCore.IDBGetResult {
        switch consume self {
        case .objectStore(var cursor):
            let result = cursor.iterate(&objectStore, key, count)
            self = .objectStore(cursor)
            return result
        case .index(let cursor):
            self = .index(cursor)
            return WebCore.makeEmptyIDBGetResult()
        }
    }

    mutating func iterateIndexCursor(
        _ index: borrowing MemoryIDBIndexState,
        _ key: MemoryIDBKey,
        _ primaryKey: MemoryIDBKey,
        _ count: UInt32
    ) -> Bool {
        switch consume self {
        case .objectStore(let cursor):
            self = .objectStore(cursor)
            return false
        case .index(var cursor):
            let hasResult = cursor.iterate(index, key, primaryKey, count)
            self = .index(cursor)
            return hasResult
        }
    }
}

/// A cursor with what finds it: its transaction, and its object store or index, by identifier.
struct MemoryIDBCursorEntry: ~Copyable {
    let identifier: WebCore.IDBResourceIdentifier
    let transactionIdentifier: WebCore.IDBResourceIdentifier
    let objectStoreIdentifier: UInt64
    let isIndexCursor: Bool
    /// The index's identifier, for an index cursor.
    let indexIdentifier: UInt64
    var state: MemoryIDBCursorState
    /// Left behind by a read-only transaction's finish (on a store its names did not give): no transaction reaches it.
    var isFinished = false
}

func memoryIDBNotifyObjectStoreCleared(_ cursors: inout UniqueArray<MemoryIDBCursorEntry>, _ objectStoreIdentifier: UInt64) {
    for i in 0..<cursors.count where !cursors[i].isIndexCursor && cursors[i].objectStoreIdentifier == objectStoreIdentifier {
        cursors[i].state.objectStoreCleared()
    }
}

/// Whether an object store cursor is open on the object store: its positions are indices into the store's ordered keys.
func memoryIDBHasObjectStoreCursor(
    _ cursors: borrowing UniqueArray<MemoryIDBCursorEntry>,
    _ objectStoreIdentifier: UInt64
) -> Bool {
    for i in 0..<cursors.count where !cursors[i].isIndexCursor && cursors[i].objectStoreIdentifier == objectStoreIdentifier {
        return true
    }
    return false
}

/// Whether a cursor is open on the index: its positions are indices into the index's entries.
func memoryIDBHasIndexCursor(_ cursors: borrowing UniqueArray<MemoryIDBCursorEntry>, _ indexIdentifier: UInt64) -> Bool {
    for i in 0..<cursors.count where cursors[i].isIndexCursor && cursors[i].indexIdentifier == indexIdentifier {
        return true
    }
    return false
}

func memoryIDBNotifyKeyDeleted(
    _ cursors: inout UniqueArray<MemoryIDBCursorEntry>,
    _ objectStoreIdentifier: UInt64,
    _ key: MemoryIDBKey
) {
    for i in 0..<cursors.count where !cursors[i].isIndexCursor && cursors[i].objectStoreIdentifier == objectStoreIdentifier {
        cursors[i].state.keyDeleted(key)
    }
}

func memoryIDBNotifyIndexRecordsAllChanged(_ cursors: inout UniqueArray<MemoryIDBCursorEntry>, _ indexIdentifier: UInt64) {
    for i in 0..<cursors.count where cursors[i].isIndexCursor && cursors[i].indexIdentifier == indexIdentifier {
        cursors[i].state.indexRecordsAllChanged()
    }
}

func memoryIDBNotifyIndexValueChanged(
    _ cursors: inout UniqueArray<MemoryIDBCursorEntry>,
    _ indexIdentifier: UInt64,
    _ key: MemoryIDBKey,
    _ primaryKey: MemoryIDBKey
) {
    for i in 0..<cursors.count where cursors[i].isIndexCursor && cursors[i].indexIdentifier == indexIdentifier {
        cursors[i].state.indexValueChanged(key, primaryKey)
    }
}

/// The cursors that end with an object store or index that is destroyed.
func memoryIDBRemoveCursors(_ cursors: inout UniqueArray<MemoryIDBCursorEntry>, objectStore objectStoreIdentifier: UInt64) {
    var i = 0
    while i < cursors.count {
        if cursors[i].objectStoreIdentifier == objectStoreIdentifier {
            _ = cursors.remove(at: i)
        } else {
            i += 1
        }
    }
}

func memoryIDBRemoveCursors(_ cursors: inout UniqueArray<MemoryIDBCursorEntry>, index indexIdentifier: UInt64) {
    var i = 0
    while i < cursors.count {
        if cursors[i].isIndexCursor && cursors[i].indexIdentifier == indexIdentifier {
            _ = cursors.remove(at: i)
        } else {
            i += 1
        }
    }
}
