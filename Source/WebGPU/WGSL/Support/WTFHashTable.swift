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

// An emulation of WTF's hash functions (wtf/HashFunctions.h, wtf/text/RapidHash.h) and of the bucket layout of
// WTF::HashTable (wtf/HashTable.h), bit for bit, so that the C++ iteration order of a HashMap can be reproduced
// where it reaches the output. Every other C++ HashMap is a LookupMap, which cannot be iterated, or a SmallKeyMap, which
// iterates in insertion order only where the C++ order is not observable.

/// The WTF hash functions.
@_spi(Testing)
public enum WTFHash {
    private static let secret0: UInt64 = 0x2d35_8dcc_aa6c_78a5
    private static let secret1: UInt64 = 0x8bb8_4b93_962e_acc9
    private static let secret2: UInt64 = 0x4b33_a62e_d433_d4a3

    private static let flagCount: UInt32 = 8
    private static let maskHash: UInt32 = (1 << (32 - flagCount)) - 1

    /// StringImpl::hash() of a WTF::String with these UTF-16 code units (an 8-bit string hashes like its code units).
    @_spi(Testing)
    public static func string(_ codeUnits: [UInt16]) -> UInt32 {
        avoidZero(UInt32(truncatingIfNeeded: rapidhash(codeUnits)) & maskHash)
    }

    /// intHash(uint64_t); the uint32_t, uint16_t and uint8_t overloads zero-extend first.
    @_spi(Testing)
    public static func int(_ key: UInt64) -> UInt32 {
        let product = (key ^ secret0).multipliedFullWidth(by: key ^ secret1)
        return UInt32(truncatingIfNeeded: product.low ^ product.high)
    }

    /// pairIntHash, which DefaultHash<std::pair<unsigned, unsigned>> applies to the raw values.
    @_spi(Testing)
    public static func pairInt(_ key1: UInt32, _ key2: UInt32) -> UInt32 {
        let shortRandom1: UInt32 = 277_951_225
        let shortRandom2: UInt32 = 95_187_966
        let longRandom: UInt64 = 19_248_658_165_952_622

        let product = longRandom &* UInt64(shortRandom1 &* key1 &+ shortRandom2 &* key2)
        return UInt32(truncatingIfNeeded: product >> 32)
    }

    private static func avoidZero(_ hash: UInt32) -> UInt32 {
        if hash != 0 {
            return hash
        }
        return 0x8000_0000 >> flagCount
    }

    private static func rapidMul128(_ a: UInt64, _ b: UInt64) -> (low: UInt64, high: UInt64) {
        let result = a.multipliedFullWidth(by: b)
        return (result.low, result.high)
    }

    private static func rapidMix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let result = rapidMul128(a, b)
        return result.low ^ result.high
    }

    private static func rapidhashImpl(_ bytes: [UInt8]) -> UInt64 {
        func read64(_ offset: Int) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<8 {
                result |= UInt64(bytes[offset + i]) << (i * 8)
            }
            return result
        }
        func read32(_ offset: Int) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<4 {
                result |= UInt64(bytes[offset + i]) << (i * 8)
            }
            return result
        }
        func readSmall(_ offset: Int, _ k: Int) -> UInt64 {
            (UInt64(bytes[offset]) << 56) | (UInt64(bytes[offset + (k >> 1)]) << 32) | UInt64(bytes[offset + k - 1])
        }

        let len = bytes.count
        var seed = rapidMix(0 ^ secret0, secret1) ^ UInt64(len)
        var a: UInt64
        var b: UInt64

        if len <= 16 {
            if len >= 4 {
                let delta = len >= 8 ? 4 : 0
                a = (read32(0) << 32) | read32(len - 4)
                b = (read32(delta) << 32) | read32(len - 4 - delta)
            } else if len > 0 {
                a = readSmall(0, len)
                b = 0
            } else {
                a = 0
                b = 0
            }
        } else {
            var i = len
            var off = 0
            if i > 48 {
                var see1 = seed
                var see2 = seed
                repeat {
                    seed = rapidMix(read64(off) ^ secret0, read64(off + 8) ^ seed)
                    see1 = rapidMix(read64(off + 16) ^ secret1, read64(off + 24) ^ see1)
                    see2 = rapidMix(read64(off + 32) ^ secret2, read64(off + 40) ^ see2)
                    off += 48
                    i -= 48
                } while i >= 48
                seed ^= see1 ^ see2
            }
            if i > 16 {
                seed = rapidMix(read64(off) ^ secret2, read64(off + 8) ^ seed ^ secret1)
                if i > 32 {
                    seed = rapidMix(read64(off + 16) ^ secret2, read64(off + 24) ^ seed)
                }
            }

            a = read64(off + i - 16)
            b = read64(off + i - 8)
        }

        a ^= secret1
        b ^= seed
        let ab = rapidMul128(a, b)
        return rapidMix(ab.low ^ secret0 ^ UInt64(len), ab.high ^ secret1)
    }

    // Latin-1 content hashes one byte per character, so that an 8-bit string and the equivalent 16-bit string hash
    // alike; any other content hashes its raw little-endian bytes.
    private static func rapidhash(_ data: [UInt16]) -> UInt64 {
        if !data.allSatisfy({ $0 <= 0xFF }) {
            return rapidhashRawBytes(data)
        }
        return rapidhashOneBytePerChar(data)
    }

    private static func rapidhashOneBytePerChar(_ data: [UInt16]) -> UInt64 {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        for codeUnit in data {
            bytes.append(UInt8(truncatingIfNeeded: codeUnit))
        }
        return rapidhashImpl(bytes)
    }

    private static func rapidhashRawBytes(_ data: [UInt16]) -> UInt64 {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 2)
        for codeUnit in data {
            bytes.append(UInt8(truncatingIfNeeded: codeUnit))
            bytes.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
        }
        return rapidhashImpl(bytes)
    }
}

/// The HashFunctions template argument of a WTF::HashMap: the key type and its hash.
@_spi(Testing)
public protocol WTFHashFunctions {
    associatedtype Key: Equatable
    static func hash(_ key: Key) -> UInt32
}

/// IntHash<uint64_t>, which is also DefaultHash<uint64_t>.
@_spi(Testing)
public enum WTFIntHash: WTFHashFunctions {
    @_spi(Testing)
    public static func hash(_ key: UInt64) -> UInt32 {
        WTFHash.int(key)
    }
}

/// StringHash, on the UTF-16 code units of a WTF::String.
@_spi(Testing)
public enum WTFStringHash: WTFHashFunctions {
    @_spi(Testing)
    public static func hash(_ key: [UInt16]) -> UInt32 {
        WTFHash.string(key)
    }
}

/// HashTableSizePolicy (HashTableCapacityForSize) and the table sizes HashTable derives from it.
@_spi(Testing)
public enum WTFHashTableSizePolicy {
    /// KeyTraits::minimumTableSize.
    @_spi(Testing)
    public static let minimumTableSize = 8

    private static let smallMaxLoadNumerator: UInt64 = 3
    private static let smallMaxLoadDenominator: UInt64 = 4
    // Load-factor for large table is 50%.
    private static let largeMaxLoadNumerator: UInt64 = 1
    private static let largeMaxLoadDenominator: UInt64 = 2
    private static let maxSmallTableCapacity = 1024
    private static let minLoad = 6

    @_spi(Testing)
    public static func shouldExpand(_ keyAndDeleteCount: Int, _ tableSize: Int) -> Bool {
        if tableSize <= maxSmallTableCapacity {
            return UInt64(keyAndDeleteCount) * smallMaxLoadDenominator >= UInt64(tableSize) * smallMaxLoadNumerator
        }
        return UInt64(keyAndDeleteCount) * largeMaxLoadDenominator >= UInt64(tableSize) * largeMaxLoadNumerator
    }

    /// HashTable::computeBestTableSize: the size of a reserveInitialCapacity, shrinkToBestSize or copy-constructed table.
    @_spi(Testing)
    public static func computeBestTableSize(_ keyCount: Int) -> Int {
        var bestTableSize = 1
        while bestTableSize < keyCount {
            bestTableSize *= 2
        }
        let minLoadRatio = 1.0 / Double(minLoad)

        if shouldExpand(keyCount, bestTableSize) {
            bestTableSize *= 2
        }

        func aboveThresholdForEagerExpansion(_ loadFactor: Double, _ keyCount: Int, _ tableSize: Int) -> Bool {
            // Here is the rationale behind this calculation, using 3/4 load-factor.
            // With maxLoad at 3/4 and minLoad at 1/6, our average load is 11/24.
            // If we are getting half-way between 11/24 and 3/4, we double the size
            // to avoid being too close to loadMax and bring the ratio close to 11/24. This
            // give us a load in the bounds [9/24, 15/24).
            let maxLoadRatio = loadFactor
            let averageLoadRatio = (minLoadRatio + maxLoadRatio) / 2
            let halfWayBetweenAverageAndMaxLoadRatio = (averageLoadRatio + maxLoadRatio) / 2
            return Double(keyCount) >= Double(tableSize) * halfWayBetweenAverageAndMaxLoadRatio
        }

        if bestTableSize <= maxSmallTableCapacity {
            let smallLoadFactor = Double(smallMaxLoadNumerator) / Double(smallMaxLoadDenominator)
            if aboveThresholdForEagerExpansion(smallLoadFactor, keyCount, bestTableSize) {
                bestTableSize *= 2
            }
        } else {
            let largeLoadFactor = Double(largeMaxLoadNumerator) / Double(largeMaxLoadDenominator)
            if aboveThresholdForEagerExpansion(largeLoadFactor, keyCount, bestTableSize) {
                bestTableSize *= 2
            }
        }
        return bestTableSize > minimumTableSize ? bestTableSize : minimumTableSize
    }

    static func mustRehashInPlace(_ keyCount: Int, _ tableSize: Int) -> Bool {
        keyCount * minLoad < tableSize * 2
    }

    static func shouldShrink(_ keyCount: Int, _ tableSize: Int) -> Bool {
        keyCount * minLoad < tableSize && tableSize > minimumTableSize
    }
}

/// A value whose C++ copy constructor the emulation must run when a table holding it is copied.
///
/// The default `wtfCopy()` is the Swift copy, which is right for every value whose C++ copy does not depend on
/// hash layout; `WTFHashTable` itself re-lays out its buckets, so a copy of a map of maps re-lays out every level.
@_spi(Testing)
public protocol WTFCopyConstructible {
    func wtfCopy() -> Self
}

extension WTFCopyConstructible {
    @_spi(Testing)
    public func wtfCopy() -> Self {
        self
    }
}

@_spi(Testing)
extension Int: WTFCopyConstructible {}

@_spi(Testing)
extension UInt32: WTFCopyConstructible {}

@_spi(Testing)
extension UInt64: WTFCopyConstructible {}

// Vector's copy constructor copy-constructs the elements in order.
@_spi(Testing)
extension Array: WTFCopyConstructible where Element: WTFCopyConstructible {
    @_spi(Testing)
    public func wtfCopy() -> [Element] {
        var copy: [Element] = []
        copy.reserveCapacity(count)
        for element in self {
            copy.append(element.wtfCopy())
        }
        return copy
    }
}

/// WTF::HashMap<Key, Value, Hash> with the bucket layout of WTF::HashTable, so that it iterates in the C++ order.
///
/// Use it only where C++ iterates a HashMap and the order reaches the output; anywhere else use `LookupMap`.
/// A C++ copy (`auto x = map;`, `HashMap(const HashMap&)`) is `wtfCopy()`, which can change the order; a C++ move is a
/// Swift copy or move, which keeps the layout. The empty and deleted keys of the C++ key traits are ordinary keys.
@_spi(Testing)
public struct WTFHashTable<Hash: WTFHashFunctions, Value> {
    @_spi(Testing)
    public typealias Key = Hash.Key

    fileprivate enum Bucket {
        case empty
        case deleted
        case full(Key, Value)
    }

    private enum AddResult {
        case existingEntry(Int)
        case newEntry
    }

    // m_table; an empty array is an unallocated table.
    private var table: [Bucket] = []
    private var keyCount = 0
    private var deletedCount = 0

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { keyCount }

    @_spi(Testing)
    public var isEmpty: Bool { keyCount == 0 }

    /// The table size: 0 while unallocated, otherwise a power of two of at least `minimumTableSize`.
    @_spi(Testing)
    public var capacity: Int { table.count }

    @_spi(Testing)
    public func find(_ key: Key) -> Value? {
        guard let entry = lookup(key) else {
            return nil
        }
        return value(at: entry)
    }

    /// HashMap::get: C++ returns the mapped type's empty value for a missing key; write it out at the call site.
    @_spi(Testing)
    public func get(_ key: Key) -> Value? {
        find(key)
    }

    @_spi(Testing)
    public func contains(_ key: Key) -> Bool {
        lookup(key) != nil
    }

    /// HashMap::add: inserts when the key is absent and never overwrites; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func add(_ key: Key, _ value: Value) -> Bool {
        guard case .newEntry = addEntry(key, { value }) else {
            return false
        }
        return true
    }

    /// HashMap::set: like add, but overwrites the value of an existing key in place; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func set(_ key: Key, _ value: Value) -> Bool {
        guard case .existingEntry(let entry) = addEntry(key, { value }) else {
            return true
        }
        guard case .full(let existingKey, _) = table[entry] else {
            wgslFatal("HashMap::set found a bucket that is not full", cppSite: "wtf/HashMap.h:416")
        }
        table[entry] = .full(existingKey, value)
        return false
    }

    /// HashMap::ensure: calls `makeValue` only when the key is absent; returns the stored value.
    @_spi(Testing)
    public mutating func ensure<E: Error>(_ key: Key, _ makeValue: () throws(E) -> Value) throws(E) -> Value {
        var newValue: Value?
        let result = try addEntry(key) { () throws(E) -> Value in
            let value = try makeValue()
            newValue = value
            return value
        }
        switch result {
        case .existingEntry(let entry):
            return value(at: entry)
        case .newEntry:
            guard let newValue else {
                wgslFatal("HashMap::ensure added an entry without making its value", cppSite: "wtf/HashMap.h:432")
            }
            return newValue
        }
    }

    /// `map.find(key)->value` mutated in place; nil (and `body` is not called) when the key is absent.
    @_spi(Testing)
    @discardableResult
    public mutating func modify<R>(_ key: Key, _ body: (inout Value) -> R) -> R? {
        guard let entry = lookup(key) else {
            return nil
        }
        return modifyValue(at: entry, body)
    }

    /// `map.add(key, value).iterator->value` mutated in place: the same layout as the C++ add followed by the mutation.
    @_spi(Testing)
    @discardableResult
    public mutating func modify<R>(_ key: Key, default makeValue: @autoclosure () -> Value, _ body: (inout Value) -> R) -> R {
        if let entry = lookup(key) {
            return modifyValue(at: entry, body)
        }
        var value = makeValue()
        let result = body(&value)
        _ = addEntry(key) { value }
        return result
    }

    /// HashMap::remove; returns whether the key was present.
    @_spi(Testing)
    @discardableResult
    public mutating func remove(_ key: Key) -> Bool {
        guard let entry = lookup(key) else {
            return false
        }
        remove(at: entry)
        return true
    }

    /// HashMap::take: C++ returns the mapped type's empty value for a missing key; write it out at the call site.
    @_spi(Testing)
    public mutating func take(_ key: Key) -> Value? {
        guard let entry = lookup(key) else {
            return nil
        }
        let result = value(at: entry)
        remove(at: entry)
        return result
    }

    /// HashTable::removeIf: visits the buckets from the last to the first; returns whether anything was removed.
    @_spi(Testing)
    @discardableResult
    public mutating func removeIf(_ functor: (Key, Value) -> Bool) -> Bool {
        if table.isEmpty {
            return false
        }

        var removedBucketCount = 0
        var i = table.count
        while i > 0 {
            i -= 1
            guard case .full(let key, let value) = table[i], functor(key, value) else {
                continue
            }
            table[i] = .deleted
            removedBucketCount += 1
        }
        if removedBucketCount != 0 {
            deletedCount += removedBucketCount
            keyCount -= removedBucketCount
        }

        if WTFHashTableSizePolicy.shouldShrink(keyCount, table.count) {
            shrinkToBestSize()
        }
        return removedBucketCount != 0
    }

    /// HashTable::clear frees the table: the next add starts again from `minimumTableSize`.
    @_spi(Testing)
    public mutating func clear() {
        table = []
        keyCount = 0
        deletedCount = 0
    }

    @_spi(Testing)
    public mutating func reserveInitialCapacity(_ keyCount: Int) {
        assert(table.isEmpty)

        let newTableSize = WTFHashTableSizePolicy.computeBestTableSize(keyCount)

        table = Array(repeating: .empty, count: newTableSize)
        deletedCount = 0
        self.keyCount = 0
    }

    /// `for (auto& [key, value] : map)` with the values mutated in place, in iteration order.
    @_spi(Testing)
    public mutating func modifyEach(_ body: (Key, inout Value) -> Void) {
        var i = 0
        while i < table.count {
            if case .full(let key, _) = table[i] {
                modifyValue(at: i) { body(key, &$0) }
            }
            i += 1
        }
    }

    // HashTable::lookup.
    private func lookup(_ key: Key) -> Int? {
        if table.isEmpty {
            return nil
        }

        let sizeMask = table.count - 1
        var i = Int(truncatingIfNeeded: Hash.hash(key)) & sizeMask
        var probeCount = 0

        while true {
            switch table[i] {
            case .empty:
                return nil
            case .deleted:
                break
            case .full(let entryKey, _):
                if entryKey == key {
                    return i
                }
            }
            probeCount += 1
            i = (i + probeCount) & sizeMask
        }
    }

    // HashTable::add(key, functor): the new entry goes into the last deleted bucket of the probe sequence, if any,
    // otherwise into the empty bucket that ends it; the table expands after the insertion.
    private mutating func addEntry<E: Error>(_ key: Key, _ functor: () throws(E) -> Value) throws(E) -> AddResult {
        if table.isEmpty {
            expand()
        }

        let sizeMask = table.count - 1
        var i = Int(truncatingIfNeeded: Hash.hash(key)) & sizeMask
        var probeCount = 0

        var deletedEntry: Int?
        probing: while true {
            switch table[i] {
            case .empty:
                break probing
            case .deleted:
                deletedEntry = i
            case .full(let entryKey, _):
                if entryKey == key {
                    return .existingEntry(i)
                }
            }
            probeCount += 1
            i = (i + probeCount) & sizeMask
        }

        // DEV-05: no validateKey; every key, including the C++ traits' empty and deleted values, is an ordinary key.
        let value = try functor()
        var entry = i
        if let deletedEntry {
            entry = deletedEntry
            deletedCount -= 1
        }

        table[entry] = .full(key, value)
        keyCount += 1

        if WTFHashTableSizePolicy.shouldExpand(keyCount + deletedCount, table.count) {
            expand()
        }
        return .newEntry
    }

    // HashTable::remove(ValueType*).
    private mutating func remove(at entry: Int) {
        table[entry] = .deleted
        deletedCount += 1
        keyCount -= 1

        if WTFHashTableSizePolicy.shouldShrink(keyCount, table.count) {
            shrink()
        }
    }

    private mutating func expand() {
        let oldSize = table.count
        let newSize: Int
        if oldSize == 0 {
            newSize = WTFHashTableSizePolicy.minimumTableSize
        } else if WTFHashTableSizePolicy.mustRehashInPlace(keyCount, oldSize) {
            newSize = oldSize
        } else {
            newSize = oldSize * 2
        }

        rehash(newSize)
    }

    private mutating func shrink() {
        rehash(table.count / 2)
    }

    private mutating func shrinkToBestSize() {
        rehash(WTFHashTableSizePolicy.computeBestTableSize(keyCount))
    }

    // HashTable::rehash: the full buckets, in bucket order, each at the first empty bucket of its probe sequence.
    private mutating func rehash(_ newTableSize: Int) {
        let oldTable = table
        table = Array(repeating: .empty, count: newTableSize)
        deletedCount = 0

        for bucket in oldTable {
            if case .full(let key, let value) = bucket {
                reinsert(key, value)
            }
        }
    }

    // HashTable::reinsert, through lookupForReinsert.
    private mutating func reinsert(_ key: Key, _ value: Value) {
        let sizeMask = table.count - 1
        var i = Int(truncatingIfNeeded: Hash.hash(key)) & sizeMask
        var probeCount = 0

        while true {
            if case .empty = table[i] {
                table[i] = .full(key, value)
                return
            }
            probeCount += 1
            i = (i + probeCount) & sizeMask
        }
    }

    private func value(at entry: Int) -> Value {
        guard case .full(_, let value) = table[entry] else {
            wgslFatal("a hash table entry is not a full bucket", cppSite: "wtf/HashTable.h:665")
        }
        return value
    }

    // Moves the value out of its bucket while `body` runs, so that `body` mutates a uniquely referenced value.
    private mutating func modifyValue<R>(at entry: Int, _ body: (inout Value) -> R) -> R {
        guard case .full(let key, var value) = table[entry] else {
            wgslFatal("a hash table entry is not a full bucket", cppSite: "wtf/HashTable.h:665")
        }
        table[entry] = .empty
        let result = body(&value)
        table[entry] = .full(key, value)
        return result
    }
}

extension WTFHashTable: WTFCopyConstructible where Value: WTFCopyConstructible {
    /// HashTable(const HashTable&), which can iterate in a different order from the original.
    ///
    /// The copy has `computeBestTableSize(count)` buckets and gets every entry, in iteration order, at the first empty
    /// bucket of its probe sequence, with its value copy-constructed.
    @_spi(Testing)
    public func wtfCopy() -> WTFHashTable {
        var copy = WTFHashTable()
        if keyCount == 0 {
            return copy
        }

        let bestTableSize = WTFHashTableSizePolicy.computeBestTableSize(keyCount)
        copy.table = Array(repeating: .empty, count: bestTableSize)
        copy.keyCount = keyCount
        copy.deletedCount = 0

        for bucket in table {
            if case .full(let key, let value) = bucket {
                copy.reinsert(key, value.wtfCopy())
            }
        }
        return copy
    }
}

extension WTFHashTable: Sequence {
    /// Iterates in bucket order, skipping empty and deleted buckets (HashTableConstIterator::skipEmptyBuckets).
    @_spi(Testing)
    public struct Iterator: IteratorProtocol {
        private let table: [Bucket]
        private var index = 0

        fileprivate init(_ table: [Bucket]) {
            self.table = table
        }

        @_spi(Testing)
        public mutating func next() -> (key: Key, value: Value)? {
            while index < table.count {
                let bucket = table[index]
                index += 1
                if case .full(let key, let value) = bucket {
                    return (key, value)
                }
            }
            return nil
        }
    }

    @_spi(Testing)
    public func makeIterator() -> Iterator {
        Iterator(table)
    }

    @_spi(Testing)
    public var underestimatedCount: Int { keyCount }
}

extension WTFHashTable: Sendable where Hash.Key: Sendable, Value: Sendable {}

extension WTFHashTable.Bucket: Sendable where Hash.Key: Sendable, Value: Sendable {}

/// GlobalVariableRewriter.cpp's `IndexMap<Value>`: HashMap<uint64_t, Value, IntHash<uint64_t>,
/// UnsignedWithZeroKeyHashTraits<uint64_t>>.
@_spi(Testing)
public typealias WTFIndexMap<Value> = WTFHashTable<WTFIntHash, Value>

/// `for (auto& [key, value] : map)` over a `WTFHashTable`, in the C++ iteration order.
@_spi(Testing)
@inline(__always)
public func forEachElement<Hash, Value, E: Error>(
    _ hashTable: WTFHashTable<Hash, Value>,
    _ body: (Hash.Key, Value) throws(E) -> Void
) throws(E) {
    var iterator = hashTable.makeIterator()
    while let entry = iterator.next() {
        try body(entry.key, entry.value)
    }
}
