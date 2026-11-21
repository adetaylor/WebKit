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

// RenderLayer as a uniquely owned type; RenderLayerOwners, the store that owns every renderer's layer; and
// RenderLayerLinks, the only writer of the layers' tree links, whose edits only RenderLayerTree.swift can call.
// RenderLayerModelObject's C++ (RenderLayerOwnership.cpp) holds the store and is the only code that can make it or reach
// it.

internal import WebCore_Private

/// The argument of RenderLayer's factory. Only this file can make one (its stored property is private to this file, so
/// an initializer elsewhere cannot initialize it), so only the store below can make a layer.
struct RenderLayerCreation {
    fileprivate let renderer: WebCore.RenderLayerModelObject

    fileprivate init(_ renderer: WebCore.RenderLayerModelObject) {
        self.renderer = renderer
    }
}

// WebCore.RenderLayerFactory names this file in SWIFT_PRIVATE_FILEID: only this file can make or claim a layer, or
// read or write its links and its owner state.
extension WebCore.RenderLayerFactory {
    fileprivate static func make(_ creation: RenderLayerCreation) -> WebCore.RenderLayer {
        create(creation.renderer)
    }

    fileprivate static func claimLayer(_ layer: WebCore.RenderLayer) -> Bool {
        claim(layer)
    }

    fileprivate static func layerDestructionCount() -> UInt64 {
        destructionCount()
    }

    // Called only by make, once per layer.
    fileprivate static func writeOwnerHandle(of layer: WebCore.RenderLayer, _ handle: UInt64) {
        setOwnerHandle(layer, handle)
    }

    // Called only by prepareForRelease, once per layer, after the layer is unlinked and before its release.
    fileprivate static func markDropping(_ layer: WebCore.LayerRef) {
        setDropping(layer)
    }
}

extension WebCore.RenderLayer: UniquelyOwnable {
    typealias FactoryArgument = RenderLayerCreation
    typealias Identity = WebCore.LayerRef
    typealias OwnerAttachment = LayerWeakFields

    static func makeForUniqueOwner(
        _ creation: RenderLayerCreation,
        token: borrowing UniqueOwnerToken<WebCore.RenderLayer>
    ) -> WebCore.RenderLayer {
        WebCore.RenderLayerFactory.make(creation)
    }

    func claimUniqueOwner(token: borrowing UniqueOwnerToken<WebCore.RenderLayer>) -> Bool {
        WebCore.RenderLayerFactory.claimLayer(self)
    }

    static func destructionCountForUniqueOwner(token: borrowing UniqueOwnerToken<WebCore.RenderLayer>) -> UInt64 {
        WebCore.RenderLayerFactory.layerDestructionCount()
    }

    func identityForUniqueOwner(token: borrowing UniqueOwnerToken<WebCore.RenderLayer>) -> WebCore.LayerRef {
        WebCore.LayerRef(self)
    }

    // While a layer is being released, a weak reference to it gives only its identity.
    static func dyingObjectForUniqueOwner(
        _ layer: WebCore.LayerRef,
        token: borrowing UniqueOwnerToken<WebCore.RenderLayer>
    ) -> WebCore.RenderLayer? {
        nil
    }

    // Every release of a layer's owner: unlinks the layer first when its render tree is being destroyed, traps if it is
    // still linked, and marks it dropping, so that no edit can link it again.
    static func prepareForRelease(
        _ layer: WebCore.LayerRef,
        teardown: Bool,
        token: borrowing UniqueOwnerToken<WebCore.RenderLayer>
    ) {
        WebCore.RenderLayerFactory.unlinkForDrop(layer, teardown: teardown)
        WebCore.RenderLayerFactory.markDropping(layer)
    }

    static func isSameObject(_ a: WebCore.RenderLayer, _ b: WebCore.RenderLayer) -> Bool {
        WebCore.LayerRef(a) == WebCore.LayerRef(b)
    }

    static func isSameIdentity(_ a: WebCore.LayerRef, _ b: WebCore.LayerRef) -> Bool {
        a == b
    }
}

/// Whether a and b are the same layer, or both nil.
func isSameRenderLayer(_ a: WebCore.RenderLayer?, _ b: WebCore.RenderLayer?) -> Bool {
    WebCore.LayerRef(a) == WebCore.LayerRef(b)
}

/// The weak references a layer keeps to other layers, made when the first is set and kept until the layer's release
/// ends.
final class LayerWeakFields {
    fileprivate var backingProvider = UniqueOwnerWeak<WebCore.RenderLayer>()
    fileprivate var backingProviderAtEndOfCompositingUpdate = UniqueOwnerWeak<WebCore.RenderLayer>()
    fileprivate var enclosingPagination = UniqueOwnerWeak<WebCore.RenderLayer>()

    fileprivate init() {}
}

/// The only writer of the layers' tree links: each edit writes the links RenderLayer::addChild and removeChild write. The
/// edits take a RenderLayerLinkEdit, which only RenderLayerTree.swift can make: its callers update what depends on the
/// links.
enum RenderLayerLinks {
    /// Links child as parent's last child, or before `before`, which must be one of parent's children. Traps unless all
    /// three are owned layers and child has no parent and no siblings. Inlined into its callers' edits, so that an edit
    /// is one frame.
    @inline(always)
    static func add(
        _ child: WebCore.RenderLayer,
        to parent: WebCore.RenderLayer,
        before: WebCore.RenderLayer?,
        _ edit: borrowing RenderLayerLinkEdit
    ) {
        WebCore.RenderLayerFactory.linkChild(child, to: parent, before: before)
    }

    /// Takes child out of parent's children. Child need not be one of them: one that is unlinked stays so, and one that is
    /// another layer's child also leaves that layer's first and last child. Traps unless both are owned layers.
    ///
    /// The paint-order lists name layers by raw pointer, so the removal dirties the lists that may name child, as
    /// RenderLayer::removeChild does: after its siblings and its parent's first and last child no longer name it, and
    /// while its own links still lead to its stacking context. Nothing between these steps can free a layer or read a
    /// list. A child of another layer leaves that layer's lists too, so that no list names it once it is unlinked.
    @inline(always)
    static func remove(_ child: WebCore.RenderLayer, from parent: WebCore.RenderLayer, _ edit: borrowing RenderLayerLinkEdit) {
        let childHasOtherParent = WebCore.RenderLayerFactory.unlinkChildFromSiblings(child, from: parent)
        WebCore.RenderLayerAncestorWalker.dirtyPaintOrderListsOnChildChange(parent, child)
        if childHasOtherParent {
            // Its own parent's normal-flow list may still name it, and nothing would dirty that list later.
            WebCore.RenderLayerAncestorWalker.dirtyPaintOrderListsOfParent(child)
        }
        WebCore.RenderLayerFactory.clearLinks(ofUnlinkedChild: child)
    }
}

// The link edits, in RenderLayerFactory's extension so that they can read and write the links. A link names a live
// layer: a layer is linked only while its owner holds it, every edit keeps the links symmetric by its preconditions, and
// the drop unlinks a layer before it frees it. A LayerRef below is a layer the caller holds a counted reference to, or a
// link of one read with nothing called between.
extension WebCore.RenderLayerFactory {
    @inline(always)
    fileprivate static func linkChild(_ child: WebCore.RenderLayer, to parent: WebCore.RenderLayer, before: WebCore.RenderLayer?) {
        let child = WebCore.LayerRef(child)
        let parent = WebCore.LayerRef(parent)
        let before = WebCore.LayerRef(before)
        let none = WebCore.LayerRef()
        precondition(
            isOwned(child) && isOwned(parent) && (before == none || isOwned(before)),
            "RenderLayerFactory: a layer that is not owned"
        )
        precondition(!(child == parent), "RenderLayerFactory: a child of itself")
        precondition(
            WebCore.RenderLayerFactory.parent(child) == none && WebCore.RenderLayerFactory.previousSibling(child) == none
                && WebCore.RenderLayerFactory.nextSibling(child) == none,
            "RenderLayerFactory: the child is already linked"
        )
        precondition(
            before == none || WebCore.RenderLayerFactory.parent(before) == parent,
            "RenderLayerFactory: the next sibling is not a child of the parent"
        )
        let previous = before == none ? WebCore.RenderLayerFactory.lastChild(parent) : WebCore.RenderLayerFactory.previousSibling(before)
        if previous == none {
            WebCore.RenderLayerFactory.setFirstChild(parent, child)
        } else {
            WebCore.RenderLayerFactory.setPreviousSibling(child, previous)
            WebCore.RenderLayerFactory.setNextSibling(previous, child)
        }
        if before == none {
            WebCore.RenderLayerFactory.setLastChild(parent, child)
        } else {
            WebCore.RenderLayerFactory.setPreviousSibling(before, child)
            WebCore.RenderLayerFactory.setNextSibling(child, before)
        }
        WebCore.RenderLayerFactory.setParent(child, parent)
    }

    // The first part of RenderLayerLinks.remove: child's siblings and its parent's first and last child no longer name
    // it; its own links are left for clearLinks(ofUnlinkedChild:). Returns whether child's parent is a layer other than
    // `parent`.
    @inline(always)
    fileprivate static func unlinkChildFromSiblings(_ child: WebCore.RenderLayer, from parent: WebCore.RenderLayer) -> Bool {
        let child = WebCore.LayerRef(child)
        let parent = WebCore.LayerRef(parent)
        let none = WebCore.LayerRef()
        precondition(isOwned(child) && isOwned(parent), "RenderLayerFactory: a layer that is not owned")
        let previous = WebCore.RenderLayerFactory.previousSibling(child)
        let next = WebCore.RenderLayerFactory.nextSibling(child)
        if !(previous == none) {
            WebCore.RenderLayerFactory.setNextSibling(previous, next)
        }
        if !(next == none) {
            WebCore.RenderLayerFactory.setPreviousSibling(next, previous)
        }
        leaveFirstAndLast(child, of: parent, previous, next)
        let otherParent = WebCore.RenderLayerFactory.parent(child)
        let childHasOtherParent = !(otherParent == none) && !(otherParent == parent)
        if childHasOtherParent {
            leaveFirstAndLast(child, of: otherParent, previous, next)
        }
        return childHasOtherParent
    }

    // The second part of RenderLayerLinks.remove.
    @inline(always)
    fileprivate static func clearLinks(ofUnlinkedChild child: WebCore.RenderLayer) {
        let child = WebCore.LayerRef(child)
        let none = WebCore.LayerRef()
        WebCore.RenderLayerFactory.setPreviousSibling(child, none)
        WebCore.RenderLayerFactory.setNextSibling(child, none)
        WebCore.RenderLayerFactory.setParent(child, none)
    }

    /// Unlinks a layer whose owner is dropping it. With teardown, takes it out of its parent's children or its siblings,
    /// and leaves its children without a parent, linked to each other; otherwise it must have no links. Traps unless its
    /// links are then all clear.
    fileprivate static func unlinkForDrop(_ layer: WebCore.LayerRef, teardown: Bool) {
        let none = WebCore.LayerRef()
        if teardown {
            let parent = WebCore.RenderLayerFactory.parent(layer)
            let previous = WebCore.RenderLayerFactory.previousSibling(layer)
            let next = WebCore.RenderLayerFactory.nextSibling(layer)
            if !(previous == none) {
                WebCore.RenderLayerFactory.setNextSibling(previous, next)
            } else if !(parent == none) {
                WebCore.RenderLayerFactory.setFirstChild(parent, next)
            }
            if !(next == none) {
                WebCore.RenderLayerFactory.setPreviousSibling(next, previous)
            } else if !(parent == none) {
                WebCore.RenderLayerFactory.setLastChild(parent, previous)
            }
            var child = WebCore.RenderLayerFactory.firstChild(layer)
            while !(child == none) {
                WebCore.RenderLayerFactory.setParent(child, none)
                child = WebCore.RenderLayerFactory.nextSibling(child)
            }
            WebCore.RenderLayerFactory.setParent(layer, none)
            WebCore.RenderLayerFactory.setPreviousSibling(layer, none)
            WebCore.RenderLayerFactory.setNextSibling(layer, none)
            WebCore.RenderLayerFactory.setFirstChild(layer, none)
            WebCore.RenderLayerFactory.setLastChild(layer, none)
        }
        precondition(
            WebCore.RenderLayerFactory.parent(layer) == none && WebCore.RenderLayerFactory.previousSibling(layer) == none
                && WebCore.RenderLayerFactory.nextSibling(layer) == none && WebCore.RenderLayerFactory.firstChild(layer) == none
                && WebCore.RenderLayerFactory.lastChild(layer) == none,
            "RenderLayerFactory: the layer is still linked"
        )
    }

    private static func leaveFirstAndLast(
        _ child: WebCore.LayerRef,
        of parent: WebCore.LayerRef,
        _ previous: WebCore.LayerRef,
        _ next: WebCore.LayerRef
    ) {
        if WebCore.RenderLayerFactory.firstChild(parent) == child {
            WebCore.RenderLayerFactory.setFirstChild(parent, next)
        }
        if WebCore.RenderLayerFactory.lastChild(parent) == child {
            WebCore.RenderLayerFactory.setLastChild(parent, previous)
        }
    }

    /// Whether the store owns the layer, and is not dropping it.
    private static func isOwned(_ layer: WebCore.LayerRef) -> Bool {
        WebCore.RenderLayerFactory.ownerState(layer) == 1
    }
}

@_expose(Cxx)
final class RenderLayerOwners {
    private let nodes = UniqueOwnerNodes<WebCore.RenderLayer>()

    @_expose(Cxx)
    init(_ key: WebCore.RenderLayerOwnersKey) {}

    /// Makes a layer for the renderer, owned by the store.
    @_expose(Cxx)
    func make(_ renderer: WebCore.RenderLayerModelObject) -> WebCore.CreatedRenderLayer {
        let handle = nodes.make(RenderLayerCreation(renderer))
        let layer = nodes.withView(handle) { $0.object }
        // Written once, before C++ sees the layer. Every entry below checks the handle against the layer.
        WebCore.RenderLayerFactory.writeOwnerHandle(of: layer, handle.bits)
        return WebCore.CreatedRenderLayer(owner: handle.bits, layer: WebCore.LayerRef(layer))
    }

    /// Frees the layer that the handle's owner owns, unlinking it first when its render tree is being destroyed. Traps if
    /// the handle names no owner, or another layer's, if the layer is linked outside teardown, and if anything else still
    /// holds the layer after the release. The layer comes as a LayerRef, so that this call holds no reference to it when
    /// the owner releases it.
    @_expose(Cxx)
    func drop(_ owner: UInt64, _ layer: WebCore.LayerRef, _ renderTreeBeingDestroyed: Bool) {
        nodes.drop(UniqueOwnerKey(bits: owner, identity: layer), teardown: renderTreeBeingDestroyed)
    }

    /// One of the layer's weak references (LayerWeakField), read without retaining its target. The layer may be one
    /// whose drop is releasing it.
    @_expose(Cxx)
    func weakField(_ field: UInt8, _ owner: UInt64, _ layer: WebCore.LayerRef) -> WebCore.LayerRef {
        let fields = nodes.attachment(UniqueOwnerKey(bits: owner, identity: layer))
        let weak: UniqueOwnerWeak<WebCore.RenderLayer>?
        // The values of WebCore::RenderLayer::LayerWeakField, pinned in RenderLayerOwnership.cpp.
        switch field {
        case 1:
            weak = fields?.backingProvider
        case 2:
            weak = fields?.backingProviderAtEndOfCompositingUpdate
        case 4:
            weak = fields?.enclosingPagination
        default:
            preconditionFailure("RenderLayerOwners: no such weak reference")
        }
        return weak?.identity ?? WebCore.LayerRef()
    }

    /// Sets one of the layer's weak references to the target, which must be a layer the store holds, or to none. The
    /// layer may be one whose drop is releasing it.
    @_expose(Cxx)
    func setWeakField(_ field: UInt8, _ owner: UInt64, _ layer: WebCore.LayerRef, _ targetOwner: UInt64, _ target: WebCore.LayerRef) {
        let key = UniqueOwnerKey<WebCore.RenderLayer>(bits: owner, identity: layer)
        let fields: LayerWeakFields?
        let weak: UniqueOwnerWeak<WebCore.RenderLayer>
        if target == WebCore.LayerRef() {
            fields = nodes.attachment(key)
            weak = UniqueOwnerWeak()
        } else {
            weak = nodes.weak(UniqueOwnerKey(bits: targetOwner, identity: target))
            fields = nodes.attachment(key, making: LayerWeakFields.init)
        }
        // The values of WebCore::RenderLayer::LayerWeakField, pinned in RenderLayerOwnership.cpp.
        switch field {
        case 1:
            fields?.backingProvider = weak
        case 2:
            fields?.backingProviderAtEndOfCompositingUpdate = weak
        case 4:
            fields?.enclosingPagination = weak
        default:
            preconditionFailure("RenderLayerOwners: no such weak reference")
        }
    }
}
