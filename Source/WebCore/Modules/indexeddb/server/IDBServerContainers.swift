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
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.ClientOrigin
internal import WebCore_Private.Core.IDBConnectionToClientDelegate
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
internal import WebCore_Private.Core.IDBDatabaseIdentifier
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBGetAllResult
internal import WebCore_Private.Core.IDBGetResult
internal import WebCore_Private.Core.IDBIndexIdentifier
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBOpenRequestData
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.SwiftIDBTypes

// The containers the IndexedDB server's types keep their entries in, and the identifiers' hashing as their keys.

/// A database's pending transactions in scheduling order, a deque: the scheduler takes from the front and puts
/// deferred transactions back there, each in constant time.
struct IDBPendingTransactionQueue: Sequence, ExpressibleByArrayLiteral {
    private var storage: [IDBEntitySerial]
    private var head = 0

    init(arrayLiteral serials: IDBEntitySerial...) {
        storage = serials
    }

    var isEmpty: Bool {
        head == storage.count
    }

    mutating func append(_ serial: IDBEntitySerial) {
        storage.append(serial)
    }

    mutating func takeFirst() -> IDBEntitySerial? {
        guard head < storage.count else {
            return nil
        }
        let first = storage[head]
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 32 && head * 2 >= storage.count {
            // The taken front is dropped once it is half the storage, so a queue that is never empty stays bounded.
            storage.removeFirst(head)
            head = 0
        }
        return first
    }

    mutating func prepend(contentsOf serials: [IDBEntitySerial]) {
        if serials.count <= head {
            head -= serials.count
            storage.replaceSubrange(head..<(head + serials.count), with: serials)
        } else {
            storage.replaceSubrange(0..<head, with: serials)
            head = 0
        }
    }

    func makeIterator() -> ArraySlice<IDBEntitySerial>.Iterator {
        storage[head...].makeIterator()
    }
}

// MARK: - Identifiers as keys

/// WTF's 64-bit integer hash (`intHash`), for the keys of the server's per-request lookups.
///
/// Identifiers hash with WTF's integer hash instead of SipHash; the dictionary's seed is mixed in first.
func idbServerIntHash(_ value: UInt64) -> UInt64 {
    var key = value
    key &+= ~(key << 32)
    key ^= key >> 22
    key &+= ~(key << 13)
    key ^= key >> 8
    key &+= key << 3
    key ^= key >> 15
    key &+= ~(key << 27)
    key ^= key >> 31
    return key
}

/// A `UInt64` key that hashes with `idbServerIntHash`.
struct IDBServerIntegerKey: Hashable {
    let value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(value)
    }

    // swift-format-ignore: NoLeadingUnderscores
    /// The hash a native dictionary asks for, without the default `Hasher` (SipHash) path.
    func _rawHashValue(seed: Int) -> Int {
        Int(truncatingIfNeeded: idbServerIntHash(value ^ UInt64(truncatingIfNeeded: seed)))
    }
}

// swift-format-ignore: AvoidRetroactiveConformances
// The identifier is a C++ type with no Hashable conformance of its own, and the server's tables key on it in many places;
// a wrapper key would add a type at each of them.
extension WebCore.IDBResourceIdentifier: @retroactive Hashable {
    /// Feeds the hasher the identifier's C++ hash rather than hashing its members, so that Swift and C++ tables agree on it.
    public func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(WebCore.idbResourceIdentifierHash(self))
    }

    // swift-format-ignore: NoLeadingUnderscores
    /// The hash a native dictionary asks for, without the default `Hasher` (SipHash) path.
    public func _rawHashValue(seed: Int) -> Int {
        let hash = UInt64(WebCore.idbResourceIdentifierHash(self))
        return Int(truncatingIfNeeded: idbServerIntHash(hash ^ UInt64(truncatingIfNeeded: seed)))
    }
}

// swift-format-ignore: AvoidRetroactiveConformances
// As for IDBResourceIdentifier above: a C++ type with no Hashable conformance, used as a key throughout the server.
extension WebCore.IDBDatabaseIdentifier: @retroactive Hashable {
    /// Feeds the hasher the identifier's C++ hash rather than hashing its members, so that Swift and C++ tables agree on it.
    public func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(WebCore.idbDatabaseIdentifierHash(self))
    }
}

/// The databases by identifier, iterated in the order a WTF HashMap of them would be.
///
/// That is the order `indexedDB.databases()` lists the open databases in, unsorted: getdatabases-expected.txt and
/// getdatabases-private-expected.txt (storage/indexeddb) expect "getdatabase-first" before "getdatabase-second". A Swift `Dictionary` alone has a per-instance, per-process order.
struct IDBDatabaseRegistry {
    private var databases: [WebCore.IDBDatabaseIdentifier: UniqueIDBDatabase] = [:]
    private var order = WebCore.IDBDatabaseIdentifierHashOrder()

    subscript(_ identifier: WebCore.IDBDatabaseIdentifier) -> UniqueIDBDatabase? {
        get {
            databases[identifier]
        }
        set {
            if let newValue {
                if databases.updateValue(newValue, forKey: identifier) == nil {
                    WebCore.idbDatabaseIdentifierHashOrderAdd(&order, identifier)
                }
            } else if databases.removeValue(forKey: identifier) != nil {
                WebCore.idbDatabaseIdentifierHashOrderRemove(&order, identifier)
            }
        }
    }

    /// Mutating so the order map is passed in place, not as a copy (whose order can differ).
    var values: [UniqueIDBDatabase] {
        mutating get {
            let identifiers = WebCore.idbDatabaseIdentifierHashOrderKeys(&order)
            let count = WebCore.idbDatabaseIdentifierVectorSize(identifiers)
            return (0..<count).compactMap { databases[WebCore.idbDatabaseIdentifierVectorAt(identifiers, $0)] }
        }
    }

    var isEmpty: Bool {
        databases.isEmpty
    }

    mutating func removeAll() {
        databases.removeAll()
        WebCore.idbDatabaseIdentifierHashOrderClear(&order)
    }
}

/// A database's in-progress transactions by identifier, whose `keys` and `values` come in the order a WTF HashMap of
/// them iterates in: the order the aborts of a closing connection, a version change and suspended clients follow,
/// which on the SQLite store decides which transaction still holds the database when the next one begins.
struct IDBInProgressTransactions {
    private var serials: [WebCore.IDBResourceIdentifier: IDBEntitySerial] = [:]
    private var order = WebCore.IDBResourceIdentifierHashOrder()

    subscript(_ identifier: WebCore.IDBResourceIdentifier) -> IDBEntitySerial? {
        serials[identifier]
    }

    /// Sets the serial for the identifier, keeping its place if it had one, and returns the serial it replaced.
    mutating func updateValue(_ serial: IDBEntitySerial, forKey identifier: WebCore.IDBResourceIdentifier) -> IDBEntitySerial? {
        let previous = serials.updateValue(serial, forKey: identifier)
        if previous == nil {
            WebCore.idbResourceIdentifierHashOrderAdd(&order, identifier)
        }
        return previous
    }

    mutating func removeValue(forKey identifier: WebCore.IDBResourceIdentifier) -> IDBEntitySerial? {
        guard let removed = serials.removeValue(forKey: identifier) else {
            return nil
        }
        WebCore.idbResourceIdentifierHashOrderRemove(&order, identifier)
        return removed
    }

    /// Mutating so the order map is passed in place, not as a copy (whose order can differ).
    var keys: [WebCore.IDBResourceIdentifier] {
        mutating get {
            let identifiers = WebCore.idbResourceIdentifierHashOrderKeys(&order)
            let count = WebCore.idbResourceIdentifierVectorSize(identifiers)
            return (0..<count).map { WebCore.idbResourceIdentifierVectorAt(identifiers, $0) }
        }
    }

    var values: [IDBEntitySerial] {
        mutating get {
            keys.compactMap { serials[$0] }
        }
    }

    /// Whether any serial satisfies the predicate, in no particular order.
    func contains(where predicate: (IDBEntitySerial) -> Bool) -> Bool {
        serials.values.contains(where: predicate)
    }

    var isEmpty: Bool {
        serials.isEmpty
    }
}

// The identifiers whose C++ type is a template specialization cannot be Hashable: a public conformance of one is
// printed into WebCore's module interface under a name the interface cannot read back (rdar://192229323). They key
// these containers by their integer instead, through an internal protocol. The operators below are defined at file
// scope because a conformance cannot be internal.

protocol IDBUInt64Identifier {
    func toUInt64() -> UInt64
}

extension WebCore.IDBDatabaseConnectionIdentifier: IDBUInt64Identifier {}
extension WebCore.IDBObjectStoreIdentifier: IDBUInt64Identifier {}
extension WebCore.IDBConnectionIdentifier: IDBUInt64Identifier {}

func == (a: WebCore.IDBDatabaseConnectionIdentifier, b: WebCore.IDBDatabaseConnectionIdentifier) -> Bool {
    a.toUInt64() == b.toUInt64()
}

func == (a: WebCore.IDBDatabaseConnectionIdentifier?, b: WebCore.IDBDatabaseConnectionIdentifier) -> Bool {
    a.map { $0 == b } ?? false
}

func != (a: WebCore.IDBDatabaseConnectionIdentifier, b: WebCore.IDBDatabaseConnectionIdentifier) -> Bool {
    a.toUInt64() != b.toUInt64()
}

struct IDBIdentifierDictionary<Identifier: IDBUInt64Identifier, Value>: Sequence, ExpressibleByDictionaryLiteral {
    private var storage: Storage = [:]

    init() {}

    init(dictionaryLiteral elements: (Identifier, Value)...) {
        for (identifier, value) in elements {
            self[identifier] = value
        }
    }

    subscript(identifier: Identifier) -> Value? {
        get { storage[IDBServerIntegerKey(identifier.toUInt64())]?.value }
        set { storage[IDBServerIntegerKey(identifier.toUInt64())] = newValue.map { (identifier, $0) } }
    }

    subscript(identifier: Identifier, default defaultValue: @autoclosure () -> Value) -> Value {
        get { self[identifier] ?? defaultValue() }
        set { self[identifier] = newValue }
    }

    typealias Storage = [IDBServerIntegerKey: (identifier: Identifier, value: Value)]

    func makeIterator() -> LazyMapSequence<Storage.Values, (Identifier, Value)>.Iterator {
        storage.values.lazy.map { ($0.identifier, $0.value) }.makeIterator()
    }
}

struct IDBIdentifierSet<Identifier: IDBUInt64Identifier>: Sequence, ExpressibleByArrayLiteral {
    private var storage: [IDBServerIntegerKey: Identifier] = [:]

    init() {}

    init(arrayLiteral elements: Identifier...) {
        formUnion(elements)
    }

    init(_ identifiers: some Sequence<Identifier>) {
        formUnion(identifiers)
    }

    var isEmpty: Bool { storage.isEmpty }

    func contains(_ identifier: Identifier) -> Bool {
        storage[IDBServerIntegerKey(identifier.toUInt64())] != nil
    }

    mutating func insert(_ identifier: Identifier) {
        storage[IDBServerIntegerKey(identifier.toUInt64())] = identifier
    }

    mutating func remove(_ identifier: Identifier) {
        storage[IDBServerIntegerKey(identifier.toUInt64())] = nil
    }

    mutating func formUnion(_ identifiers: some Sequence<Identifier>) {
        for identifier in identifiers {
            insert(identifier)
        }
    }

    func makeIterator() -> Dictionary<IDBServerIntegerKey, Identifier>.Values.Iterator {
        storage.values.makeIterator()
    }
}
