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

// An index's records in the memory backing store: for each index key, the primary keys of the records that have it,
// both sorted arrays of MemoryIDBKey in IDBKeyData's order, searched by binary search with memoryIDBCompare. Cursors hold
// a MemoryIndexValueStorePosition (indices plus a generation).

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes
internal import WebCore_Private.Core.ThreadSafeDataBuffer
internal import wtf.Assertions
internal import wtf.Core.text.WTFString

/// The elements that insertions and removals in the middle of a sorted array have moved since its order was last read,
/// against the cost of sorting it instead: past that, the array is left unordered and the next ordered read sorts it,
/// so random-order writes do not move half the array each.
struct MemoryIDBSortedArrayMoves {
    private var moves = 0

    /// Called at every read of the order.
    mutating func reset() {
        moves = 0
    }

    /// Counts `moved` elements moved in an array of `count`; true once the moves since the last reset exceed about the
    /// cost of sorting it (16 n log2 n).
    mutating func exceedSortCost(adding moved: Int, count: Int) -> Bool {
        moves += moved
        return moves > 16 * count * (Int.bitWidth - count.leadingZeroBitCount)
    }
}

/// First index whose element is not less than `key`.
func memoryIndexLowerBound(_ elements: borrowing ContiguousArray<MemoryIDBKey>, _ key: MemoryIDBKey) -> Int {
    var low = 0
    var high = elements.count
    while low < high {
        let middle = low + (high - low) / 2
        if memoryIDBCompare(elements[middle], key) < 0 {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

/// First index whose element is greater than `key`.
func memoryIndexUpperBound(_ elements: borrowing ContiguousArray<MemoryIDBKey>, _ key: MemoryIDBKey) -> Int {
    var low = 0
    var high = elements.count
    while low < high {
        let middle = low + (high - low) / 2
        if memoryIDBCompare(elements[middle], key) <= 0 {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

/// One index key and the primary keys of the records that have it, ascending (exactly one in a unique index).
///
/// The lowest primary key is held inline, so an entry with one record allocates no array:
/// `first` is the lowest primary key, `rest` the others ascending and each greater than `first`; removing `first`
/// promotes `rest[0]`; a unique index's entry has an empty `rest`. Primary key `i` is `first` for 0, `rest[i - 1]` after.
struct MemoryIndexValueEntry {
    let key: MemoryIDBKey
    /// The key's hash.
    let hash: UInt64
    private(set) var first: MemoryIDBKey
    private(set) var rest: ContiguousArray<MemoryIDBKey> = []

    init(_ key: MemoryIDBKey, _ hash: UInt64, _ primaryKey: MemoryIDBKey) {
        self.key = key
        self.hash = hash
        first = primaryKey
    }

    /// With `primaryKeys` not empty, ascending and distinct.
    init(_ key: MemoryIDBKey, _ hash: UInt64, primaryKeys: ContiguousArray<MemoryIDBKey>) {
        self.key = key
        self.hash = hash
        first = primaryKeys[0]
        rest = ContiguousArray(primaryKeys.dropFirst())
    }

    var count: Int {
        rest.count + 1
    }

    subscript(_ index: Int) -> MemoryIDBKey {
        index == 0 ? first : rest[index - 1]
    }

    /// All the primary keys, ascending.
    var primaryKeys: ContiguousArray<MemoryIDBKey> {
        var keys = ContiguousArray<MemoryIDBKey>()
        keys.reserveCapacity(count)
        keys.append(first)
        keys.append(contentsOf: rest)
        return keys
    }

    /// The position of the first primary key not less than `primaryKey`.
    func lowerBound(_ primaryKey: MemoryIDBKey) -> Int {
        memoryIDBCompare(first, primaryKey) >= 0 ? 0 : 1 + memoryIndexLowerBound(rest, primaryKey)
    }

    /// The position of the first primary key greater than `primaryKey`.
    func upperBound(_ primaryKey: MemoryIDBKey) -> Int {
        memoryIDBCompare(first, primaryKey) > 0 ? 0 : 1 + memoryIndexUpperBound(rest, primaryKey)
    }

    func find(_ primaryKey: MemoryIDBKey) -> Int? {
        let position = lowerBound(primaryKey)
        if position < count && memoryIDBCompare(self[position], primaryKey) == 0 {
            return position
        }
        return nil
    }

    func contains(_ primaryKey: MemoryIDBKey) -> Bool {
        find(primaryKey) != nil
    }

    /// A set insertion: an equal primary key already there is kept.
    mutating func insert(_ primaryKey: MemoryIDBKey) {
        // Keys arriving in ascending order (the common case) go at the end: one comparison, not a binary search.
        if memoryIDBCompare(self[count - 1], primaryKey) < 0 {
            rest.append(primaryKey)
            return
        }
        let position = lowerBound(primaryKey)
        if memoryIDBCompare(self[position], primaryKey) == 0 {
            return
        }
        if position == 0 {
            let second = first
            first = primaryKey
            rest.insert(second, at: 0)
        } else {
            rest.insert(primaryKey, at: position - 1)
        }
    }

    /// Removes primary key `index`, with `count > 1`.
    mutating func remove(at index: Int) {
        if index == 0 {
            first = rest.removeFirst()
        } else {
            rest.remove(at: index - 1)
        }
    }
}

/// First entry whose key is not less than `key`.
func memoryIndexEntryLowerBound(_ entries: borrowing ContiguousArray<MemoryIndexValueEntry>, _ key: MemoryIDBKey) -> Int {
    var low = 0
    var high = entries.count
    while low < high {
        let middle = low + (high - low) / 2
        if memoryIDBCompare(entries[middle].key, key) < 0 {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

/// First entry whose key is greater than `key`.
func memoryIndexEntryUpperBound(_ entries: borrowing ContiguousArray<MemoryIndexValueEntry>, _ key: MemoryIDBKey) -> Int {
    var low = 0
    var high = entries.count
    while low < high {
        let middle = low + (high - low) / 2
        if memoryIDBCompare(entries[middle].key, key) <= 0 {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

/// The index of the entry for `key`, if present.
func memoryIndexEntryFind(_ entries: borrowing ContiguousArray<MemoryIndexValueEntry>, _ key: MemoryIDBKey) -> Int? {
    let index = memoryIndexEntryLowerBound(entries, key)
    if index < entries.count && memoryIDBCompare(entries[index].key, key) == 0 {
        return index
    }
    return nil
}

/// The primary keys each index key had before a write transaction changed it: membership by hash, and the entries in the order
/// they were added (nothing is removed but all at once), so iterating it does not depend on a hash. `add` keeps the
/// first primary keys.
struct MemoryIndexModifiedRecords {
    struct Entry {
        let key: MemoryIDBKey
        let hash: UInt64
        let primaryKeys: ContiguousArray<MemoryIDBKey>
    }

    private(set) var entries: ContiguousArray<Entry> = []
    private var keys = MemoryIDBKeyTable<Void>()

    func contains(_ key: MemoryIDBKey, _ hash: UInt64) -> Bool {
        keys.contains(key, hash)
    }

    mutating func add(_ key: MemoryIDBKey, _ hash: UInt64, _ primaryKeys: ContiguousArray<MemoryIDBKey>) {
        if keys.contains(key, hash) {
            return
        }
        keys.insert(key, hash, ())
        entries.append(Entry(key: key, hash: hash, primaryKeys: primaryKeys))
    }

    mutating func reserve(_ additional: Int) {
        entries.reserveCapacity(entries.count + additional)
    }

    mutating func removeAll() {
        self = MemoryIndexModifiedRecords()
    }
}

/// A position in a MemoryIndexValueStore: the indices of the record it designates, plus the store's mutation
/// generation at which they were last valid.
///
/// A position never points into the store, so a stale one re-seeks by its record's keys (the cursor's current keys).
struct MemoryIndexValueStorePosition {
    var generation: UInt64 = 0
    var keyIndex = 0
    var primaryKeyIndex = 0
    var isValid = false
    var forward = true
    var noDuplicates = false
    // The cursor's range and direction (set once, when the cursor opens).
    var rangeLowerKey = MemoryIDBKey.null
    var rangeUpperKey = MemoryIDBKey.null
    var rangeLowerOpen = false
    var rangeUpperOpen = false
    var cursorForward = true
    var cursorUnique = false
    var cursorNoDuplicates = false

    mutating func invalidate() {
        isValid = false
    }
}

/// An index's records: the entries by index key, each with at least one primary key, and the same keys by hash.
///
/// The entries are kept ascending until out-of-order writes with no ordered read between them have moved about as
/// many entries as one sort costs; they are then kept in the order of the key table's entries, which finds them by
/// hash, and the next ordered read (order()) sorts them.
struct MemoryIndexValueStore {
    private let unique: Bool
    /// Ascending by key while `isOrdered`; otherwise in the order of the key table's entries (entry `i` has key `i`).
    private(set) var entries: ContiguousArray<MemoryIndexValueEntry> = []
    /// The entries' keys by hash.
    private var keys = MemoryIDBKeyTable<Void>()
    private(set) var isOrdered = true
    private var moves = MemoryIDBSortedArrayMoves()
    /// Changes on every mutation, so that a position whose indices predate it re-seeks by its keys.
    private var generation: UInt64

    init(unique: Bool, generation: UInt64) {
        self.unique = unique
        self.generation = generation
    }

    var currentGeneration: UInt64 { generation }

    /// Called before every read of the order (ranges, cursors); sorts the entries if writes left them unordered.
    mutating func order() {
        moves.reset()
        if isOrdered {
            return
        }
        entries.sort { memoryIDBCompare($0.key, $1.key) < 0 }
        isOrdered = true
        generation &+= 1
    }

    // MARK: Lookups

    /// The lowest primary key for `key`, or nil if there is none.
    func lowestValueForKey(_ key: MemoryIDBKey) -> MemoryIDBKey? {
        guard let index = entryIndex(key) else {
            return nil
        }
        return entries[index].first
    }

    /// The entry for `key`, if any.
    func entry(_ key: MemoryIDBKey) -> MemoryIndexValueEntry? {
        guard let index = entryIndex(key) else {
            return nil
        }
        return entries[index]
    }

    func countForKey(_ key: MemoryIDBKey) -> UInt64 {
        guard let index = entryIndex(key) else {
            return 0
        }
        return UInt64(entries[index].count)
    }

    /// By hash, with `hash` the key's hash.
    func contains(_ key: MemoryIDBKey, _ hash: UInt64) -> Bool {
        keys.contains(key, hash)
    }

    /// The primary keys of `key` by hash, or nil if the store has no entry for it.
    func primaryKeysForKey(_ key: MemoryIDBKey, _ hash: UInt64) -> ContiguousArray<MemoryIDBKey>? {
        // A key found by hash is not a NaN, so the ordered search compares no NaN.
        guard keys.contains(key, hash), let index = entryIndex(key, hash) else {
            return nil
        }
        return entries[index].primaryKeys
    }

    /// The lowest index key in the range, or nil; a range of more than one key reads the order.
    func lowestKeyWithRecordInRange(
        _ lowerKey: MemoryIDBKey,
        _ upperKey: MemoryIDBKey,
        _ lowerOpen: Bool,
        _ upperOpen: Bool,
        _ isExactlyOneKey: Bool
    ) -> MemoryIDBKey? {
        if isExactlyOneKey {
            return entryIndex(lowerKey) != nil ? lowerKey : nil
        }
        guard let index = view.lowestIndexInRange(lowerKey, upperKey, lowerOpen, upperOpen) else {
            return nil
        }
        return entries[index].key
    }

    // MARK: Mutations

    /// False, changing nothing, when the index is unique and already has `indexKey` (the caller's ConstraintError).
    /// `hash` is the index key's hash and `isPresent` whether the store has it (`contains(indexKey, hash)`);
    /// `mayLeaveUnsorted` is false while a cursor is open on the index, whose positions are indices into `entries`.
    mutating func addRecord(
        _ indexKey: MemoryIDBKey,
        _ hash: UInt64,
        _ valueKey: MemoryIDBKey,
        isPresent: Bool,
        mayLeaveUnsorted: Bool
    ) -> Bool {
        // An existing index key by hash; a new one into the ordered entries too.
        if isPresent {
            if unique {
                return false
            }
            generation &+= 1
            guard let index = entryIndex(indexKey, hash) else {
                return true
            }
            entries[index].insert(valueKey)
            return true
        }
        generation &+= 1
        insertEntry(MemoryIndexValueEntry(indexKey, hash, valueKey), mayLeaveUnsorted: mayLeaveUnsorted)
        return true
    }

    /// Adds an entry whose key is absent, to the entries and the key table.
    private mutating func insertEntry(_ entry: MemoryIndexValueEntry, mayLeaveUnsorted: Bool) {
        let count = entries.count
        if isOrdered {
            // Keys arriving in ascending order (the common case) go at the end: one comparison, not a binary search.
            if count == 0 || memoryIDBCompare(entries[count - 1].key, entry.key) < 0 {
                keys.insert(entry.key, entry.hash, ())
                entries.append(entry)
                return
            }
            let position = memoryIndexEntryLowerBound(entries, entry.key)
            if keepsOrder(moving: count - position, mayLeaveUnsorted: mayLeaveUnsorted) {
                keys.insert(entry.key, entry.hash, ())
                entries.insert(entry, at: position)
                return
            }
        }
        keys.insert(entry.key, entry.hash, ())
        entries.append(entry)
    }

    mutating func removeRecord(_ indexKey: MemoryIDBKey, _ valueKey: MemoryIDBKey, mayLeaveUnsorted: Bool) {
        guard let index = entryIndex(indexKey) else {
            return
        }
        removePrimaryKey(index, valueKey, mayLeaveUnsorted: mayLeaveUnsorted)
    }

    /// Removes the entry for `indexKey`, whatever its primary keys.
    mutating func removeAllRecordsForIndexKey(_ indexKey: MemoryIDBKey, mayLeaveUnsorted: Bool) {
        guard let index = entryIndex(indexKey) else {
            return
        }
        removeEntry(index, mayLeaveUnsorted: mayLeaveUnsorted)
    }

    /// removeAllRecordsForIndexKey(indexKey), then addRecord(indexKey, k) for each k of `primaryKeys` in order, which
    /// are ascending and distinct (an entry's primary keys saved earlier): when the key is then absent, its new entry
    /// takes the keys whole rather than growing one key at a time.
    mutating func restoreRecords(
        _ indexKey: MemoryIDBKey,
        _ hash: UInt64,
        _ primaryKeys: ContiguousArray<MemoryIDBKey>,
        mayLeaveUnsorted: Bool
    ) {
        removeAllRecordsForIndexKey(indexKey, mayLeaveUnsorted: mayLeaveUnsorted)
        if primaryKeys.isEmpty {
            return
        }
        let present = keys.contains(indexKey, hash)
        if (unique && primaryKeys.count > 1) || present {
            for primaryKey in primaryKeys {
                _ = addRecord(indexKey, hash, primaryKey, isPresent: keys.contains(indexKey, hash), mayLeaveUnsorted: mayLeaveUnsorted)
            }
            return
        }
        generation &+= 1
        insertEntry(MemoryIndexValueEntry(indexKey, hash, primaryKeys: primaryKeys), mayLeaveUnsorted: mayLeaveUnsorted)
    }

    /// Removes `valueKey` from every entry, dropping entries left empty, and returns the index keys of the entries that
    /// had it, in the order of `entries`.
    mutating func removeEntriesWithValueKey(_ valueKey: MemoryIDBKey, mayLeaveUnsorted: Bool) -> ContiguousArray<MemoryIDBKey> {
        var changed = ContiguousArray<MemoryIDBKey>()
        var start = 0
        while let (index, position) = firstEntry(containing: valueKey, from: start) {
            changed.append(entries[index].key)
            generation &+= 1
            if entries[index].count == 1 {
                // The entry that takes its place, if any, is looked at next.
                removeEntry(index, mayLeaveUnsorted: mayLeaveUnsorted)
                start = index
                continue
            }
            entries[index].remove(at: position)
            start = index + 1
        }
        return changed
    }

    /// The first entry from `start` on holding the primary key, and its position there.
    ///
    /// Not mutating, so the scan
    /// reads the entries' keys in place instead of copying each one (a retain and a release per entry).
    private func firstEntry(containing valueKey: MemoryIDBKey, from start: Int) -> (index: Int, position: Int)? {
        for index in start..<entries.count {
            if let position = entries[index].find(valueKey) {
                return (index, position)
            }
        }
        return nil
    }

    // MARK: Positions

    /// The entries, generation and uniqueness for one seek or step: a value, so the position code below reads them
    /// with static exclusivity.
    private var view: MemoryIndexValueStoreView {
        MemoryIndexValueStoreView(entries: entries, generation: generation, unique: unique)
    }

    /// A new cursor's first position (MemoryIndexValueStoreView.openCursor), after order().
    func openCursor(
        _ position: inout MemoryIndexValueStorePosition,
        _ currentKey: inout MemoryIDBKey,
        _ currentPrimaryKey: inout MemoryIDBKey
    ) -> Bool {
        view.openCursor(&position, &currentKey, &currentPrimaryKey)
    }

    /// A cursor's next position (MemoryIndexValueStoreView.iterateCursor), after order().
    func iterateCursor(
        _ key: MemoryIDBKey,
        _ primaryKey: MemoryIDBKey,
        _ count: UInt32,
        _ currentKey: inout MemoryIDBKey,
        _ currentPrimaryKey: inout MemoryIDBKey,
        _ position: inout MemoryIndexValueStorePosition
    ) -> UInt8 {
        view.iterateCursor(key, primaryKey, count, &currentKey, &currentPrimaryKey, &position)
    }

    // MARK: Private

    /// The index of the entry for `key`, if present: by its key's order, or by hash while the entries are unordered.
    private func entryIndex(_ key: MemoryIDBKey) -> Int? {
        if isOrdered {
            return memoryIndexEntryFind(entries, key)
        }
        return keys.find(key, key.hash)
    }

    /// entryIndex(key), with `hash` the key's hash.
    private func entryIndex(_ key: MemoryIDBKey, _ hash: UInt64) -> Int? {
        if isOrdered {
            return memoryIndexEntryFind(entries, key)
        }
        return keys.find(key, hash)
    }

    /// Counts an insertion or removal moving `count` entries; false when it stops keeping the order instead, which an
    /// open cursor on the index (`mayLeaveUnsorted` false) prevents.
    ///
    /// The key table is then rebuilt in the entries' order. Moves made while the order must be kept are not counted.
    private mutating func keepsOrder(moving count: Int, mayLeaveUnsorted: Bool) -> Bool {
        if !mayLeaveUnsorted || !moves.exceedSortCost(adding: count, count: entries.count) {
            return true
        }
        keys = MemoryIDBKeyTable()
        keys.reserve(entries.count + 1)
        for entry in entries {
            keys.insert(entry.key, entry.hash, ())
        }
        isOrdered = false
        return false
    }

    private mutating func removePrimaryKey(_ index: Int, _ valueKey: MemoryIDBKey, mayLeaveUnsorted: Bool) {
        guard let position = entries[index].find(valueKey) else {
            return
        }
        generation &+= 1
        if entries[index].count == 1 {
            removeEntry(index, mayLeaveUnsorted: mayLeaveUnsorted)
            return
        }
        entries[index].remove(at: position)
    }

    private mutating func removeEntry(_ index: Int, mayLeaveUnsorted: Bool) {
        generation &+= 1
        let last = entries.count - 1
        if isOrdered {
            if index == last || keepsOrder(moving: last - index, mayLeaveUnsorted: mayLeaveUnsorted) {
                keys.remove(entries[index].key, entries[index].hash)
                entries.remove(at: index)
                return
            }
        }
        // The key table moves its last entry into the removed one's place; the entries follow it.
        keys.remove(entries[index].key, entries[index].hash)
        entries.swapAt(index, last)
        entries.removeLast()
    }
}

/// IDBKeyRangeData::containsKey, on the range's four fields.
func memoryIDBRangeContains(
    _ lowerKey: MemoryIDBKey,
    _ upperKey: MemoryIDBKey,
    _ lowerOpen: Bool,
    _ upperOpen: Bool,
    _ key: MemoryIDBKey
) -> Bool {
    if lowerKey.isValid {
        let order = memoryIDBCompare(lowerKey, key)
        if order > 0 || (lowerOpen && order == 0) {
            return false
        }
    }
    if upperKey.isValid {
        let order = memoryIDBCompare(upperKey, key)
        if order < 0 || (upperOpen && order == 0) {
            return false
        }
    }
    return true
}

/// The store's position code (a position's moves and the cursor logic that combines them), on a
/// value snapshot of the store taken once per call: it changes only the position and the cursor's current keys.
struct MemoryIndexValueStoreView {
    let entries: ContiguousArray<MemoryIndexValueEntry>
    let generation: UInt64
    let unique: Bool

    /// Whether a valid, current position's record is in its cursor's range.
    func positionInRange(_ position: MemoryIndexValueStorePosition) -> Bool {
        memoryIDBRangeContains(
            position.rangeLowerKey,
            position.rangeUpperKey,
            position.rangeLowerOpen,
            position.rangeUpperOpen,
            entries[position.keyIndex].key
        )
    }

    /// The cursor's current keys become a valid, current position's record's.
    ///
    /// The position holds indices only.
    func takeCurrentKeys(
        _ position: MemoryIndexValueStorePosition,
        _ currentKey: inout MemoryIDBKey,
        _ currentPrimaryKey: inout MemoryIDBKey
    ) {
        currentKey = entries[position.keyIndex].key
        currentPrimaryKey = entries[position.keyIndex][position.primaryKeyIndex]
    }

    /// A new cursor's first position: the first record of the range in the cursor's direction.
    ///
    /// Returns whether there is one in the range (the cursor then becomes clean, at that record's keys); `position` is
    /// invalid otherwise.
    func openCursor(
        _ position: inout MemoryIndexValueStorePosition,
        _ currentKey: inout MemoryIDBKey,
        _ currentPrimaryKey: inout MemoryIDBKey
    ) -> Bool {
        if position.cursorForward {
            findKey(position.rangeLowerKey, position.rangeLowerOpen, &position)
        } else {
            reverseFindKey(position.rangeUpperKey, position.cursorNoDuplicates, position.rangeUpperOpen, &position)
        }
        if position.isValid && positionInRange(position) {
            takeCurrentKeys(position, &currentKey, &currentPrimaryKey)
            return true
        }
        position.invalidate()
        return false
    }

    /// Moves a cursor to (`key`, `primaryKey`) when `key` is valid, else `count` records on (0 means 1) from the
    /// cursor's current record, re-seeking from (`currentKey`, `currentPrimaryKey`) first when the position was
    /// invalidated (`unique`: a Nextunique or Prevunique cursor).
    ///
    /// Returns bit 0 when the cursor became clean on the way (a re-seek found a record), bit 1 when it ends at a record
    /// in the range (then also clean), and the current keys are then that record's; otherwise they are left for the
    /// caller to clear. A valid position is always at the current keys between calls (revalidate re-seeks by them).
    func iterateCursor(
        _ key: MemoryIDBKey,
        _ primaryKey: MemoryIDBKey,
        _ count: UInt32,
        _ currentKey: inout MemoryIDBKey,
        _ currentPrimaryKey: inout MemoryIDBKey,
        _ position: inout MemoryIndexValueStorePosition
    ) -> UInt8 {
        let forward = position.cursorForward
        let unique = position.cursorUnique
        let noDuplicates = position.cursorNoDuplicates
        if key.isValid {
            if primaryKey.isValid {
                if forward {
                    findRecord(key, primaryKey, &position)
                } else {
                    reverseFindRecord(key, primaryKey, noDuplicates, &position)
                }
            } else if forward {
                findKey(key, false, &position)
            } else {
                reverseFindKey(key, noDuplicates, false, &position)
            }
            if position.isValid && positionInRange(position) {
                takeCurrentKeys(position, &currentKey, &currentPrimaryKey)
                return 3
            }
            position.invalidate()
            return 0
        }

        var remaining = count == 0 ? 1 : count
        var outcome: UInt8 = 0
        if !position.isValid {
            if forward {
                if unique {
                    findKey(currentKey, true, &position)
                } else {
                    findRecord(currentKey, currentPrimaryKey, &position)
                }
            } else if unique {
                reverseFindKey(currentKey, noDuplicates, true, &position)
            } else {
                reverseFindRecord(currentKey, currentPrimaryKey, noDuplicates, &position)
            }
            if !position.isValid {
                return 0
            }
            outcome = 1
            // A restored position not at the current record is the next one in line: that counts as one step.
            let entry = entries[position.keyIndex]
            if currentKey != entry.key || currentPrimaryKey != entry[position.primaryKeyIndex] {
                remaining -= 1
            }
        }

        while remaining > 0 {
            if noDuplicates {
                nextIndexEntry(&position, currentKey, currentPrimaryKey)
            } else {
                advance(&position, currentKey, currentPrimaryKey)
            }
            if !position.isValid {
                break
            }
            remaining -= 1
        }

        if position.isValid && positionInRange(position) {
            takeCurrentKeys(position, &currentKey, &currentPrimaryKey)
            return outcome | 2
        }
        position.invalidate()
        return outcome
    }

    /// The first record at `key` (the minimum key if null), or after it if `open`; invalid if none.
    func findKey(_ key: MemoryIDBKey, _ open: Bool, _ position: inout MemoryIndexValueStorePosition) {
        guard let index = lowestIndexInRange(key.isNull ? .min : key, .null, open, false) else {
            position.invalidate()
            return
        }
        setPosition(&position, forward: true, noDuplicates: false, index, 0)
    }

    /// The record at (`key`, `primaryKey`), or the next one after it; invalid if none.
    func findRecord(_ key: MemoryIDBKey, _ primaryKey: MemoryIDBKey, _ position: inout MemoryIndexValueStorePosition) {
        guard let index = lowestIndexInRange(key, .null, false, false) else {
            position.invalidate()
            return
        }
        // At a higher index key, the first primary key is the next record.
        if memoryIDBCompare(entries[index].key, key) != 0 {
            setPosition(&position, forward: true, noDuplicates: false, index, 0)
            return
        }
        if let primaryKeyIndex = entryFind(index, primaryKey) {
            setPosition(&position, forward: true, noDuplicates: false, index, primaryKeyIndex)
            return
        }
        // No such primary key in this entry: the start of the next one.
        if index + 1 >= entries.count {
            position.invalidate()
            return
        }
        setPosition(&position, forward: true, noDuplicates: false, index + 1, 0)
    }

    /// The last record at `key` (the maximum key if null), or before it if `open`; invalid if none.
    func reverseFindKey(_ key: MemoryIDBKey, _ noDuplicates: Bool, _ open: Bool, _ position: inout MemoryIndexValueStorePosition) {
        guard let index = highestIndexInRange(.null, key.isNull ? .max : key, false, open) else {
            position.invalidate()
            return
        }
        setPosition(&position, forward: false, noDuplicates: noDuplicates, index, reverseBeginIndex(index, noDuplicates))
    }

    /// The record at (`key`, `primaryKey`), or the next one before it; invalid if none.
    func reverseFindRecord(
        _ key: MemoryIDBKey,
        _ primaryKey: MemoryIDBKey,
        _ noDuplicates: Bool,
        _ position: inout MemoryIndexValueStorePosition
    ) {
        guard let index = highestIndexInRange(.null, key, false, false) else {
            position.invalidate()
            return
        }
        if let primaryKeyIndex = entryReverseFind(index, primaryKey) {
            setPosition(&position, forward: false, noDuplicates: noDuplicates, index, primaryKeyIndex)
            return
        }
        // No such primary key in this entry: the start (in reverse) of the next one.
        if index == 0 {
            position.invalidate()
            return
        }
        setPosition(&position, forward: false, noDuplicates: noDuplicates, index - 1, reverseBeginIndex(index - 1, noDuplicates))
    }

    /// The next record in the position's direction (operator++); invalid past the last.
    ///
    /// A stale position re-seeks by the current keys, which only change after the last step.
    func advance(_ position: inout MemoryIndexValueStorePosition, _ currentKey: MemoryIDBKey, _ currentPrimaryKey: MemoryIDBKey) {
        guard position.isValid, revalidate(&position, currentKey, currentPrimaryKey) else {
            position.invalidate()
            return
        }
        let index = position.keyIndex
        let count = entries[index].count
        if position.forward {
            if !unique && position.primaryKeyIndex + 1 < count {
                setPosition(&position, forward: true, noDuplicates: position.noDuplicates, index, position.primaryKeyIndex + 1)
                return
            }
        } else if !unique && position.primaryKeyIndex > 0 {
            setPosition(&position, forward: false, noDuplicates: position.noDuplicates, index, position.primaryKeyIndex - 1)
            return
        }
        // Ran out of primary keys: the next index key.
        nextIndexEntry(&position, currentKey, currentPrimaryKey)
    }

    /// The first record (in the position's direction) of the next index key; invalid past the last.
    func nextIndexEntry(_ position: inout MemoryIndexValueStorePosition, _ currentKey: MemoryIDBKey, _ currentPrimaryKey: MemoryIDBKey) {
        guard position.isValid, revalidate(&position, currentKey, currentPrimaryKey) else {
            position.invalidate()
            return
        }
        let index = position.keyIndex
        if position.forward {
            if index + 1 >= entries.count {
                position.invalidate()
                return
            }
            setPosition(&position, forward: true, noDuplicates: position.noDuplicates, index + 1, 0)
        } else {
            if index == 0 {
                position.invalidate()
                return
            }
            setPosition(
                &position,
                forward: false,
                noDuplicates: position.noDuplicates,
                index - 1,
                reverseBeginIndex(index - 1, position.noDuplicates)
            )
        }
    }

    /// In a unique index only the exact primary key; otherwise the first not less than it.
    func entryFind(_ index: Int, _ primaryKey: MemoryIDBKey) -> Int? {
        if unique {
            return memoryIDBCompare(entries[index].first, primaryKey) == 0 ? 0 : nil
        }
        let position = entries[index].lowerBound(primaryKey)
        return position < entries[index].count ? position : nil
    }

    /// In a unique index only the exact primary key; otherwise the last not greater.
    func entryReverseFind(_ index: Int, _ primaryKey: MemoryIDBKey) -> Int? {
        if unique {
            return memoryIDBCompare(entries[index].first, primaryKey) == 0 ? 0 : nil
        }
        let position = entries[index].upperBound(primaryKey)
        return position > 0 ? position - 1 : nil
    }

    /// The highest primary key, except for a no-duplicates cursor, which gets the lowest (the reverse end), as unique
    /// cursors report the lowest primary key of each index key.
    func reverseBeginIndex(_ index: Int, _ noDuplicates: Bool) -> Int {
        noDuplicates ? 0 : entries[index].count - 1
    }

    /// The first entry whose key is in the range.
    func lowestIndexInRange(_ lowerKey: MemoryIDBKey, _ upperKey: MemoryIDBKey, _ lowerOpen: Bool, _ upperOpen: Bool) -> Int? {
        var index = memoryIndexEntryLowerBound(entries, lowerKey)
        if index >= entries.count {
            return nil
        }
        if lowerOpen && memoryIDBCompare(entries[index].key, lowerKey) == 0 {
            index += 1
            if index >= entries.count {
                return nil
            }
        }
        if !upperKey.isNull {
            let comparison = memoryIDBCompare(entries[index].key, upperKey)
            if comparison > 0 || (upperOpen && comparison == 0) {
                return nil
            }
        }
        return index
    }

    /// The last entry whose key is in the range.
    func highestIndexInRange(_ lowerKey: MemoryIDBKey, _ upperKey: MemoryIDBKey, _ lowerOpen: Bool, _ upperOpen: Bool) -> Int? {
        var end = memoryIndexEntryUpperBound(entries, upperKey)
        if end == 0 {
            return nil
        }
        if upperOpen && memoryIDBCompare(entries[end - 1].key, upperKey) == 0 {
            end -= 1
            if end == 0 {
                return nil
            }
        }
        let index = end - 1
        if !lowerKey.isNull {
            let comparison = memoryIDBCompare(entries[index].key, lowerKey)
            if comparison < 0 || (lowerOpen && comparison == 0) {
                return nil
            }
        }
        return index
    }

    func setPosition(
        _ position: inout MemoryIndexValueStorePosition,
        forward: Bool,
        noDuplicates: Bool,
        _ index: Int,
        _ primaryKeyIndex: Int
    ) {
        position.keyIndex = index
        position.primaryKeyIndex = primaryKeyIndex
        position.generation = generation
        position.forward = forward
        position.noDuplicates = noDuplicates
        position.isValid = true
    }

    /// Brings a valid position's indices up to date with the store, by its record's keys (the cursor's current keys,
    /// which a valid position designates).
    ///
    /// Its cursor's owner invalidates it when its own record goes (and a reverse one on any change), so the record is
    /// still here; if it is not, the position becomes invalid rather than pointing at another record.
    func revalidate(_ position: inout MemoryIndexValueStorePosition, _ key: MemoryIDBKey, _ primaryKey: MemoryIDBKey) -> Bool {
        if position.generation == generation {
            return true
        }
        guard let index = memoryIndexEntryFind(entries, key), let primaryKeyIndex = entries[index].find(primaryKey) else {
            return false
        }
        position.keyIndex = index
        position.primaryKeyIndex = primaryKeyIndex
        position.generation = generation
        return true
    }
}
