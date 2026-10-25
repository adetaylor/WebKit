// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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

/// A C++ HashMap that is only searched: it has no `Sequence` conformance, so iterating it does not compile.
///
/// The C++ iteration order is the hash layout; where that order reaches the output, use `WTFHashTable`.
/// The methods keep the HashMap names.
///
/// A map of up to `linearLimit` keys is an array that a lookup scans, which hashes nothing (the prepare passes look every
/// entry point's name up in a map of the one or two being prepared); a larger one is a `Dictionary`.
@_spi(Testing)
public struct LookupMap<Key: Hashable, Value> {
    private var small: [(key: Key, value: Value)] = []
    private var storage: [Key: Value] = [:]
    private var isLarge = false

    private static var linearLimit: Int { 8 }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { isLarge ? storage.count : small.count }

    @_spi(Testing)
    public var isEmpty: Bool { count == 0 }

    @inline(__always)
    private func smallIndex(_ key: Key) -> Int? {
        var index = 0
        while index < small.count {
            if small[index].key == key {
                return index
            }
            index += 1
        }
        return nil
    }

    private mutating func becomeLarge() {
        storage.reserveCapacity(2 * Self.linearLimit)
        var index = 0
        while index < small.count {
            storage[small[index].key] = small[index].value
            index += 1
        }
        small = []
        isLarge = true
    }

    /// HashMap::add: inserts when the key is absent and never overwrites; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func add(_ key: Key, _ value: Value) -> Bool {
        if !isLarge {
            guard smallIndex(key) == nil else {
                return false
            }
            guard small.count == Self.linearLimit else {
                small.append((key, value))
                return true
            }
            becomeLarge()
        }
        guard storage.index(forKey: key) == nil else {
            return false
        }
        storage[key] = value
        return true
    }

    /// HashMap::set: inserts or overwrites; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func set(_ key: Key, _ value: Value) -> Bool {
        if !isLarge {
            if let index = smallIndex(key) {
                small[index].value = value
                return false
            }
            guard small.count == Self.linearLimit else {
                small.append((key, value))
                return true
            }
            becomeLarge()
        }
        return storage.updateValue(value, forKey: key) == nil
    }

    /// HashMap::get: C++ returns the mapped type's empty value for a missing key; write it out at the call site.
    @_spi(Testing)
    public func get(_ key: Key) -> Value? {
        find(key)
    }

    /// `map.find(key)`: nil where C++ gets `map.end()`.
    @_spi(Testing)
    public func find(_ key: Key) -> Value? {
        if isLarge {
            return storage[key]
        }
        guard let index = smallIndex(key) else {
            return nil
        }
        return small[index].value
    }

    @_spi(Testing)
    public func contains(_ key: Key) -> Bool {
        isLarge ? storage.index(forKey: key) != nil : smallIndex(key) != nil
    }

    /// HashMap::remove; returns whether the key was present.
    @_spi(Testing)
    @discardableResult
    public mutating func remove(_ key: Key) -> Bool {
        take(key) != nil
    }

    /// HashMap::take: C++ returns the mapped type's empty value for a missing key; write it out at the call site.
    @_spi(Testing)
    public mutating func take(_ key: Key) -> Value? {
        if isLarge {
            return storage.removeValue(forKey: key)
        }
        guard let index = smallIndex(key) else {
            return nil
        }
        return small.remove(at: index).value
    }

    /// HashMap::ensure: calls `makeValue` only when the key is absent; returns the stored value.
    @_spi(Testing)
    public mutating func ensure<E: Error>(_ key: Key, _ makeValue: () throws(E) -> Value) throws(E) -> Value {
        if let value = find(key) {
            return value
        }
        let value = try makeValue()
        add(key, value)
        return value
    }

    /// `map.find(key)->value` mutated in place; nil (and `body` is not called) when the key is absent.
    @_spi(Testing)
    @discardableResult
    public mutating func modify<R>(_ key: Key, _ body: (inout Value) -> R) -> R? {
        if !isLarge {
            guard let index = smallIndex(key) else {
                return nil
            }
            return body(&small[index].value)
        }
        guard let index = storage.index(forKey: key) else {
            return nil
        }
        return body(&storage.values[index])
    }

    /// `map.add(key, value).iterator->value` (or `ensure`) mutated in place.
    @_spi(Testing)
    @discardableResult
    public mutating func modify<R>(_ key: Key, default makeValue: @autoclosure () -> Value, _ body: (inout Value) -> R) -> R {
        if !isLarge {
            if let index = smallIndex(key) {
                return body(&small[index].value)
            }
            if small.count < Self.linearLimit {
                small.append((key, makeValue()))
                return body(&small[small.count - 1].value)
            }
            becomeLarge()
        }
        return body(&storage[key, default: makeValue()])
    }

    @_spi(Testing)
    public mutating func clear() {
        small = []
        storage.removeAll()
        isLarge = false
    }

    @_spi(Testing)
    public mutating func reserveInitialCapacity(_ keyCount: Int) {
        if keyCount > Self.linearLimit {
            if !isLarge {
                becomeLarge()
            }
            storage.reserveCapacity(keyCount)
        } else if !isLarge {
            small.reserveCapacity(keyCount)
        }
    }
}

extension LookupMap: Equatable where Value: Equatable {
    /// HashMap::operator==: the same keys with equal values, whichever representation either map has.
    @_spi(Testing)
    public static func == (lhs: LookupMap, rhs: LookupMap) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        if lhs.isLarge && rhs.isLarge {
            return lhs.storage == rhs.storage
        }
        let (scanned, other) = lhs.isLarge ? (rhs, lhs) : (lhs, rhs)
        var index = 0
        while index < scanned.small.count {
            guard other.find(scanned.small[index].key) == scanned.small[index].value else {
                return false
            }
            index += 1
        }
        return true
    }
}

extension LookupMap: Sendable where Key: Sendable, Value: Sendable {}

/// A C++ HashSet that is only searched: it has no `Sequence` conformance, so iterating it does not compile.
@_spi(Testing)
public struct LookupSet<Element: Hashable> {
    private var storage: Set<Element> = []

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { storage.count }

    @_spi(Testing)
    public var isEmpty: Bool { storage.isEmpty }

    /// HashSet::add; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func add(_ element: Element) -> Bool {
        storage.insert(element).inserted
    }

    /// HashSet::addAll.
    @_spi(Testing)
    public mutating func addAll(_ other: LookupSet) {
        storage.formUnion(other.storage)
    }

    /// HashSet::addAll over a Vector.
    @_spi(Testing)
    public mutating func addAll(_ elements: [Element]) {
        storage.formUnion(elements)
    }

    @_spi(Testing)
    public func contains(_ element: Element) -> Bool {
        storage.contains(element)
    }

    /// HashSet::remove; returns whether the element was present.
    @_spi(Testing)
    @discardableResult
    public mutating func remove(_ element: Element) -> Bool {
        storage.remove(element) != nil
    }

    @_spi(Testing)
    public mutating func clear() {
        storage.removeAll()
    }

    @_spi(Testing)
    public mutating func reserveInitialCapacity(_ count: Int) {
        storage.reserveCapacity(count)
    }
}

extension LookupSet: Equatable {}

extension LookupSet: Sendable where Element: Sendable {}

/// SipHash-1-3 keyed with two words drawn from the stdlib Hasher, which is seeded per process.
///
/// Inlined, where Hasher is a call per combine and per finalize. The hash of `SymbolTable` and `SmallKeyMap`.
struct KeyedHasher {
    private var v0: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64

    @inline(__always)
    init() {
        self.init(key: keyedHasherKey)
    }

    @inline(__always)
    init(key: KeyedHasherKey) {
        v0 = key.k0 ^ 0x736f_6d65_7073_6575
        v1 = key.k1 ^ 0x646f_7261_6e64_6f6d
        v2 = key.k0 ^ 0x6c79_6765_6e65_7261
        v3 = key.k1 ^ 0x7465_6462_7974_6573
    }

    @inline(__always)
    mutating func combine(_ word: UInt64) {
        v3 ^= word
        round()
        v0 ^= word
    }

    @inline(__always)
    private mutating func round() {
        v0 &+= v1
        v1 = v1 &<< 13 | v1 &>> 51
        v1 ^= v0
        v0 = v0 &<< 32 | v0 &>> 32
        v2 &+= v3
        v3 = v3 &<< 16 | v3 &>> 48
        v3 ^= v2
        v0 &+= v3
        v3 = v3 &<< 21 | v3 &>> 43
        v3 ^= v0
        v2 &+= v1
        v1 = v1 &<< 17 | v1 &>> 47
        v1 ^= v2
        v2 = v2 &<< 32 | v2 &>> 32
    }

    @inline(__always)
    mutating func finalize() -> Int {
        v2 ^= 0xff
        round()
        round()
        round()
        return Int(truncatingIfNeeded: v0 ^ v1 ^ v2 ^ v3)
    }

    /// Text of `count` code units, combined four to a word: `tail` holds the last `count % 4`, and its high 16 bits, which
    /// they leave clear, take the count (modulo 2^16, which with the number of words determines it), as SipHash's last
    /// block takes the length.
    @inline(__always)
    mutating func finalize(tail: UInt64, count: Int) -> Int {
        combine(tail | UInt64(truncatingIfNeeded: count) &<< 48)
        return finalize()
    }

    /// The hash of one word.
    @inline(__always)
    static func hash(_ word: UInt64, key: KeyedHasherKey) -> Int {
        var hasher = KeyedHasher(key: key)
        hasher.combine(word)
        return hasher.finalize()
    }
}

/// The key of `KeyedHasher`; `keyedHasherKey` is the process's.
struct KeyedHasherKey: Sendable {
    let k0: UInt64
    let k1: UInt64

    static var zero: KeyedHasherKey { KeyedHasherKey(k0: 0, k1: 0) }

    private init(k0: UInt64, k1: UInt64) {
        self.k0 = k0
        self.k1 = k1
    }

    init() {
        var first = Hasher()
        first.combine(UInt64(0x5747_534c_5379_6d30))
        var second = Hasher()
        second.combine(UInt64(0x5747_534c_5379_6d31))
        k0 = UInt64(truncatingIfNeeded: first.finalize())
        k1 = UInt64(truncatingIfNeeded: second.finalize())
    }
}

private let keyedHasherKey = KeyedHasherKey()

/// A key of `SmallKeyMap`: a symbol, an ID, or a tuple of small integers packed into 64 bits.
@_spi(Testing)
public protocol SmallKey: Equatable, BitwiseCopyable {
    /// Distinct keys have distinct bits.
    var smallKeyBits: UInt64 { get }
}

extension Symbol: SmallKey {
    @_spi(Testing)
    public var smallKeyBits: UInt64 { UInt64(truncatingIfNeeded: index) }
}

/// A C++ HashMap keyed by identifier text that is only searched, for per-node paths: a `LookupMap<Symbol, Value>` that
/// scans while it is small.
@_spi(Testing)
public typealias SymbolMap<Value> = SmallKeyMap<Symbol, Value>

/// A C++ HashMap or HashSet that is only searched, for per-node paths, keyed by symbols or small integers.
///
/// A small map has no table: a lookup scans the entries. Past `linearLimit` entries the index table is open addressing
/// over a `KeyedHasher` hash of the key, as in `SymbolTable`: the source chooses which
/// symbols a map holds and the pairs a composite key packs (GlobalSorting's edges, AliasAnalysis's memory locations), so
/// with an unkeyed mix crafted keys could fill one probe cluster. Entries are kept in insertion order, which only
/// `orderedKeys` and `forEachEntry` expose, for callers whose C++ loops do not depend on the hash order; the seed is
/// never observable.
@_spi(Testing)
public struct SmallKeyMap<Key: SmallKey, Value> {
    fileprivate struct Entry {
        let key: Key
        // The key's hash, computed when the table is first built and stored so that a rebuild or `addAll` hashes
        // nothing.
        var hash: UInt32
        var value: Value
    }

    private var entries: [Entry] = []
    // 0 = empty, else a position in `entries` + 1; empty while there are at most `linearLimit` entries.
    private var table: [UInt32] = []
    // `keyedHasherKey`, read when the table is first built: a lookup that read the lazily initialised global would make
    // every caller retain the map's arrays around it.
    private var hashKey = KeyedHasherKey.zero

    private static var linearLimit: Int { 8 }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { entries.count }

    @_spi(Testing)
    public var isEmpty: Bool { entries.isEmpty }

    /// The keys in insertion order.
    @_spi(Testing)
    public var orderedKeys: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(entries.count)
        var index = 0
        while index < entries.count {
            keys.append(entries[index].key)
            index += 1
        }
        return keys
    }

    /// HashMap::add: inserts when the key is absent and never overwrites; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func add(_ key: Key, _ value: Value) -> Bool {
        add(key, value, table.isEmpty ? 0 : hash(of: key))
    }

    /// HashMap::set: inserts or overwrites; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func set(_ key: Key, _ value: Value) -> Bool {
        let keyHash = table.isEmpty ? 0 : hash(of: key)
        let (position, slot) = probe(key, keyHash)
        if let position {
            entries[position].value = value
            return false
        }
        append(key, value, keyHash, slot)
        return true
    }

    /// `add` of every entry of `other`, in its insertion order.
    @_spi(Testing)
    public mutating func addAll(_ other: SmallKeyMap) {
        let isHashed = !other.table.isEmpty
        var index = 0
        while index < other.entries.count {
            let entry = other.entries[index]
            add(entry.key, entry.value, table.isEmpty ? 0 : isHashed ? entry.hash : hash(of: entry.key))
            index += 1
        }
    }

    /// HashMap::get: C++ returns the mapped type's empty value for a missing key; write it out at the call site.
    @_spi(Testing)
    public func get(_ key: Key) -> Value? {
        find(key)
    }

    /// `map.find(key)`: nil where C++ gets `map.end()`.
    @_spi(Testing)
    public func find(_ key: Key) -> Value? {
        guard let position = probe(key, table.isEmpty ? 0 : hash(of: key)).position else {
            return nil
        }
        return entries[position].value
    }

    @_spi(Testing)
    public func contains(_ key: Key) -> Bool {
        probe(key, table.isEmpty ? 0 : hash(of: key)).position != nil
    }

    /// Calls `body` with every entry, in insertion order.
    @_spi(Testing)
    @inline(__always)
    public func forEachEntry(_ body: (Key, Value) -> Void) {
        var index = 0
        while index < entries.count {
            body(entries[index].key, entries[index].value)
            index += 1
        }
    }

    @_spi(Testing)
    public mutating func clear() {
        entries = []
        table = []
    }

    /// `clear()` for a map that is filled again: the entries keep their storage.
    @_spi(Testing)
    public mutating func removeAllKeepingCapacity() {
        if !entries.isEmpty {
            entries.removeAll(keepingCapacity: true)
        }
        table = []
    }

    @_spi(Testing)
    public mutating func reserveInitialCapacity(_ keyCount: Int) {
        if keyCount > entries.capacity {
            entries.reserveCapacity(keyCount)
        }
    }

    // `hash` is the key's hash when the map has a table (ignored while it scans).
    @inline(__always)
    @discardableResult
    private mutating func add(_ key: Key, _ value: Value, _ hash: UInt32) -> Bool {
        let (position, slot) = probe(key, hash)
        guard position == nil else {
            return false
        }
        append(key, value, hash, slot)
        return true
    }

    // The key's position, else the empty slot where its probe ended (unused while the map scans).
    @inline(__always)
    private func probe(_ key: Key, _ hash: UInt32) -> (position: Int?, slot: Int) {
        if table.isEmpty {
            var index = 0
            while index < entries.count {
                if entries[index].key == key {
                    return (index, 0)
                }
                index += 1
            }
            return (nil, 0)
        }
        let mask = table.count - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        while true {
            let entry = Int(table[slot])
            if entry == 0 {
                return (nil, slot)
            }
            if entries[entry - 1].key == key {
                return (entry - 1, slot)
            }
            slot = (slot + 1) & mask
        }
    }

    private mutating func append(_ key: Key, _ value: Value, _ hash: UInt32, _ slot: Int) {
        if entries.capacity == 0 {
            entries.reserveCapacity(Self.linearLimit / 2)
        }
        entries.append(Entry(key: key, hash: hash, value: value))
        if !table.isEmpty && 2 * entries.count <= table.count {
            table[slot] = UInt32(truncatingIfNeeded: entries.count)
        } else if entries.count > Self.linearLimit {
            rebuildTable(table.isEmpty ? Self.firstTableSize(entries.capacity) : 2 * table.count)
        }
    }

    // The first table holds the entries' capacity, which `reserveInitialCapacity` sets for a map whose size the caller
    // knows, so that it is not rebuilt at each doubling on the way.
    private static func firstTableSize(_ capacity: Int) -> Int {
        var size = 4 * linearLimit
        while size < 2 * capacity {
            size *= 2
        }
        return size
    }

    private mutating func rebuildTable(_ size: Int) {
        var position = 0
        if table.isEmpty {
            hashKey = keyedHasherKey
            while position < entries.count {
                entries[position].hash = hash(of: entries[position].key)
                position += 1
            }
        }
        table = Array(repeatElement(0, count: size))
        let mask = size - 1
        position = 0
        while position < entries.count {
            var slot = Int(truncatingIfNeeded: entries[position].hash) & mask
            while table[slot] != 0 {
                slot = (slot + 1) & mask
            }
            table[slot] = UInt32(truncatingIfNeeded: position + 1)
            position += 1
        }
    }

    @inline(__always)
    private func hash(of key: Key) -> UInt32 {
        UInt32(truncatingIfNeeded: KeyedHasher.hash(key.smallKeyBits, key: hashKey))
    }

    /// The longest run of occupied slots, which bounds the probes of any lookup; 0 while the map scans.
    @_spi(Testing)
    public func longestProbeRun() -> Int {
        var longest = 0
        var run = 0
        var index = 0
        while index < 2 * table.count {
            if table[index & (table.count - 1)] == 0 {
                run = 0
            } else {
                run += 1
                if run > longest {
                    longest = run
                }
            }
            index += 1
        }
        return longest
    }
}

extension SmallKeyMap: Equatable where Value: Equatable {
    /// HashMap::operator==: the same keys with equal values, whatever the insertion order.
    @_spi(Testing)
    public static func == (lhs: SmallKeyMap, rhs: SmallKeyMap) -> Bool {
        guard lhs.entries.count == rhs.entries.count else {
            return false
        }
        var index = 0
        while index < lhs.entries.count {
            guard rhs.find(lhs.entries[index].key) == lhs.entries[index].value else {
                return false
            }
            index += 1
        }
        return true
    }
}

extension SmallKeyMap: Sendable where Key: Sendable, Value: Sendable {}

extension SmallKeyMap.Entry: Sendable where Key: Sendable, Value: Sendable {}

/// ListHashSet<T>: iterates in insertion order.
///
/// `add` appends only an element that is not already present (re-adding never moves it), `remove` keeps the order
/// of the others, and a copy keeps the order. Iterate with `forEachElement` (or `for … in` outside per-node code).
@_spi(Testing)
public struct OrderedSet<Element: Hashable> {
    // The elements in insertion order, nil where one was removed; slots[..<head] are nil and the last slot is not.
    private var slots: [Element?] = []
    private var indices: [Element: Int] = [:]
    private var head = 0

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { indices.count }

    @_spi(Testing)
    public var isEmpty: Bool { indices.isEmpty }

    /// ListHashSet::first: nil where C++ dereferences the null head of an empty set.
    @_spi(Testing)
    public var first: Element? {
        guard head < slots.count else {
            return nil
        }
        return slots[head]
    }

    /// ListHashSet::last: nil where C++ dereferences the null tail of an empty set.
    @_spi(Testing)
    public var last: Element? {
        guard let lastSlot = slots.last else {
            return nil
        }
        return lastSlot
    }

    /// The elements in iteration order.
    @_spi(Testing)
    public var elements: [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        var index = head
        while index < slots.count {
            if let element = slots[index] {
                result.append(element)
            }
            index += 1
        }
        return result
    }

    @_spi(Testing)
    public func contains(_ element: Element) -> Bool {
        indices.index(forKey: element) != nil
    }

    /// ListHashSet::add: appends the element when it is absent; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func add(_ element: Element) -> Bool {
        guard indices.index(forKey: element) == nil else {
            return false
        }
        indices[element] = slots.count
        slots.append(element)
        return true
    }

    /// ListHashSet::remove: unlinks the element; returns whether it was present.
    @_spi(Testing)
    @discardableResult
    public mutating func remove(_ element: Element) -> Bool {
        guard let index = indices.removeValue(forKey: element) else {
            return false
        }
        if indices.isEmpty {
            slots.removeAll(keepingCapacity: true)
            head = 0
            return true
        }

        slots[index] = nil
        while let lastSlot = slots.last, lastSlot == nil {
            slots.removeLast()
        }
        while slots[head] == nil {
            head += 1
        }
        if slots.count - indices.count > Self.compactionThreshold(indices.count) {
            compact()
        }
        return true
    }

    @_spi(Testing)
    public mutating func clear() {
        slots.removeAll()
        indices.removeAll()
        head = 0
    }

    // Removed slots are dropped once they outnumber the elements, so every operation stays amortised O(1).
    private static func compactionThreshold(_ count: Int) -> Int {
        count > 16 ? count : 16
    }

    private mutating func compact() {
        var compacted: [Element?] = []
        compacted.reserveCapacity(indices.count)
        var index = head
        while index < slots.count {
            if let element = slots[index] {
                indices[element] = compacted.count
                compacted.append(element)
            }
            index += 1
        }
        slots = compacted
        head = 0
    }
}

extension OrderedSet: Sequence {
    /// Iterates in insertion order.
    @_spi(Testing)
    public struct Iterator: IteratorProtocol {
        private let slots: [Element?]
        private var index: Int

        fileprivate init(_ slots: [Element?], _ head: Int) {
            self.slots = slots
            self.index = head
        }

        @_spi(Testing)
        public mutating func next() -> Element? {
            while index < slots.count {
                let slot = slots[index]
                index += 1
                if let slot {
                    return slot
                }
            }
            return nil
        }
    }

    @_spi(Testing)
    public func makeIterator() -> Iterator {
        Iterator(slots, head)
    }

    @_spi(Testing)
    public var underestimatedCount: Int { count }
}

extension OrderedSet: Sendable where Element: Sendable {}

/// `for (auto& element : elements)` without IndexingIterator.
///
/// At -Onone the iterator calls the generic Collection.subscript read coroutine, whose frame is heap-allocated: one
/// malloc per iteration. Hot per-node loops (visitors, writers) use this instead; -O code is identical either way.
@_spi(Testing)
@inline(__always)
public func forEachElement<Element, E: Error>(_ elements: [Element], _ body: (Element) throws(E) -> Void) throws(E) {
    var index = 0
    let count = elements.count
    while index < count {
        try body(elements[index])
        index += 1
    }
}

/// `for (auto& element : set)` over a ListHashSet, in insertion order.
@_spi(Testing)
@inline(__always)
public func forEachElement<Element, E: Error>(_ set: OrderedSet<Element>, _ body: (Element) throws(E) -> Void) throws(E) {
    var iterator = set.makeIterator()
    while let element = iterator.next() {
        try body(element)
    }
}

extension Array where Element: Equatable {
    /// Vector::appendIfNotContains: a linear search, then an append; returns whether the value was appended.
    @_spi(Testing)
    @discardableResult
    public mutating func appendIfNotContains(_ value: Element) -> Bool {
        if contains(value) {
            return false
        }
        append(value)
        return true
    }
}
