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

// The encoder model shared by BindGroup, the resource classes, the three encoders and RenderBundle.

import Metal
import WebGPU_Internal.BindGroup
import WebGPU_Internal.BindableResource
import WebGPU_Internal.Buffer
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.ExternalTexture
import WebGPU_Internal.Texture
import WebGPU_Internal.TextureView
import WebGPU_Private.WebGPUCpp

// MARK: WTF::HashTable replica

/// WTF::intHash(uint64_t).
///
/// intHash(uint32_t) widens to 64 bits first, and PtrHash hashes the address as a uintptr_t, so this is DefaultHash for
/// every integer and pointer key the encoders use.
func wtfIntHash(_ key: UInt64) -> UInt32 {
    let product = (key ^ 0x2d35_8dcc_aa6c_78a5).multipliedFullWidth(by: key ^ 0x8bb8_4b93_962e_acc9)
    return UInt32(truncatingIfNeeded: product.low ^ product.high)
}

protocol WTFHashKey: Equatable {
    /// WTF's DefaultHash<Key>::hash for integer keys, whose iteration order is observable; any well-mixed hash otherwise.
    var wtfHash: UInt32 { get }
}

extension UInt32: WTFHashKey {
    var wtfHash: UInt32 { wtfIntHash(UInt64(self)) }
}

extension UInt64: WTFHashKey {
    var wtfHash: UInt32 { wtfIntHash(self) }
}

/// WTF::HashMap<Key, Value> with DefaultHash and UnsignedWithZeroKeyHashTraits, replicated bucket for bucket.
///
/// The same table sizes (minimum 8, max load 3/4 up to 1024 buckets then 1/2, shrink below 1/6), the same triangular
/// probing, the same reuse of the last deleted bucket on the probe path, the same rehash in old-bucket order, and
/// clear() freeing the table, so `forEachInWTFOrder` visits keys in the order a WTF iterator would after the same
/// sequence of set/add/remove/removeAll calls.
///
/// Values live in a dense array (never in an Optional), so a Value may hold FRTs.
struct WTFHashMap<Key: WTFHashKey, Value> {
    private static var emptyBucket: UInt8 { 0 }
    private static var deletedBucket: UInt8 { 1 }
    private static var fullBucket: UInt8 { 2 }
    private static var minimumTableSize: Int { 8 }

    private var states: [UInt8] = []
    private var keys: [Key?] = []
    private var valueIndexForBucket: [Int32] = []
    private(set) var values: [Value] = []
    private var bucketForValue: [Int32] = []
    private var deletedCount = 0

    init() {
    }

    var count: Int {
        values.count
    }

    var isEmpty: Bool {
        values.isEmpty
    }

    func contains(_ key: Key) -> Bool {
        bucket(of: key) != nil
    }

    func value(forKey key: Key) -> Value? {
        guard let bucket = bucket(of: key) else {
            return nil
        }
        return values[Int(valueIndexForBucket[bucket])]
    }

    /// HashMap::set: replaces the value of an existing key in place, which does not move the key.
    @discardableResult
    mutating func set(_ key: Key, _ value: Value) -> Bool {
        if let bucket = bucket(of: key) {
            values[Int(valueIndexForBucket[bucket])] = value
            return false
        }
        insertNewKey(key, value)
        return true
    }

    /// HashMap::add: keeps the value of an existing key, and returns isNewEntry.
    @discardableResult
    mutating func add(_ key: Key, _ makeValue: () -> Value) -> Bool {
        if bucket(of: key) != nil {
            return false
        }
        insertNewKey(key, makeValue())
        return true
    }

    /// Mutates the value of an existing key in place; returns false, doing nothing, for a missing key.
    @discardableResult
    mutating func modifyValue(forKey key: Key, _ body: (inout Value) -> Void) -> Bool {
        guard let bucket = bucket(of: key) else {
            return false
        }
        body(&values[Int(valueIndexForBucket[bucket])])
        return true
    }

    /// The dense index of the value of a key in `values`, to read and then replace it with one probe.
    func valueIndex(forKey key: Key) -> Int? {
        guard let bucket = bucket(of: key) else {
            return nil
        }
        return Int(valueIndexForBucket[bucket])
    }

    mutating func replaceValue(at valueIndex: Int, with value: Value) {
        values[valueIndex] = value
    }

    mutating func modifyValue(at valueIndex: Int, _ body: (inout Value) -> Void) {
        body(&values[valueIndex])
    }

    /// HashMap::set or add of a key known to be absent (valueIndex(forKey:) just returned nil).
    mutating func insertAbsent(_ key: Key, _ value: Value) {
        insertNewKey(key, value)
    }

    /// HashMap::remove(key).
    @discardableResult
    mutating func remove(_ key: Key) -> Bool {
        guard let bucket = bucket(of: key) else {
            return false
        }
        let valueIndex = Int(valueIndexForBucket[bucket])
        states[bucket] = Self.deletedBucket
        keys[bucket] = nil
        valueIndexForBucket[bucket] = -1
        let lastIndex = values.count - 1
        if valueIndex != lastIndex {
            values.swapAt(valueIndex, lastIndex)
            bucketForValue.swapAt(valueIndex, lastIndex)
            valueIndexForBucket[Int(bucketForValue[valueIndex])] = Int32(valueIndex)
        }
        values.removeLast()
        bucketForValue.removeLast()
        deletedCount += 1
        if values.count * 6 < states.count && states.count > Self.minimumTableSize {
            rehash(states.count / 2)
        }
        return true
    }

    /// HashMap::clear(): frees the table, so the next insertion starts again from 8 buckets.
    mutating func removeAll() {
        states = []
        keys = []
        valueIndexForBucket = []
        values = []
        bucketForValue = []
        deletedCount = 0
    }

    /// Visits the entries in WTF iterator order; the body must not mutate this map.
    func forEachInWTFOrder(_ body: (Key, Value) throws -> Void) rethrows {
        for bucket in 0..<states.count where states[bucket] == Self.fullBucket {
            if let key = keys[bucket] {
                try body(key, values[Int(valueIndexForBucket[bucket])])
            }
        }
    }

    func forEachKeyInWTFOrder(_ body: (Key) throws -> Void) rethrows {
        for bucket in 0..<states.count where states[bucket] == Self.fullBucket {
            if let key = keys[bucket] {
                try body(key)
            }
        }
    }

    private func bucket(of key: Key) -> Int? {
        let tableSize = states.count
        if tableSize == 0 {
            return nil
        }
        let mask = tableSize - 1
        var index = Int(truncatingIfNeeded: key.wtfHash) & mask
        var probeCount = 0
        while true {
            let state = states[index]
            if state == Self.emptyBucket {
                return nil
            }
            if state == Self.fullBucket && keys[index] == key {
                return index
            }
            probeCount += 1
            index = (index + probeCount) & mask
        }
    }

    private static func shouldExpand(_ keyAndDeleteCount: Int, _ tableSize: Int) -> Bool {
        if tableSize <= 1024 {
            return keyAndDeleteCount * 4 >= tableSize * 3
        }
        return keyAndDeleteCount * 2 >= tableSize
    }

    // As WTF::HashTable::add: the last deleted bucket on the probe path is reused.
    private mutating func insertNewKey(_ key: Key, _ value: Value) {
        if states.isEmpty {
            rehash(Self.minimumTableSize)
        }
        let mask = states.count - 1
        var index = Int(truncatingIfNeeded: key.wtfHash) & mask
        var probeCount = 0
        var deletedBucket: Int?
        while states[index] != Self.emptyBucket {
            if states[index] == Self.deletedBucket {
                deletedBucket = index
            }
            probeCount += 1
            index = (index + probeCount) & mask
        }
        if let deletedBucket {
            index = deletedBucket
            deletedCount -= 1
        }
        states[index] = Self.fullBucket
        keys[index] = key
        valueIndexForBucket[index] = Int32(values.count)
        values.append(value)
        bucketForValue.append(Int32(index))
        if Self.shouldExpand(values.count + deletedCount, states.count) {
            expand()
        }
    }

    // As WTF::HashTable::expand.
    private mutating func expand() {
        let oldSize = states.count
        if oldSize == 0 {
            rehash(Self.minimumTableSize)
        } else if values.count * 6 < oldSize * 2 {
            rehash(oldSize)
        } else {
            rehash(oldSize * 2)
        }
    }

    // As WTF::HashTable::rehash: reinserts the full buckets in old-bucket order.
    private mutating func rehash(_ newSize: Int) {
        let oldStates = states
        let oldKeys = keys
        let oldValueIndexForBucket = valueIndexForBucket
        states = Array(repeating: Self.emptyBucket, count: newSize)
        keys = Array(repeating: nil, count: newSize)
        valueIndexForBucket = Array(repeating: -1, count: newSize)
        deletedCount = 0
        let mask = newSize - 1
        for oldBucket in 0..<oldStates.count where oldStates[oldBucket] == Self.fullBucket {
            guard let key = oldKeys[oldBucket] else {
                continue
            }
            var index = Int(truncatingIfNeeded: key.wtfHash) & mask
            var probeCount = 0
            while states[index] != Self.emptyBucket {
                probeCount += 1
                index = (index + probeCount) & mask
            }
            states[index] = Self.fullBucket
            keys[index] = key
            let valueIndex = oldValueIndexForBucket[oldBucket]
            valueIndexForBucket[index] = valueIndex
            bucketForValue[Int(valueIndex)] = Int32(index)
        }
    }
}

/// WTF::HashSet<Key, DefaultHash, UnsignedWithZeroKeyHashTraits>.
typealias WTFHashSet<Key: WTFHashKey> = WTFHashMap<Key, Void>

extension WTFHashMap where Value == Void {
    @discardableResult
    mutating func add(_ key: Key) -> Bool {
        add(key) { () }
    }
}

/// The key of a map keyed by object identity: the Impl's address, stable while it lives.
func identityKey(_ identity: ObjectIdentifier) -> UInt64 {
    UInt64(UInt(bitPattern: identity))
}

// MARK: Bind-group-index tables

/// Device::maxBindGroups, the size of every per-group array (Swift does not import static constexpr).
let maxBindGroupIndexCount = 32

/// WTF::HashSet<uint32_t, DefaultHash, UnsignedWithZeroKeyHashTraits> of bind-group indices (keys below 32).
///
/// The WTFHashMap replica's table sizes, probing, deleted-bucket reuse, expand, shrink and rehash order, in inline
/// storage. At most 32 keys never take more than 128 buckets (an expansion with fewer than a third of 128 buckets live
/// rehashes in place), so it never allocates, and a copy of it is a snapshot of the iteration order.
struct GroupIndexOrder: Sequence {
    private static var minimumTableSize: Int { 8 }
    private static var maximumTableSize: Int { 128 }

    // Bucket bytes: 0 empty, 1 deleted, key + 2 full. `lowBuckets` holds buckets 0..<64, `highBuckets` 64..<128.
    private var lowBuckets = SIMD64<UInt8>()
    private var highBuckets = SIMD64<UInt8>()
    private var tableSize = 0
    private var deletedCount = 0
    /// Bit `key` is set for each key in the set.
    private(set) var presentMask: UInt32 = 0

    init() {
    }

    var count: Int {
        presentMask.nonzeroBitCount
    }

    var isEmpty: Bool {
        @inline(__always)
        get {
            presentMask == 0
        }
    }

    @inline(__always)
    func contains(_ key: UInt32) -> Bool {
        key < 32 && presentMask & (1 << key) != 0
    }

    private func bucketState(_ index: Int) -> UInt8 {
        index < 64 ? lowBuckets[index] : highBuckets[index &- 64]
    }

    private mutating func setBucketState(_ index: Int, _ state: UInt8) {
        if index < 64 {
            lowBuckets[index] = state
        } else {
            highBuckets[index &- 64] = state
        }
    }

    private static func fullState(_ key: UInt32) -> UInt8 {
        UInt8(key) &+ 2
    }

    /// HashSet::add; returns isNewEntry.
    @inline(__always)
    @discardableResult
    mutating func add(_ key: UInt32) -> Bool {
        precondition(key < 32)
        if contains(key) {
            return false
        }
        insertNewKey(key)
        return true
    }

    @inline(never)
    private mutating func insertNewKey(_ key: UInt32) {
        if tableSize == 0 {
            rehash(Self.minimumTableSize)
        }
        let mask = tableSize - 1
        var index = Int(truncatingIfNeeded: key.wtfHash) & mask
        var probeCount = 0
        var deletedBucket = -1
        while true {
            let state = bucketState(index)
            if state == 0 {
                break
            }
            if state == 1 {
                deletedBucket = index
            }
            probeCount += 1
            index = (index + probeCount) & mask
        }
        if deletedBucket >= 0 {
            index = deletedBucket
            deletedCount -= 1
        }
        setBucketState(index, Self.fullState(key))
        presentMask |= 1 << key
        if Self.shouldExpand(count + deletedCount, tableSize) {
            expand()
        }
    }

    /// HashSet::remove.
    @inline(__always)
    @discardableResult
    mutating func remove(_ key: UInt32) -> Bool {
        if !contains(key) {
            return false
        }
        removePresentKey(key)
        return true
    }

    @inline(never)
    private mutating func removePresentKey(_ key: UInt32) {
        let mask = tableSize - 1
        var index = Int(truncatingIfNeeded: key.wtfHash) & mask
        var probeCount = 0
        let full = Self.fullState(key)
        while bucketState(index) != full {
            probeCount += 1
            index = (index + probeCount) & mask
        }
        setBucketState(index, 1)
        presentMask &= ~(1 << key)
        deletedCount += 1
        if count * 6 < tableSize && tableSize > Self.minimumTableSize {
            rehash(tableSize / 2)
        }
    }

    /// HashSet::clear(): frees the table, so the next insertion starts again from 8 buckets.
    mutating func removeAll() {
        lowBuckets = SIMD64()
        highBuckets = SIMD64()
        tableSize = 0
        deletedCount = 0
        presentMask = 0
    }

    private static func shouldExpand(_ keyAndDeleteCount: Int, _ tableSize: Int) -> Bool {
        keyAndDeleteCount * 4 >= tableSize * 3
    }

    private mutating func expand() {
        if tableSize == 0 {
            rehash(Self.minimumTableSize)
        } else if count * 6 < tableSize * 2 {
            rehash(tableSize)
        } else {
            rehash(tableSize * 2)
        }
    }

    private mutating func rehash(_ newSize: Int) {
        precondition(newSize <= Self.maximumTableSize)
        let old = self
        lowBuckets = SIMD64()
        highBuckets = SIMD64()
        tableSize = newSize
        deletedCount = 0
        let mask = newSize - 1
        for oldBucket in 0..<old.tableSize {
            let state = old.bucketState(oldBucket)
            if state < 2 {
                continue
            }
            var index = Int(truncatingIfNeeded: UInt32(state &- 2).wtfHash) & mask
            var probeCount = 0
            while bucketState(index) != 0 {
                probeCount += 1
                index = (index + probeCount) & mask
            }
            setBucketState(index, state)
        }
    }

    /// The keys in WTF iterator order.
    struct Iterator: IteratorProtocol {
        fileprivate let order: GroupIndexOrder
        fileprivate var bucket = 0

        mutating func next() -> UInt32? {
            while bucket < order.tableSize {
                let state = order.bucketState(bucket)
                bucket += 1
                if state >= 2 {
                    return UInt32(state &- 2)
                }
            }
            return nil
        }
    }

    func makeIterator() -> Iterator {
        Iterator(order: self)
    }
}

/// A per-encoder HashMap<uint32_t, V, DefaultHash<uint32_t>, UnsignedWithZeroKeyHashTraits<uint32_t>> keyed by a
/// bind-group index: the WTF order replica plus dense storage allocated once. `Value` must not contain an FRT (it is
/// stored Optional).
struct GroupIndexedTable<Value> {
    private(set) var order = GroupIndexOrder()
    /// Empty until the first set(), then maxBindGroupIndexCount slots.
    private var slots: [Value?] = []

    /// nil for an absent or out-of-range group.
    subscript(group: UInt32) -> Value? {
        @inline(__always)
        get {
            order.contains(group) ? slots[Int(group)] : nil
        }
    }

    var isEmpty: Bool {
        @inline(__always)
        get {
            order.isEmpty
        }
    }

    @inline(__always)
    func contains(_ group: UInt32) -> Bool {
        order.contains(group)
    }

    mutating func set(_ group: UInt32, _ value: Value) {
        if slots.isEmpty {
            slots = Array(repeating: nil, count: maxBindGroupIndexCount)
        }
        order.add(group)
        slots[Int(group)] = value
    }

    @inline(__always)
    @discardableResult
    mutating func remove(_ group: UInt32) -> Bool {
        if !order.remove(group) {
            return false
        }
        slots[Int(group)] = nil
        return true
    }

    mutating func removeAll() {
        var present = order.presentMask
        while present != 0 {
            slots[present.trailingZeroBitCount] = nil
            present &= present &- 1
        }
        order.removeAll()
    }

    /// The body must not mutate this table.
    func forEachInWTFOrder(_ body: (UInt32, Value) throws -> Void) rethrows {
        for group in order {
            if let value = slots[Int(group)] {
                try body(group, value)
            }
        }
    }
}

/// The bind groups of an encoder, by group index.
///
/// Hot paths read the Impls only; `shells` holds one strong reference per present group and is never iterated. Walk it
/// as `for group in table.order { table[group] }`: the order is a POD snapshot, so nothing is copied.
struct BindGroupTable {
    private var impls = GroupIndexedTable<BindGroupImpl>()
    private var shells: [WebGPU.Metal.BindGroup] = []
    private var shellIndexForGroup = SIMD32<Int8>(repeating: -1)
    private var groupForShellIndex = SIMD32<UInt8>()

    var order: GroupIndexOrder {
        @inline(__always)
        get {
            impls.order
        }
    }

    subscript(group: UInt32) -> BindGroupImpl? {
        @inline(__always)
        get {
            impls[group]
        }
    }

    /// Whether `impl` is already the group's bind group, which makes set() a no-op (a read, so callers can skip the
    /// modify access).
    @inline(__always)
    func holds(_ group: UInt32, _ impl: BindGroupImpl) -> Bool {
        impls[group] === impl
    }

    /// Setting a group's own bind group again changes nothing (a BindGroupImpl has exactly one shell), and the group
    /// keeps its place in the order.
    mutating func set(_ group: UInt32, _ shell: WebGPU.Metal.BindGroup, _ impl: BindGroupImpl) {
        if holds(group, impl) {
            return
        }
        setImpl(group, impl)
        storeShell(group, shell)
    }

    /// set() in two steps, for an encoder whose shell hands in the bind group's shell only when asked: setImpl() when
    /// holds() is false, then at once storeShell() with that Impl's shell.
    mutating func setImpl(_ group: UInt32, _ impl: BindGroupImpl) {
        impls.set(group, impl)
    }

    mutating func storeShell(_ group: UInt32, _ shell: WebGPU.Metal.BindGroup) {
        let index = Int(shellIndexForGroup[Int(group)])
        if index >= 0 {
            shells[index] = shell
            return
        }
        shellIndexForGroup[Int(group)] = Int8(shells.count)
        groupForShellIndex[shells.count] = UInt8(group)
        shells.append(shell)
    }

    @discardableResult
    mutating func remove(_ group: UInt32) -> Bool {
        if !impls.order.contains(group) {
            return false
        }
        let index = Int(shellIndexForGroup[Int(group)])
        let lastIndex = shells.count - 1
        if index != lastIndex {
            shells.swapAt(index, lastIndex)
            let movedGroup = groupForShellIndex[lastIndex]
            groupForShellIndex[index] = movedGroup
            shellIndexForGroup[Int(movedGroup)] = Int8(index)
        }
        shells.removeLast()
        shellIndexForGroup[Int(group)] = -1
        return impls.remove(group)
    }

    mutating func removeAll() {
        impls.removeAll()
        shells.removeAll(keepingCapacity: true)
        shellIndexForGroup = SIMD32(repeating: -1)
    }

    /// The body must not mutate this table.
    func forEachInWTFOrder(_ body: (UInt32, BindGroupImpl) throws -> Void) rethrows {
        try impls.forEachInWTFOrder(body)
    }

    /// The shell of a present group, for CommandEncoderImpl.rebindSamplersPreCommit.
    func shell(_ group: UInt32) -> WebGPU.Metal.BindGroup {
        shells[Int(shellIndexForGroup[Int(group)])]
    }
}

// MARK: Resource model

/// How a bind group entry or an attachment uses its resource.
struct EntryUsage: OptionSet, Hashable {
    let rawValue: UInt16

    static let input = EntryUsage(rawValue: 1 << 0)
    static let constant = EntryUsage(rawValue: 1 << 1)
    static let storage = EntryUsage(rawValue: 1 << 2)
    static let storageRead = EntryUsage(rawValue: 1 << 3)
    static let attachment = EntryUsage(rawValue: 1 << 4)
    static let attachmentRead = EntryUsage(rawValue: 1 << 5)
    static let constantTexture = EntryUsage(rawValue: 1 << 6)
    static let storageTextureWriteOnly = EntryUsage(rawValue: 1 << 7)
    static let storageTextureRead = EntryUsage(rawValue: 1 << 8)
    static let storageTextureReadWrite = EntryUsage(rawValue: 1 << 9)

    private static let exclusive: EntryUsage = [.storage, .storageTextureWriteOnly, .storageTextureReadWrite, .attachment]

    /// Whether the usages may combine: an exclusive usage (each is one bit) only on its own.
    var isAllowed: Bool {
        isDisjoint(with: Self.exclusive) || rawValue & (rawValue &- 1) == 0
    }

    /// The usage names for error messages, each followed by a space.
    var name: String {
        let names: [(EntryUsage, String)] = [
            (.input, "Input "), (.constant, "Constant "), (.storage, "Storage "), (.storageRead, "StorageRead "),
            (.attachment, "Attachment "), (.attachmentRead, "AttachmentRead "), (.constantTexture, "ConstantTexture "),
            (.storageTextureWriteOnly, "StorageTextureWriteOnly "), (.storageTextureRead, "StorageTextureRead "),
            (.storageTextureReadWrite, "StorageTextureReadWrite "),
        ]
        var result = ""
        for (flag, flagName) in names where contains(flag) {
            result += flagName
        }
        return result
    }
}

/// A bound resource with its Impl (pair invariant), for ownership only: hot paths read TrackedImpl.
enum BoundResource {
    case buffer(WebGPU.Metal.Buffer, BufferImpl)
    case texture(WebGPU.Metal.Texture, TextureImpl)
    case textureView(WebGPU.Metal.TextureView, TextureViewImpl)
    case externalTexture(WebGPU.Metal.ExternalTexture, ExternalTextureImpl)

    var trackedImpl: TrackedImpl {
        switch self {
        case .buffer(_, let impl): .buffer(impl)
        case .texture(_, let impl): .texture(impl)
        case .textureView(_, let impl): .textureView(impl)
        case .externalTexture(_, let impl): .externalTexture(impl)
        }
    }
}

/// The Impl half of a BoundResource: native Swift references only, so copying one never touches an FRT refcount.
enum TrackedImpl {
    case buffer(BufferImpl)
    case texture(TextureImpl)
    case textureView(TextureViewImpl)
    case externalTexture(ExternalTextureImpl)

    var identity: ObjectIdentifier {
        switch self {
        case .buffer(let impl): ObjectIdentifier(impl)
        case .texture(let impl): ObjectIdentifier(impl)
        case .textureView(let impl): ObjectIdentifier(impl)
        case .externalTexture(let impl): ObjectIdentifier(impl)
        }
    }

    /// The Metal resource to bind in place of a destroyed resource; nil otherwise.
    var placeholderIfDestroyed: (any MTLResource)? {
        switch self {
        case .buffer(let impl):
            impl.isDestroyed() ? impl.buffer() : nil
        case .texture(let impl):
            impl.isDestroyed() && !impl.isCanvasBacking() ? impl.texture() : nil
        case .textureView(let impl):
            impl.isDestroyed() && !impl.parentIsCanvasBacking() ? impl.texture() : nil
        case .externalTexture:
            nil
        }
    }

    /// Records the encoder on the resource; idempotent per (resource, encoder), so it is called once per distinct
    /// resource.
    func setCommandEncoder(_ encoder: CommandEncoderImpl) {
        switch self {
        case .buffer(let impl): impl.setCommandEncoder(encoder, mayModifyBuffer: false)
        case .texture(let impl): impl.setCommandEncoder(encoder)
        case .textureView(let impl): impl.setCommandEncoder(encoder)
        case .externalTexture(let impl): impl.setCommandEncoder(encoder)
        }
    }

    /// Records a bind group that holds the resource.
    func addBindGroupHolder(_ bindGroup: WebGPU.Metal.BindGroup) {
        switch self {
        case .buffer(let impl): impl.addBindGroupHolder(bindGroup)
        case .texture(let impl): impl.addBindGroupHolder(bindGroup)
        case .textureView(let impl): impl.parentTextureImpl.addBindGroupHolder(bindGroup)
        case .externalTexture: break
        }
    }

    /// Records a render bundle that holds the resource.
    func addRenderBundleHolder(_ renderBundle: RenderBundleImpl) {
        switch self {
        case .buffer(let impl): impl.addRenderBundleHolder(renderBundle)
        case .texture(let impl): impl.addRenderBundleHolder(renderBundle)
        case .textureView(let impl): impl.parentTextureImpl.addRenderBundleHolder(renderBundle)
        case .externalTexture: break
        }
    }
}

/// What usage tracking needs about a record's resource, fixed at creation (the view's subresource range and the
/// texture's mip and layer counts are immutable).
struct TrackingInfo {
    enum Kind: UInt8 {
        case buffer
        case texture
        case textureView
        case externalTexture
    }

    let kind: Kind
    /// ObjectIdentifier of the BufferImpl, of the parent TextureImpl (texture and view) or of the ExternalTextureImpl.
    let identity: UInt64
    let baseMipLevel: UInt32
    let mipLevelCount: UInt32
    let baseArrayLayer: UInt32
    let arrayLayerCount: UInt32
    /// The view's aspect; .All for a texture, which both passes track as DepthOnly and StencilOnly.
    let aspect: WebGPU.TextureAspect
}

/// One use of a resource by a bind group entry or a bundle.
struct UsageRecord {
    let usage: EntryUsage
    /// INT_MAX for a bundle resource added outside a bind group.
    let binding: UInt32
    let entryOffset: UInt64
    let entrySize: UInt64
    /// Index into ResourceSet.owners; -1 for a bundle resource with no WebGPU object (argument and dynamic-offset
    /// buffers), which tracking skips.
    let resource: Int32
    /// The Impl of owners[resource], nil where `resource` is -1: native references only, so reading a record never
    /// touches an FRT refcount.
    let impl: TrackedImpl?
    let tracking: TrackingInfo?
}

/// The records ResourceSet.records[range] that share a Metal usage and render stages; their owner keeps their
/// MTLResources in a ResourceLists beside it (one list per container, `range.count` long).
struct ResourceContainer {
    let range: Range<Int>
    let usage: MTLResourceUsage
    /// 0 for the compute stage and 3 for an undefined stage, which no MTLRenderStages names.
    let renderStages: MTLRenderStages
}

/// The containers of a ResourceSet, stored inline: there is at most one per (render stages, usage) bucket, 12 of them.
struct ResourceContainers: RandomAccessCollection {
    private static var capacity: Int { 16 }
    private var ends = SIMD16<UInt32>()
    /// Each container's MTLResourceUsage (1 to 3) in bits 0-1 and render stages (0 to 4) in bits 2-4.
    private var usagesAndRenderStages = SIMD16<UInt8>()
    private(set) var count = 0

    init() {
    }

    var startIndex: Int {
        0
    }

    var endIndex: Int {
        count
    }

    /// Appends the container of the next `recordCount` records.
    mutating func append(recordCount: Int, usage: MTLResourceUsage, renderStages stages: MTLRenderStages) {
        precondition(count < Self.capacity && usage.rawValue < 4 && stages.rawValue < 8)
        let start = count == 0 ? 0 : ends[count - 1]
        ends[count] = start + UInt32(recordCount)
        usagesAndRenderStages[count] = UInt8(usage.rawValue) | UInt8(stages.rawValue) << 2
        count += 1
    }

    subscript(index: Int) -> ResourceContainer {
        precondition(index >= 0 && index < count)
        let start = index == 0 ? 0 : Int(ends[index - 1])
        return ResourceContainer(
            range: start..<Int(ends[index]),
            usage: MTLResourceUsage(rawValue: UInt(usagesAndRenderStages[index] & 3)),
            renderStages: MTLRenderStages(rawValue: UInt(usagesAndRenderStages[index] >> 2))
        )
    }
}

/// The mtlResources of each ResourceContainer, mutated in place by placeholder replacement and external-texture refresh.
///
/// Kept apart so that the owner holds the rest of the ResourceSet as a `let`. The first container's list is stored
/// inline: a group or bundle usually has one container. Read one list at a time (each is what Metal's useResources
/// takes), so that a reader copies one array reference.
struct ResourceLists: ExpressibleByArrayLiteral {
    private(set) var count = 0
    private var first: [any MTLResource] = []
    private var rest: [[any MTLResource]] = []

    init() {
    }

    init(arrayLiteral lists: [any MTLResource]...) {
        for list in lists {
            append(list)
        }
    }

    mutating func reserveCapacity(_ capacity: Int) {
        if capacity > 1 {
            rest.reserveCapacity(capacity - 1)
        }
    }

    mutating func append(_ list: [any MTLResource]) {
        if count == 0 {
            first = list
        } else {
            rest.append(list)
        }
        count += 1
    }

    subscript(index: Int) -> [any MTLResource] {
        get {
            precondition(index >= 0 && index < count)
            return index == 0 ? first : rest[index - 1]
        }
        _modify {
            precondition(index >= 0 && index < count)
            if index == 0 {
                yield &first
            } else {
                yield &rest[index - 1]
            }
        }
    }
}

/// The owners of a ResourceSet: one strong reference per record with a resource, in record order.
///
/// Up to four are stored inline; every case has a payload, so no FRT sits next to an empty case (none is an empty
/// `spilled`).
struct OwnerList {
    private enum Storage {
        case one(BoundResource)
        case two(BoundResource, BoundResource)
        case three(BoundResource, BoundResource, BoundResource)
        case four(BoundResource, BoundResource, BoundResource, BoundResource)
        case spilled([BoundResource])
    }

    private var storage = Storage.spilled([])
    private(set) var count = 0

    init() {
    }

    mutating func append(_ owner: BoundResource) {
        switch storage {
        case .spilled(var owners):
            if owners.isEmpty {
                storage = .one(owner)
            } else {
                storage = .spilled([])
                owners.append(owner)
                storage = .spilled(owners)
            }
        case .one(let first):
            storage = .two(first, owner)
        case .two(let first, let second):
            storage = .three(first, second, owner)
        case .three(let first, let second, let third):
            storage = .four(first, second, third, owner)
        case .four(let first, let second, let third, let fourth):
            storage = .spilled([first, second, third, fourth, owner])
        }
        count += 1
    }

    /// Traps past the end.
    subscript(index: Int) -> BoundResource {
        switch (storage, index) {
        case (.one(let owner), 0), (.two(let owner, _), 0), (.three(let owner, _, _), 0), (.four(let owner, _, _, _), 0):
            return owner
        case (.two(_, let owner), 1), (.three(_, let owner, _), 1), (.four(_, let owner, _, _), 1):
            return owner
        case (.three(_, _, let owner), 2), (.four(_, _, let owner, _), 2):
            return owner
        case (.four(_, _, _, let owner), 3):
            return owner
        case (.spilled(let owners), _):
            return owners[index]
        default:
            preconditionFailure("owner index out of range")
        }
    }
}

/// The resources of a BindGroup or a RenderBundle, except the mutable ResourceLists.
struct ResourceSet {
    let containers: ResourceContainers
    /// Every container's records, container after container.
    let records: [UsageRecord]
    /// One strong reference per record with a resource, in record order.
    let owners: OwnerList
    /// The distinct Impls of the records, by identity, in first-use order; nil when no Impl repeats (the usual case), and
    /// then they are the records' Impls themselves.
    private let distinctImplsIfRepeated: [TrackedImpl]?

    init(containers: ResourceContainers, records: [UsageRecord], owners: OwnerList) {
        self.containers = containers
        self.records = records
        self.owners = owners
        if owners.count <= 16 {
            var firstRepeat: Int?
            var earlierImpls = 0
            search: for index in records.indices {
                guard let impl = records[index].impl else {
                    continue
                }
                for earlier in 0..<index where records[earlier].impl?.identity == impl.identity {
                    firstRepeat = index
                    break search
                }
                earlierImpls += 1
            }
            guard let firstRepeat else {
                distinctImplsIfRepeated = nil
                return
            }
            var distinct: [TrackedImpl] = []
            distinct.reserveCapacity(earlierImpls)
            for record in records[..<firstRepeat] {
                if let impl = record.impl {
                    distinct.append(impl)
                }
            }
            for record in records[firstRepeat...] {
                if let impl = record.impl, !distinct.contains(where: { $0.identity == impl.identity }) {
                    distinct.append(impl)
                }
            }
            distinctImplsIfRepeated = distinct
            return
        }
        var seen = WTFHashSet<UInt64>()
        var distinct: [TrackedImpl] = []
        for record in records {
            if let impl = record.impl, seen.add(identityKey(impl.identity)) {
                distinct.append(impl)
            }
        }
        distinctImplsIfRepeated = distinct
    }

    static var empty: ResourceSet {
        ResourceSet(containers: ResourceContainers(), records: [], owners: OwnerList())
    }

    /// Each distinct Impl once, in first-use order.
    @inline(__always)
    func forEachDistinctImpl(_ body: (TrackedImpl) -> Void) {
        if let distinctImplsIfRepeated {
            for impl in distinctImplsIfRepeated {
                body(impl)
            }
            return
        }
        for record in records {
            if let impl = record.impl {
                body(impl)
            }
        }
    }

    /// Replaces the destroyed resources in `lists` with placeholders; returns whether it replaced any.
    func replaceDestroyedResourcesWithPlaceholders(_ lists: inout ResourceLists) -> Bool {
        var replacedAnything = false
        for containerIndex in containers.indices {
            let range = containers[containerIndex].range
            let resourceCount = min(lists[containerIndex].count, range.count)
            for index in 0..<resourceCount {
                guard let impl = records[range.lowerBound + index].impl, let placeholder = impl.placeholderIfDestroyed else {
                    continue
                }
                if placeholder === lists[containerIndex][index] {
                    continue
                }
                lists[containerIndex][index] = placeholder
                replacedAnything = true
            }
        }
        return replacedAnything
    }

    /// Registers the bind group with the resource of every record; the holder sets drop repeats.
    func registerBindGroupHolder(_ bindGroup: WebGPU.Metal.BindGroup) {
        for index in records.indices {
            records[index].impl?.addBindGroupHolder(bindGroup)
        }
    }

    /// Registers the render bundle with the resource of every record.
    func registerRenderBundleHolder(_ renderBundle: RenderBundleImpl) {
        for index in records.indices {
            records[index].impl?.addRenderBundleHolder(renderBundle)
        }
    }
}

// MARK: Weak references

/// A weak set of Impls (pair invariant), for the API thread only.
struct WeakImplList<T: AnyObject> {
    private struct Entry {
        weak var impl: T?
        /// The identity of the Impl when it was added, compared first so that adding a different Impl loads no weak
        /// reference; a match is confirmed by loading `impl`, so an address reused after it died is never taken for it.
        let identity: ObjectIdentifier
    }

    /// Dead entries are dropped when the array is full, before it grows.
    private var entries: [Entry] = []

    /// Adds `impl` unless it is the last entry: repeats come from one holder registering with one resource several
    /// times in a row (registerRenderBundleHolder walks all of a holder's records in one call).
    mutating func add(_ impl: T) {
        let identity = ObjectIdentifier(impl)
        let lastIndex = entries.count - 1
        if lastIndex >= 0, entries[lastIndex].identity == identity, entries[lastIndex].impl === impl {
            return
        }
        if entries.count >= 8 && entries.count == entries.capacity {
            entries.removeAll { $0.impl == nil }
        }
        entries.append(Entry(impl: impl, identity: identity))
    }

    /// The live ones, as strong references for the duration of the caller's walk.
    var values: [T] {
        entries.compactMap(\.impl)
    }

    mutating func removeAll() {
        entries = []
    }
}

/// Weak references to the shells of the textures a device made, sharing the control block TextureImpl.ownerShell made.
///
/// A dead entry at a sweeping cursor is replaced in place, as in CxxBridging.BindGroupHolders. API thread only.
struct TextureShellList {
    private var entries: [CxxBridging.TextureWeakPtr] = []
    private var cursor = 0

    mutating func add(_ texture: consuming CxxBridging.TextureWeakPtr) {
        let index = cursor
        if index < entries.count {
            cursor += 1
            if CxxBridging.isTextureGone(entries[index]) {
                entries[index] = texture
                return
            }
        } else {
            cursor = 0
        }
        entries.append(texture)
    }

    /// The live ones, as strong references for the duration of the caller's walk.
    var values: [WebGPU.Metal.Texture] {
        entries.compactMap { CxxBridging.protectedTexture($0) }
    }

    mutating func removeAll() {
        entries = []
        cursor = 0
    }
}

// MARK: Render pass attachments

/// TextureOrTextureView without its null state.
enum AttachmentView {
    case texture(WebGPU.Metal.Texture, TextureImpl)
    case textureView(WebGPU.Metal.TextureView, TextureViewImpl)

    var format: WebGPU.TextureFormat {
        switch self {
        case .texture(_, let impl): impl.formatOrDefault
        case .textureView(_, let impl): impl.formatOrDefault
        }
    }

    var sampleCount: UInt32 {
        switch self {
        case .texture(_, let impl): impl.sampleCount()
        case .textureView(_, let impl): impl.sampleCount()
        }
    }

    var metalTexture: (any MTLTexture)? {
        switch self {
        case .texture(_, let impl): impl.texture()
        case .textureView(_, let impl): impl.texture()
        }
    }
}

/// What RenderPipelineImpl.errorValidatingColorDepthStencilTargets and RenderBundleImpl.validateRenderPass read.
struct PassAttachments {
    private(set) var views: [AttachmentView] = []
    /// views[i]'s format and sample count, which are immutable: what setPipeline validates, read without copying a view.
    private(set) var viewTargets: [(format: WebGPU.TextureFormat, sampleCount: UInt32)] = []
    /// One per descriptor color slot: an index into `views`, or -1 for an empty slot.
    var colorViewIndices: [Int32] = []
    /// Whether the pass has a depth-stencil attachment.
    var hasDepthStencil = false
    /// -1 for an engaged but null view.
    var depthStencilViewIndex: Int32 = -1
    var depthReadOnly = false
    var stencilReadOnly = false

    mutating func appendView(_ view: AttachmentView) {
        views.append(view)
        viewTargets.append((format: view.format, sampleCount: view.sampleCount))
    }

    func colorView(_ slot: Int) -> AttachmentView? {
        let index = Int(colorViewIndices[slot])
        return index >= 0 ? views[index] : nil
    }

    /// colorView(slot)'s format and sample count.
    func colorTarget(_ slot: Int) -> (format: WebGPU.TextureFormat, sampleCount: UInt32)? {
        let index = Int(colorViewIndices[slot])
        return index >= 0 ? viewTargets[index] : nil
    }

    /// depthStencilView's format and sample count.
    var depthStencilTarget: (format: WebGPU.TextureFormat, sampleCount: UInt32)? {
        depthStencilViewIndex >= 0 ? viewTargets[Int(depthStencilViewIndex)] : nil
    }

    var depthStencilView: AttachmentView? {
        depthStencilViewIndex >= 0 ? views[Int(depthStencilViewIndex)] : nil
    }
}

// MARK: Render bundle ICB model

/// The index validation of one indexed draw of a bundle's ICB; storeIndexDataForValidation never stores a null buffer.
struct BundleIndexValidation {
    let indexBuffer: WebGPU.Metal.Buffer
    let indexBufferImpl: BufferImpl
    let indexType: MTLIndexType
    let indexBufferOffsetInBytes: UInt
    /// The struct the ICB clamp shader reads; its minVertexCount is `vertices.shaderValue`.
    let indexData: WebGPU.Metal.IndexData
    let vertices: CountBound
}

/// One indirect draw of a bundle's ICB, with the contents generations it was last encoded with.
struct BundleIndirectDraw {
    let renderCommand: UInt64
    let indirectBuffer: WebGPU.Metal.Buffer
    let indirectBufferImpl: BufferImpl
    let indirectOffset: UInt64
    let bounds: VertexInstanceBounds
    /// Zero or one element: empty for a non-indexed draw.
    let indexBuffer: [WebGPU.Metal.Buffer]
    let indexBufferImpl: BufferImpl?
    let indexType: MTLIndexType
    let indexBufferOffset: UInt
    let primitiveType: MTLPrimitiveType
    let isIndexed: Bool
    var encodedAtLeastOnce = false
    var lastIndirectGeneration: UInt64 = 0
    var lastIndexGeneration: UInt64 = 0
}

/// An indirect command buffer of a render bundle and the state to execute it with, built by RenderBundleEncoderImpl;
/// RenderPassEncoderImpl reads it in executeBundles and updates the encode cache in `indirectDraws`.
final class BundleICB {
    let indirectCommandBuffer: any MTLIndirectCommandBuffer
    let indirectCommandBufferContainer: (any MTLBuffer)?
    let outOfBoundsReadFlag: (any MTLBuffer)?
    let renderPipelineState: (any MTLRenderPipelineState)?
    let depthStencilState: (any MTLDepthStencilState)?
    let cullMode: MTLCullMode
    let frontFace: MTLWinding
    let depthClipMode: MTLDepthClipMode
    let depthBias: Float
    let depthBiasSlopeScale: Float
    let depthBiasClamp: Float
    let fragmentDynamicOffsetsBuffer: (any MTLBuffer)?
    /// By ICB command index, walked in WTF order.
    let indexValidations: WTFHashMap<UInt64, BundleIndexValidation>
    /// By ICB command index, walked in WTF order.
    var indirectDraws: WTFHashMap<UInt64, BundleIndirectDraw>

    init(
        indirectCommandBuffer: any MTLIndirectCommandBuffer,
        indirectCommandBufferContainer: (any MTLBuffer)?,
        outOfBoundsReadFlag: (any MTLBuffer)?,
        renderPipelineState: (any MTLRenderPipelineState)?,
        depthStencilState: (any MTLDepthStencilState)?,
        cullMode: MTLCullMode,
        frontFace: MTLWinding,
        depthClipMode: MTLDepthClipMode,
        depthBias: Float,
        depthBiasSlopeScale: Float,
        depthBiasClamp: Float,
        fragmentDynamicOffsetsBuffer: (any MTLBuffer)?,
        indexValidations: WTFHashMap<UInt64, BundleIndexValidation>,
        indirectDraws: WTFHashMap<UInt64, BundleIndirectDraw>
    ) {
        self.indirectCommandBuffer = indirectCommandBuffer
        self.indirectCommandBufferContainer = indirectCommandBufferContainer
        self.outOfBoundsReadFlag = outOfBoundsReadFlag
        self.renderPipelineState = renderPipelineState
        self.depthStencilState = depthStencilState
        self.cullMode = cullMode
        self.frontFace = frontFace
        self.depthClipMode = depthClipMode
        self.depthBias = depthBias
        self.depthBiasSlopeScale = depthBiasSlopeScale
        self.depthBiasClamp = depthBiasClamp
        self.fragmentDynamicOffsetsBuffer = fragmentDynamicOffsetsBuffer
        self.indexValidations = indexValidations
        self.indirectDraws = indirectDraws
    }
}

// MARK: Draw-indexed validation cache key

/// The key of the draw-indexed validation cache of BufferImpl, for lookups only.
struct DrawIndexKey: WTFHashKey {
    let firstIndex: UInt32
    let indexCount: UInt32
    let primitiveOffsetWithIndexType: UInt32
    let icbLow: UInt32
    let icbHigh: UInt32

    var wtfHash: UInt32 {
        var hash = wtfIntHash(UInt64(firstIndex) | UInt64(indexCount) << 32)
        hash ^= wtfIntHash(UInt64(primitiveOffsetWithIndexType) | UInt64(icbLow) << 32) &* 31
        hash ^= wtfIntHash(UInt64(icbHigh)) &* 961
        return hash
    }

    /// The primitive offset bit, and the index type bit left in place: 0 for uint16, 2 (not MTLIndexType.uint32) for
    /// uint32.
    var primitiveOffset: UInt32 {
        primitiveOffsetWithIndexType & 0x1
    }

    var indexTypeRawValue: UInt {
        UInt(primitiveOffsetWithIndexType & 0x2)
    }
}

// MARK: Shared functions

/// isValidToUseWithDevice for two Impls that each keep their DeviceImpl.
func isValidToUse(_ objectIsValid: Bool, _ objectDevice: DeviceImpl, with targetDevice: DeviceImpl) -> Bool {
    objectIsValid && objectDevice.isValid() && objectDevice === targetDevice
}

/// The error when the bound groups do not fit the pipeline layout, or nil.
///
/// `boundGroup` reads the encoder's bind group at an index, so that the encoder's table is not copied; inlined, it needs
/// no closure context.
@inline(__always)
func errorValidatingBindGroupCompatibility(_ layout: PipelineLayoutImpl, _ boundGroup: (UInt32) -> BindGroupImpl?) -> String? {
    if !layout.isValid() {
        return "pipeline layout is not valid"
    }
    for bindGroupIndex in 0..<layout.numberOfBindGroupLayouts() {
        // An empty bind group layout never requires a bind group at its index.
        guard let pipelineGroupLayout = layout.bindGroupLayout(at: bindGroupIndex), !pipelineGroupLayout.entries.isEmpty else {
            continue
        }
        guard let group = boundGroup(UInt32(bindGroupIndex)) else {
            return "can not find bind group in pipeline for bindGroup index \(bindGroupIndex)"
        }
        guard let setLayout = group.layoutImpl else {
            return "can not find bind group in set bind groups for bindGroup index \(bindGroupIndex)"
        }
        // BindGroupLayoutImpl.errorValidatingCompatibility's own first check, without the call.
        if pipelineGroupLayout === setLayout {
            continue
        }
        if let error = pipelineGroupLayout.errorValidatingCompatibility(with: setLayout) {
            return error
        }
    }
    return nil
}

/// The most vertices or instances a draw may use given the bound vertex buffers, unbounded when no buffer bounds it.
enum CountBound: Equatable {
    case unbounded
    case atMost(UInt32)

    /// Decodes UInt32.max as unbounded, for minimumVertexInstanceCount only.
    fileprivate init(inBand value: UInt32) {
        self = value == .max ? .unbounded : .atMost(value)
    }

    var isBounded: Bool {
        self != .unbounded
    }

    var isZero: Bool {
        self == .atMost(0)
    }

    /// What the clamp kernels and the ICB index validation read (minCounts[], IndexData): UInt32.max when unbounded.
    ///
    /// A device maximum there would change which in-range draws pass; the kernels' lost condition bounds the work instead.
    var shaderValue: UInt32 {
        switch self {
        case .unbounded: .max
        case .atMost(let count): count
        }
    }

    /// The index-value clamp's vertexCount: UInt32.max minus the strip restart when unbounded.
    func indexClampVertexCount(primitiveOffset: UInt32) -> UInt32 {
        switch self {
        case .unbounded: UInt32.max &- primitiveOffset
        case .atMost(let count): count
        }
    }

    /// The count index values are checked against once baseVertex is added: the count minus baseVertex, wrapping.
    func effectiveVertexCount(baseVertex: Int32) -> UInt32 {
        switch self {
        case .unbounded: .max
        case .atMost(let count): count &- UInt32(bitPattern: baseVertex)
        }
    }

    /// Whether baseVertex moves every index outside the bound, either way.
    func excludesBaseVertex(_ baseVertex: Int32) -> Bool {
        let limit = Int64(shaderValue)
        return -Int64(baseVertex) > limit || Int64(baseVertex) > limit
    }
}

/// minimumVertexInstanceCount's result.
struct VertexInstanceBounds {
    let vertices: CountBound
    let instances: CountBound
    let needsValidationLayerWorkaround: Bool

    /// Whether an indexed draw's GPU clamp also checks every index value against the vertex buffers (the second
    /// dispatch of an indirect one).
    ///
    /// The argument clamp runs for every indirect draw whatever this says. Render passes, command-replay bundles and
    /// executeBundles' ICB encode all decide through this.
    var clampsIndexValues: Bool {
        vertices.isBounded || instances.isBounded
    }
}

/// The vertex and instance bounds of the bound vertex buffers, order-independent (min and or); inlined so that
/// `bufferSize` needs no closure context.
@inline(__always)
func minimumVertexInstanceCount(
    _ pipeline: RenderPipelineImpl?,
    bufferSize: (UInt32) -> UInt64
) -> VertexInstanceBounds {
    guard let pipeline else {
        return VertexInstanceBounds(vertices: .atMost(0), instances: .atMost(0), needsValidationLayerWorkaround: false)
    }
    var minVertexCount = UInt32.max
    var minInstanceCount = UInt32.max
    var needsValidationLayerWorkaround = false
    for buffer in pipeline.requiredVertexBuffers {
        let size = bufferSize(buffer.bufferIndex)
        if buffer.stride == 0 && size >= buffer.lastStride {
            continue
        }
        let elementCount: UInt64 = size < buffer.lastStride ? 0 : (size - buffer.lastStride) / buffer.stride + 1
        if size < buffer.stride && size >= buffer.lastStride && elementCount == 1 {
            needsValidationLayerWorkaround = true
        }
        if buffer.stepMode == .Vertex {
            minVertexCount = min(minVertexCount, UInt32(truncatingIfNeeded: elementCount))
        } else {
            minInstanceCount = min(minInstanceCount, UInt32(truncatingIfNeeded: elementCount))
        }
    }
    return VertexInstanceBounds(
        vertices: CountBound(inBand: minVertexCount),
        instances: CountBound(inBand: minInstanceCount),
        needsValidationLayerWorkaround: needsValidationLayerWorkaround
    )
}

// MARK: Lazy zero-initialization: what an encoder did, applied when its command buffer is committed

/// What one command encoder did to lazily initialized texture regions.
///
/// Its effects become facts only when its command buffer is committed (apply, which needs the queue's CommitToken); a
/// dropped ledger (encoder or command buffer discarded, made invalid, rejected by submit, never submitted, device lost)
/// only settles its pending discards. ~Copyable, so it cannot be applied twice or kept after it was dropped.
struct InitializationLedger: ~Copyable {
    enum Effect {
        case written
        case discarded
    }

    struct Entry {
        let texture: TextureImpl
        let region: InitRegion
        let effect: Effect
    }

    struct Requirement {
        let texture: TextureImpl
        let region: InitRegion
    }

    enum RequireResult {
        case satisfied
        case recorded
        /// After this encoder's own discard of the region: only a zero fill at this point is right.
        case zeroFillHere
    }

    /// In encoding order; applied in that order.
    private(set) var effects: [Entry] = []
    /// Regions read (or partly written) before this encoder wrote them, which QueueImpl.submit zero-fills before this
    /// command buffer runs unless they are initialized by then.
    private(set) var requirements: [Requirement] = []

    init() {
    }

    var hasRequirements: Bool {
        !requirements.isEmpty
    }

    /// Records a read or a partial write of `region` (the texture counts this encoder's own discards among its pending
    /// ones).
    mutating func require(_ texture: TextureImpl, _ region: InitRegion) -> RequireResult {
        if texture.pendingDiscards == 0 && texture.isInitialized(region) {
            return .satisfied
        }
        switch lastEffect(texture, region) {
        case .written:
            return .satisfied
        case .discarded:
            return .zeroFillHere
        case nil:
            recordRequirement(texture, region)
            return .recorded
        }
    }

    /// A requirement on the region as this command buffer starts, whatever this encoder did to it before.
    mutating func recordRequirement(_ texture: TextureImpl, _ region: InitRegion) {
        if let last = requirements.last, last.texture === texture, last.region == region {
            return
        }
        requirements.append(Requirement(texture: texture, region: region))
    }

    mutating func noteWritten(_ texture: TextureImpl, _ region: InitRegion) {
        effects.append(Entry(texture: texture, region: region, effect: .written))
    }

    /// A copy that reads and/or writes `region`. .zeroFillHere: the copy must first zero-fill the region itself, and then
    /// note it written; nothing was recorded.
    mutating func noteCopy(_ texture: TextureImpl, _ region: InitRegion, reads: Bool, writes: Bool) -> RequireResult {
        let result = reads ? require(texture, region) : .satisfied
        if result != .zeroFillHere && writes {
            noteWritten(texture, region)
        }
        return result
    }

    /// One aspect of a render pass attachment.
    ///
    /// A load after this encoder's own discard is resolved as the command buffer starts: zeros if the region is not
    /// initialized then, its earlier contents otherwise.
    mutating func noteAttachment(_ texture: TextureImpl, _ region: InitRegion, _ plan: AttachmentInitPlan) {
        if plan.before == .requireInitialized, require(texture, region) == .zeroFillHere {
            recordRequirement(texture, region)
        }
        switch plan.after {
        case .unchanged:
            break
        case .written, .zeroedAfterPass:
            noteWritten(texture, region)
        case .discarded:
            noteDiscarded(texture, region)
        }
    }

    mutating func noteDiscarded(_ texture: TextureImpl, _ region: InitRegion) {
        effects.append(Entry(texture: texture, region: region, effect: .discarded))
        texture.didRecordDiscard()
    }

    private func lastEffect(_ texture: TextureImpl, _ region: InitRegion) -> Effect? {
        for entry in effects.reversed() where entry.texture === texture && entry.region == region {
            return entry.effect
        }
        return nil
    }

    consuming func apply(_ token: borrowing CommitToken) {
        for entry in effects {
            switch entry.effect {
            case .written:
                entry.texture.markInitialized(entry.region, token)
            case .discarded:
                entry.texture.markUninitialized(entry.region)
                entry.texture.didSettleDiscard()
            }
        }
        effects = []
    }

    deinit {
        for entry in effects where entry.effect == .discarded {
            entry.texture.didSettleDiscard()
        }
    }
}

/// What a render pass attachment needs before the pass and leaves after it, for one aspect.
struct AttachmentInitPlan: Equatable {
    enum Before {
        case nothing
        case requireInitialized
    }

    enum After {
        case unchanged
        case written
        case discarded
        /// The pass ends with a zero clear of the attachment (runClearEncoder after endEncoding), which writes it.
        case zeroedAfterPass
    }

    let before: Before
    let after: After
}

/// The plan of every (loadOp, storeOp) of a color, depth or stencil attachment.
///
/// A 3D attachment writes one depth plane of a mip level that is initialized as a whole, so it always needs the level
/// initialized and never discards it.
func attachmentInitPlan(
    load: WebGPU.LoadOp?,
    store: WebGPU.StoreOp?,
    readOnly: Bool,
    isVolume: Bool,
    isTransient: Bool
) -> AttachmentInitPlan {
    if isTransient {
        // Memoryless: never stored, never loaded (validation requires clear + discard).
        return AttachmentInitPlan(before: .nothing, after: .unchanged)
    }
    if readOnly {
        return AttachmentInitPlan(before: .requireInitialized, after: .unchanged)
    }
    switch (load, store) {
    case (.Clear, .Store):
        return AttachmentInitPlan(before: isVolume ? .requireInitialized : .nothing, after: .written)
    case (.Clear, .Discard):
        return isVolume
            ? AttachmentInitPlan(before: .requireInitialized, after: .zeroedAfterPass)
            : AttachmentInitPlan(before: .nothing, after: .discarded)
    case (.Load, .Store):
        return AttachmentInitPlan(before: .requireInitialized, after: .written)
    case (.Load, .Discard):
        return AttachmentInitPlan(before: .requireInitialized, after: .zeroedAfterPass)
    default:
        // Only an aspect without ops reaches here, and validation has rejected a pass that writes one.
        return AttachmentInitPlan(before: .requireInitialized, after: .unchanged)
    }
}
