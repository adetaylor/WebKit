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

// Unique ownership of a reference-counted C++ object, with weak references and borrowed views. The owner's one strong
// reference is the object's owning count: dropping the owner frees the object, and the drop traps if anything else
// still holds a count. UniqueOwnerWeak references name the object's slot in a UniqueOwnerNodes, never the object.

#if !compiler(>=6.4)
#error("The RenderLayer Swift files need Swift 6.4 or later; WebCore does not link without them.")
#endif

/// Passed by UniqueOwner and UniqueOwnerNodes to the conforming type's requirements. Only this file can make one: its
/// stored property is private to this file, so an initializer elsewhere cannot initialize it. A token for one type
/// cannot be passed to another type's requirements.
struct UniqueOwnerToken<T>: ~Copyable {
    private let seal: UniqueOwnerSeal

    fileprivate init() {
        seal = UniqueOwnerSeal()
    }
}

private struct UniqueOwnerSeal {}

/// A C++ reference-counted type whose objects UniqueOwner owns.
protocol UniquelyOwnable {
    associatedtype FactoryArgument
    /// Names an object without holding a count on it.
    associatedtype Identity: BitwiseCopyable
    /// What the conformance keeps for an object beside its owner, in the object's node, from when it first asks for it
    /// until the object's release ends.
    associatedtype OwnerAttachment

    /// Allocates a new object, returning its only strong reference.
    static func makeForUniqueOwner(_ argument: FactoryArgument, token: borrowing UniqueOwnerToken<Self>) -> Self
    /// True the first time it is called on an object, false every later time.
    func claimUniqueOwner(token: borrowing UniqueOwnerToken<Self>) -> Bool
    /// The number of objects of the type whose destruction has begun. Releasing a reference changes it only by
    /// destroying an object.
    static func destructionCountForUniqueOwner(token: borrowing UniqueOwnerToken<Self>) -> UInt64
    /// The object's identity, the same for the whole of its life.
    func identityForUniqueOwner(token: borrowing UniqueOwnerToken<Self>) -> Identity
    /// The object that identity names, called only while that object's destruction runs; nil if the type cannot name
    /// it then.
    static func dyingObjectForUniqueOwner(_ identity: Identity, token: borrowing UniqueOwnerToken<Self>) -> Self?
    /// Called on every path that releases an owner, just before the release, with the identity of the object. With
    /// teardown, the argument of UniqueOwnerNodes.drop(_:teardown:), the object's other structures are being destroyed
    /// with it; every other path passes false.
    static func prepareForRelease(_ identity: Identity, teardown: Bool, token: borrowing UniqueOwnerToken<Self>)
    static func isSameObject(_ a: Self, _ b: Self) -> Bool
    static func isSameIdentity(_ a: Identity, _ b: Identity) -> Bool
}

extension UniquelyOwnable where Identity: Equatable {
    static func isSameIdentity(_ a: Identity, _ b: Identity) -> Bool {
        a == b
    }
}

/// The owner of one object. There is no other way to make one than make(_:), and no way to take the object out. Only
/// this file makes, inserts or drops an owner, so every owner ends through release(): in a node's release, in the nodes'
/// deinit, or in drop().
struct UniqueOwner<T: UniquelyOwnable>: ~Copyable {
    fileprivate let object: T

    fileprivate init(claimed object: T) {
        self.object = object
    }

    fileprivate static func make(_ argument: T.FactoryArgument) -> UniqueOwner<T> {
        let token = UniqueOwnerToken<T>()
        let object = T.makeForUniqueOwner(argument, token: token)
        precondition(object.claimUniqueOwner(token: token), "UniqueOwner: the object already has an owner")
        return UniqueOwner(claimed: object)
    }

    @_lifetime(borrow self)
    borrowing func view() -> UniqueOwnerView<T> {
        UniqueOwnerView(self)
    }

    borrowing func withView<R: ~Copyable>(_ body: (UniqueOwnerView<T>) throws -> R) rethrows -> R {
        try body(view())
    }

    /// Frees the object. Traps if anything else holds a count on it.
    fileprivate consuming func drop() {
        let identity = object.identityForUniqueOwner(token: UniqueOwnerToken())
        let survived = release(self, identity, teardown: false)
        precondition(!survived, "UniqueOwner: the object outlived its owner")
    }
}

/// Ends the owner of the object `identity` names, after the conformance prepares its release, and returns whether the
/// object survived the release.
private func release<T>(_ owner: consuming UniqueOwner<T>, _ identity: T.Identity, teardown: Bool) -> Bool {
    let token = UniqueOwnerToken<T>()
    T.prepareForRelease(identity, teardown: teardown, token: token)
    let before = T.destructionCountForUniqueOwner(token: token)
    _ = consume owner
    return T.destructionCountForUniqueOwner(token: token) == before
}

/// A borrowed view of an owned object. It cannot outlive the owner or the weak resolution it came from. Its object
/// is a counted reference, so a copy of it kept past a drop is caught by the drop.
struct UniqueOwnerView<T: UniquelyOwnable>: ~Escapable {
    let object: T

    @_lifetime(borrow owner)
    fileprivate init(_ owner: borrowing UniqueOwner<T>) {
        object = owner.object
    }

    @_lifetime(borrow strong)
    fileprivate init(resolved strong: borrowing T) {
        object = copy strong
    }
}

@available(*, unavailable)
extension UniqueOwnerView: Sendable {}

/// A weak reference to an object a UniqueOwnerNodes owns: the nodes' store, the object's slot, and the slot's generation
/// when the reference was made. It resolves to the object while its owner holds it and while the owner's drop destroys
/// it.
struct UniqueOwnerWeak<T: UniquelyOwnable>: CustomReflectable {
    fileprivate var store: UniqueOwnerNodesStore<T>?
    fileprivate var slot: UInt32
    fileprivate var generation: UInt32

    init() {
        store = nil
        slot = 0
        generation = 0
    }

    fileprivate init(_ store: UniqueOwnerNodesStore<T>, bits: UInt64) {
        self.store = store
        slot = UInt32(truncatingIfNeeded: bits & 0xffff_ffff)
        generation = UInt32(truncatingIfNeeded: bits >> 32)
    }

    func get() -> T? {
        guard let store else {
            return nil
        }
        if let object = store.core.object(slot, generation) {
            return object
        }
        let dying = store.core.dying(slot, generation)
        guard let dying else {
            return nil
        }
        return T.dyingObjectForUniqueOwner(dying, token: UniqueOwnerToken())
    }

    func withView<R: ~Copyable>(_ body: (UniqueOwnerView<T>) throws -> R) rethrows -> R? {
        guard let strong = get() else {
            return nil
        }
        return try body(UniqueOwnerView(resolved: strong))
    }

    /// The identity of the object get() resolves to, read without a count on the object.
    var identity: T.Identity? {
        store?.core.identity(slot, generation)
    }

    var isCleared: Bool {
        identity == nil
    }

    mutating func clear() {
        store = nil
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

@available(*, unavailable)
extension UniqueOwnerWeak: Sendable {}

/// Names an owner in one UniqueOwnerNodes: the node's slot in the low 32 bits, its generation in the high 32 bits.
struct UniqueOwnerHandle<T: UniquelyOwnable>: Equatable {
    fileprivate let storedBits: UInt64
    fileprivate let nodes: UniqueOwnerNodesBrand

    var bits: UInt64 { storedBits }

    static func == (a: UniqueOwnerHandle<T>, b: UniqueOwnerHandle<T>) -> Bool {
        a.storedBits == b.storedBits && a.nodes === b.nodes
    }
}

@available(*, unavailable)
extension UniqueOwnerHandle: Sendable {}

/// Names an owner from outside Swift: a handle's bits and the identity of the object they should name. An
/// UniqueOwnerNodes entry that takes one traps unless the bits name the owner of that object.
struct UniqueOwnerKey<T: UniquelyOwnable> {
    let bits: UInt64
    let identity: T.Identity
}

private final class UniqueOwnerNodesBrand {}

/// One object's owner and the state its weak references read, in the object's slot. A node holds an owner, or, while the
/// owner's drop releases the object, the object's identity; and the conformance's attachment for the object.
private struct UniqueOwnerNode<T: UniquelyOwnable>: ~Copyable {
    var owner: UniqueOwner<T>?
    /// The identity of the object the owner holds or, while isReleasing, of the object the owner's drop is releasing;
    /// nil while the node holds neither.
    var identity: T.Identity?
    var isReleasing = false
    var isFree = false
    var generation: UInt32
    var attachment: T.OwnerAttachment?

    init(generation: UInt32) {
        self.generation = generation
    }

    /// The identity of the object the owner holds.
    var owned: T.Identity? {
        isReleasing ? nil : identity
    }

    /// The identity of the object the owner's drop is releasing.
    var dying: T.Identity? {
        isReleasing ? identity : nil
    }
}

/// The nodes and the free slots of a UniqueOwnerNodes. No access to it runs code that can reach the nodes: the only calls
/// out of Swift inside one take a count on an object, and a value whose destruction can release an object (an owner, an
/// attachment, an identity, the core itself) is moved out first and destroyed after the access. A whole-module optimized
/// build (-O -wmo) then proves every access to it exclusive and checks none at run time; an -Onone or a per-file build
/// still checks them at run time.
private struct UniqueOwnerNodesCore<T: UniquelyOwnable>: ~Copyable {
    var nodes = UniqueArray<UniqueOwnerNode<T>>()
    var freeSlots = UniqueArray<UInt32>()
    /// The number of free slots whose index is at least half the number of slots.
    var upperFree = 0
    /// At least every generation a released slot had, and the first generation of every slot added after it: a slot
    /// added again at a released index never takes a generation that index has had.
    var generationFloor: UInt32 = 0

    /// The slot the bits name, if its node is in the bits' generation.
    func node(_ bits: UInt64) -> Int? {
        node(UInt32(truncatingIfNeeded: bits & 0xffff_ffff), UInt32(truncatingIfNeeded: bits >> 32))
    }

    /// The slot, if it exists and its node is in `generation`.
    func node(_ slot: UInt32, _ generation: UInt32) -> Int? {
        let index = Int(slot)
        guard index < nodes.count else {
            return nil
        }
        guard nodes[index].generation == generation else {
            return nil
        }
        return index
    }

    /// The object whose owner the slot's node holds, if the node is in `generation`.
    func object(_ slot: UInt32, _ generation: UInt32) -> T? {
        guard let index = node(slot, generation) else {
            return nil
        }
        return object(index)
    }

    /// The object whose owner the node at `index` holds.
    func object(_ index: Int) -> T? {
        switch nodes[index].owner {
        case .some(let owner):
            return owner.object
        case .none:
            return nil
        }
    }

    /// The identity of the object whose release the slot's node is in, if the node is in `generation`.
    func dying(_ slot: UInt32, _ generation: UInt32) -> T.Identity? {
        guard let index = node(slot, generation) else {
            return nil
        }
        return nodes[index].dying
    }

    /// The identity of the object the slot's node holds or releases, if the node is in `generation`.
    func identity(_ slot: UInt32, _ generation: UInt32) -> T.Identity? {
        guard let index = node(slot, generation) else {
            return nil
        }
        return nodes[index].identity
    }

    /// The identity of the object whose owner the bits' node holds, if the node is in the bits' generation.
    func liveIdentity(_ bits: UInt64) -> T.Identity? {
        guard let index = node(bits) else {
            return nil
        }
        return nodes[index].owned
    }

    /// The bits' slot and its object's identity, if its node holds an owner in the bits' generation.
    func liveNode(_ bits: UInt64) -> (index: Int, identity: T.Identity)? {
        guard let index = node(bits), let identity = nodes[index].owned else {
            return nil
        }
        return (index, identity)
    }

    /// Takes a free slot for the object `identity` names, and returns the slot. UniqueOwnerNodes adds a slot first when
    /// none is free, and then moves the object's owner into the slot's node.
    mutating func claim(_ identity: T.Identity) -> Int {
        guard let slot = freeSlots.popLast() else {
            preconditionFailure("UniqueOwnerNodes: no free slot")
        }
        let index = Int(slot)
        nodes[index].identity = identity
        nodes[index].isFree = false
        if index >= nodes.count / 2 {
            upperFree -= 1
        }
        return index
    }

    /// The bits that name the slot at `index` in its node's generation.
    func bits(_ index: Int) -> UInt64 {
        UInt64(nodes[index].generation) << 32 | UInt64(index)
    }

    /// Moves the node at `index` from holding its object's owner to releasing the object, and returns the object's
    /// identity; nil if the node holds no owner.
    mutating func beginRelease(_ index: Int) -> T.Identity? {
        guard let identity = nodes[index].owned else {
            return nil
        }
        nodes[index].isReleasing = true
        return identity
    }

    /// Advances the generation of the node at `index`, after its release. Returns false, leaving the node as it is, if
    /// the generation would wrap: the slot is then never used again.
    mutating func advanceGeneration(_ index: Int) -> Bool {
        guard nodes[index].generation != UInt32.max else {
            return false
        }
        nodes[index].generation += 1
        return true
    }

    /// Marks a slot just pushed to freeSlots as free.
    mutating func markFree(_ index: Int) {
        nodes[index].isFree = true
        if index >= nodes.count / 2 {
            upperFree += 1
        }
    }

    /// Moves the upper half's bound after a slot was added, before the new slot is marked free.
    mutating func slotAdded() {
        let count = nodes.count
        // From an odd count to an even one, slot count / 2 - 1 leaves the upper half.
        if count % 2 == 0 && nodes[count / 2 - 1].isFree {
            upperFree -= 1
        }
    }

    /// The number of slots to keep if every slot of the upper half is free and there are at least
    /// UniqueOwnerNodes.slotsNeverReleased slots: 1 plus the highest slot that is not free. Otherwise nil.
    func countAfterRelease(_ slotsNeverReleased: Int) -> Int? {
        let count = nodes.count
        guard count >= slotsNeverReleased && upperFree == count - count / 2 else {
            return nil
        }
        var top = count / 2
        while top > 0 && nodes[top - 1].isFree {
            top -= 1
        }
        return top
    }

    /// Raises the generation floor to the generations of the slots from `top` on, which are free.
    mutating func raiseGenerationFloor(releasing top: Int) {
        for index in top..<nodes.count {
            precondition(nodes[index].isFree, "UniqueOwnerNodes: releasing a slot in use")
            generationFloor = max(generationFloor, nodes[index].generation)
        }
    }

    /// Replaces the nodes and the free slots with `other`'s, and returns the ones replaced, so that they are destroyed
    /// outside the access to the core.
    mutating func exchange(_ other: consuming UniqueOwnerNodesCore<T>) -> UniqueOwnerNodesCore<T> {
        let replaced = consume self
        self = other
        return replaced
    }

    /// Counts upperFree again after the slots were released.
    mutating func recountUpperFree() {
        upperFree = 0
        for index in (nodes.count / 2)..<nodes.count where nodes[index].isFree {
            upperFree += 1
        }
    }
}

/// The nodes of a UniqueOwnerNodes. Its weak references hold it, and name a slot in it.
private final class UniqueOwnerNodesStore<T: UniquelyOwnable> {
    var core = UniqueOwnerNodesCore<T>()
}

/// Owners held by handle, one node per object. A dropped node's generation advances, so a stale handle traps and a
/// stale weak reference resolves to nil; a node whose generation would wrap is never reused. An owner leaves its node
/// only to be released. When the upper half of the slots is free, the free slots above the highest one in use are
/// released; a slot added again at a released index starts at generationFloor.
final class UniqueOwnerNodes<T: UniquelyOwnable>: CustomReflectable {
    /// With fewer slots all are kept: at most this many free slots are kept without a release.
    static var slotsNeverReleased: Int { 256 }

    private let store = UniqueOwnerNodesStore<T>()
    private let brand = UniqueOwnerNodesBrand()
    init() {}

    /// The number of slots, live and free; a slot's index is below it.
    var slotCount: Int {
        store.core.nodes.count
    }

    /// Releases the owners left, without the survivor check, so that no weak reference keeps an object, then the nodes.
    deinit {
        for index in store.core.nodes.indices {
            if let owner = store.core.nodes[index].owner.take() {
                guard let identity = store.core.nodes[index].owned else {
                    preconditionFailure("UniqueOwnerNodes: an owner without its object's identity")
                }
                _ = store.core.nodes[index].identity.take()
                _ = store.core.nodes[index].attachment.take()
                _ = release(owner, identity, teardown: false)
            }
        }
        _ = store.core.exchange(UniqueOwnerNodesCore())
    }

    fileprivate func insert(_ owner: consuming UniqueOwner<T>) -> UniqueOwnerHandle<T> {
        let identity = owner.object.identityForUniqueOwner(token: UniqueOwnerToken())
        if store.core.freeSlots.isEmpty {
            addSlot()
        }
        let index = store.core.claim(identity)
        // Assigning the owner would destroy the node's old value, which can release an object, inside the access.
        var previous: UniqueOwner<T>? = consume owner
        swap(&previous, &store.core.nodes[index].owner)
        precondition(previous == nil, "UniqueOwnerNodes: a free slot holds an owner")
        return UniqueOwnerHandle(storedBits: store.core.bits(index), nodes: brand)
    }

    func make(_ argument: T.FactoryArgument) -> UniqueOwnerHandle<T> {
        insert(UniqueOwner.make(argument))
    }

    /// The handle the bits name. Traps unless its node holds `object`.
    func handle(bits: UInt64, expecting object: T) -> UniqueOwnerHandle<T> {
        guard let live = store.core.liveNode(bits), let current = store.core.object(live.index) else {
            preconditionFailure("UniqueOwnerNodes: stale handle")
        }
        precondition(T.isSameObject(current, object), "UniqueOwnerNodes: the handle names another object")
        return UniqueOwnerHandle(storedBits: bits, nodes: brand)
    }

    /// Runs body with a view of the handle's object. The view holds a count on the object, so dropping that handle inside
    /// body traps.
    func withView<R: ~Copyable>(_ handle: UniqueOwnerHandle<T>, _ body: (UniqueOwnerView<T>) throws -> R) rethrows -> R {
        guard let strong = store.core.object(checkedNode(handle)) else {
            preconditionFailure("UniqueOwnerNodes: stale handle")
        }
        return try body(UniqueOwnerView(resolved: strong))
    }

    func weak(_ handle: UniqueOwnerHandle<T>) -> UniqueOwnerWeak<T> {
        _ = checkedNode(handle)
        return UniqueOwnerWeak(store, bits: handle.storedBits)
    }

    func weak(_ key: UniqueOwnerKey<T>) -> UniqueOwnerWeak<T> {
        guard let live = store.core.liveNode(key.bits), matches(key, live.identity) else {
            preconditionFailure("UniqueOwnerNodes: the handle names no owner of the object")
        }
        return UniqueOwnerWeak(store, bits: key.bits)
    }

    /// Whether the key's bits name the owner of its object.
    func holds(_ key: UniqueOwnerKey<T>) -> Bool {
        matches(key, store.core.liveIdentity(key.bits))
    }

    /// The attachment of the key's object, which its owner holds or whose drop is releasing it. Traps for any other key.
    func attachment(_ key: UniqueOwnerKey<T>) -> T.OwnerAttachment? {
        store.core.nodes[attachedNode(key)].attachment
    }

    /// The attachment of the key's object, made by `make` if it has none, as attachment(_:) does.
    func attachment(_ key: UniqueOwnerKey<T>, making make: () -> T.OwnerAttachment) -> T.OwnerAttachment {
        if let attachment = store.core.nodes[attachedNode(key)].attachment {
            return attachment
        }
        let attachment = make()
        // make can change the nodes: the key is checked again.
        let index = attachedNode(key)
        var previous: T.OwnerAttachment? = attachment
        swap(&previous, &store.core.nodes[index].attachment)
        // The attachment replaced, if make set one, is released here, outside the access.
        return attachment
    }

    /// Frees the handle's object. Traps if anything else holds a count on it.
    func drop(_ handle: UniqueOwnerHandle<T>) {
        releaseNode(at: checkedNode(handle), teardown: false)
    }

    /// Frees the key's object, passing teardown to the conformance's prepareForRelease. Traps if anything else holds a
    /// count on the object.
    func drop(_ key: UniqueOwnerKey<T>, teardown: Bool) {
        check(key, store.core.liveIdentity(key.bits))
        // The identity check calls the conformance: the bits must still name a live node, in their generation, after it.
        guard let live = store.core.liveNode(key.bits) else {
            preconditionFailure("UniqueOwnerNodes: the handle names no owner of the object")
        }
        releaseNode(at: live.index, teardown: teardown)
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    private func checkedNode(_ handle: UniqueOwnerHandle<T>) -> Int {
        precondition(handle.nodes === brand, "UniqueOwnerNodes: the handle belongs to other nodes")
        guard let live = store.core.liveNode(handle.storedBits) else {
            preconditionFailure("UniqueOwnerNodes: stale handle")
        }
        return live.index
    }

    /// The key's slot, if its node holds the owner of the key's object or its drop is releasing that object.
    private func attachedNode(_ key: UniqueOwnerKey<T>) -> Int {
        guard let index = store.core.node(key.bits), matches(key, store.core.nodes[index].identity) else {
            preconditionFailure("UniqueOwnerNodes: the handle names no owner of the object")
        }
        // The compare calls the conformance, which can drop the node: the bits must still name the same slot after it.
        precondition(store.core.node(key.bits) == index, "UniqueOwnerNodes: the handle names no owner of the object")
        return index
    }

    /// Whether `current`, the identity the key's bits name, is the key's object. It is copied out first, so that no
    /// access to the nodes is open while the identities are compared.
    private func matches(_ key: UniqueOwnerKey<T>, _ current: T.Identity?) -> Bool {
        guard let current else {
            return false
        }
        return T.isSameIdentity(current, key.identity)
    }

    private func check(_ key: UniqueOwnerKey<T>, _ current: T.Identity?) {
        precondition(matches(key, current), "UniqueOwnerNodes: the handle names no owner of the object")
    }

    /// Takes the owner out of a live node and releases it. While the release runs, the node names the object for weak
    /// references and holds no owner, so its handle is stale; the node's attachment goes, and its slot is freed, after
    /// the release.
    private func releaseNode(at index: Int, teardown: Bool) {
        guard let identity = store.core.beginRelease(index), let owner = store.core.nodes[index].owner.take() else {
            preconditionFailure("UniqueOwnerNodes: stale handle")
        }
        let survived = release(owner, identity, teardown: teardown)
        store.core.nodes[index].identity = nil
        store.core.nodes[index].isReleasing = false
        precondition(!survived, "UniqueOwnerNodes: the object outlived its owner")
        _ = store.core.nodes[index].attachment.take()
        guard store.core.advanceGeneration(index) else {
            return
        }
        appendFreeSlot(UInt32(truncatingIfNeeded: index))
        releaseFreeSlots()
    }

    // The core's arrays grow outside any access to `core`: each is moved out, appended to and moved back. An allocation
    // inside an access to `core` keeps the optimizer from proving that no two of its accesses overlap, and every access
    // then stays a run-time exclusivity check.

    /// Adds a slot and its node, and frees it. It starts at the generation floor.
    private func addSlot() {
        precondition(store.core.nodes.count < Int(UInt32.max), "UniqueOwnerNodes: out of slots")
        let index = UInt32(store.core.nodes.count)
        let node = UniqueOwnerNode<T>(generation: store.core.generationFloor)
        var nodes = UniqueArray<UniqueOwnerNode<T>>()
        swap(&nodes, &store.core.nodes)
        nodes.append(node)
        swap(&nodes, &store.core.nodes)
        store.core.slotAdded()
        appendFreeSlot(index)
    }

    private func appendFreeSlot(_ index: UInt32) {
        var freeSlots = UniqueArray<UInt32>()
        swap(&freeSlots, &store.core.freeSlots)
        freeSlots.append(index)
        swap(&freeSlots, &store.core.freeSlots)
        store.core.markFree(Int(index))
    }

    /// Releases the free slots above the highest slot in use, when the upper half of the slots is free. Each slot
    /// released was added once, and at least half the slots go, so the copies cost O(1) per slot added. A slot that is
    /// not free (one in use, one whose drop is releasing its object, one whose generation would wrap) is never released.
    /// A weak reference that names a released slot resolves to nil: the slot is gone, or was added again at a later
    /// generation.
    private func releaseFreeSlots() {
        guard let top = store.core.countAfterRelease(Self.slotsNeverReleased) else {
            return
        }
        store.core.raiseGenerationFloor(releasing: top)
        let released = store.core.nodes.count - top
        var freeSlots = UniqueArray<UInt32>()
        swap(&freeSlots, &store.core.freeSlots)
        var kept = UniqueArray<UInt32>()
        kept.reserveCapacity(freeSlots.count - released)
        for index in freeSlots.indices where Int(freeSlots[index]) < top {
            kept.append(freeSlots[index])
        }
        swap(&kept, &store.core.freeSlots)
        var nodes = UniqueArray<UniqueOwnerNode<T>>()
        swap(&nodes, &store.core.nodes)
        nodes.removeLast(released)
        nodes.setCapacity(top)
        swap(&nodes, &store.core.nodes)
        store.core.recountUpperFree()
    }
}
