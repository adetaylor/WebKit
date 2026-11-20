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

/*
 * Copyright (C) 2006-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2013-2014 Google Inc. All rights reserved.
 * Copyright (C) 2019 Adobe. All rights reserved.
 * Copyright (c) 2020, 2021, 2022, 2026 Igalia S.L.
 *
 * Portions are Copyright (C) 1998 Netscape Communications Corporation.
 *
 * Other contributors:
 *   Robert O'Callahan <roc+@cs.cmu.edu>
 *   David Baron <dbaron@fas.harvard.edu>
 *   Christian Biesinger <cbiesinger@web.de>
 *   Randall Jesup <rjesup@wgate.com>
 *   Roland Mainz <roland.mainz@informatik.med.uni-giessen.de>
 *   Josh Soref <timeless@mac.com>
 *   Boris Zbarsky <bzbarsky@mit.edu>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 * Alternatively, the contents of this file may be used under the terms
 * of either the Mozilla Public License Version 1.1, found at
 * http://www.mozilla.org/MPL/ (the "MPL") or the GNU General Public
 * License Version 2.0, found at http://www.fsf.org/copyleft/gpl.html
 * (the "GPL"), in which case the provisions of the MPL or the GPL are
 * applicable instead of those above.  If you wish to allow use of your
 * version of this file only under the terms of one of those two
 * licenses (the MPL or the GPL) and not to allow others to use your
 * version of this file under the LGPL, indicate your decision by
 * deletingthe provisions above and replace them with the notice and
 * other provisions required by the MPL or the GPL, as the case may be.
 * If you do not delete the provisions above, a recipient may use your
 * version of this file under any of the LGPL, the MPL or the GPL.
 */

/*
 * Copyright (C) 2003-2024 Apple Inc. All rights reserved.
 * Copyright (c) 2020 Igalia S.L.
 *
 * Portions are Copyright (C) 1998 Netscape Communications Corporation.
 *
 * Other contributors:
 *   Robert O'Callahan <roc+@cs.cmu.edu>
 *   David Baron <dbaron@fas.harvard.edu>
 *   Christian Biesinger <cbiesinger@web.de>
 *   Randall Jesup <rjesup@wgate.com>
 *   Roland Mainz <roland.mainz@informatik.med.uni-giessen.de>
 *   Josh Soref <timeless@mac.com>
 *   Boris Zbarsky <bzbarsky@mit.edu>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 * Alternatively, the contents of this file may be used under the terms
 * of either the Mozilla Public License Version 1.1, found at
 * http://www.mozilla.org/MPL/ (the "MPL") or the GNU General Public
 * License Version 2.0, found at http://www.fsf.org/copyleft/gpl.html
 * (the "GPL"), in which case the provisions of the MPL or the GPL are
 * applicable instead of those above.  If you wish to allow use of your
 * version of this file only under the terms of one of those two
 * licenses (the MPL or the GPL) and not to allow others to use your
 * version of this file under the LGPL, indicate your decision by
 * deletingthe provisions above and replace them with the notice and
 * other provisions required by the MPL or the GPL, as the case may be.
 * If you do not delete the provisions above, a recipient may use your
 * version of this file under any of the LGPL, the MPL or the GPL.
 */

// The builders of the paint-order lists, for RenderLayerTree.swift. WebCore.RenderLayerPaintOrderListWriter names this
// file in SWIFT_PRIVATE_FILEID: only this file can write a list. A list holds plain pointers, so a builder takes only the
// layers whose removal dirties the list: a layer's normal-flow children for its normal-flow list, and for a stacking
// context's z-order lists the layers below it that are not normal-flow-only, short of another stacking context. The
// writers trap if the layer's list mutation is not allowed, or if a layer can be freed during an append.

internal import Synchronization
internal import WebCore_Private

private struct ZOrderEntry {
    var zIndex: Int32
    var layer: WebCore.LayerRef
}

// The working arrays of the rebuilds, kept from one rebuild to the next so that each reuses the capacity of the last, up
// to 4096 entries (64 KB for the z-order array, 32 KB for the normal-flow one); a larger one is freed at the end of its
// rebuild. A rebuild that finds its array in use (a rebuild reached from inside another) works in a local array instead.
// The normal-flow array is a UniqueArray, which has a single owner, so its appends make no copy-on-write check.
private let zOrderEntriesScratch = Mutex<[ZOrderEntry]>([])
private let zOrderEntriesScratchCapacityLimit = 4096
private let normalFlowListScratch = Mutex<UniqueArray<WebCore.LayerRef>>(UniqueArray())
private let normalFlowListScratchCapacityLimit = 4096

// The writer's private members are reachable only from an extension in this file.
extension WebCore.RenderLayerPaintOrderListWriter {
    /// Empties the layer's normal-flow list.
    @inline(always)
    static func clearNormalFlowList(_ layer: WebCore.RenderLayer) {
        reset(layer, .NormalFlow, 0, false)
    }

    /// Empties the layer's z-order lists.
    @inline(always)
    static func clearZOrderLists(_ layer: WebCore.RenderLayer) {
        reset(layer, .Positive, 0, false)
        reset(layer, .Negative, 0, false)
    }

    /// Frees the layer's z-order lists.
    static func releaseZOrderLists(_ layer: WebCore.RenderLayer) {
        release(layer, .Positive)
        release(layer, .Negative)
    }

    /// Rebuilds the layer's normal-flow list from its children, walking them once into a scratch array that the list is
    /// then filled from. The walk calls only the writer's members, so it can neither free a layer nor change the children.
    static func rebuildNormalFlowList(_ layer: WebCore.RenderLayer) {
        assert(WebCore.RenderLayer.layerFreeForbidden())
        let rebuilt: Void? = normalFlowListScratch.withLockIfAvailable { list in
            rebuildNormalFlowList(layer, &list)
        }
        if rebuilt == nil {
            var list = UniqueArray<WebCore.LayerRef>()
            rebuildNormalFlowList(layer, &list)
        }
    }

    /// Rebuilds the layer's normal-flow list, collecting it in list, which starts and ends empty.
    private static func rebuildNormalFlowList(_ layer: WebCore.RenderLayer, _ list: inout UniqueArray<WebCore.LayerRef>) {
        // Read once: the walk only sets bits, so nothing in it can change the reflection.
        let reflectionLayer = layer.reflectionLayer()
        let reflection = WebCore.LayerRef(reflectionLayer)
        var current = firstChild(WebCore.LayerRef(layer))
        while !(current == WebCore.LayerRef()) {
            // Ignore non-overflow layers and reflections.
            if isNormalFlowOnly(current) && !(current == reflection) {
                list.append(current)
                if wasOmittedFromZOrderTree(current) {
                    setWasIncludedInZOrderTree(current)
                }
            }
            current = nextSibling(current)
        }
        withExtendedLifetime(reflectionLayer) {}
        reset(layer, .NormalFlow, list.count, true)
        for index in list.indices {
            append(layer, .NormalFlow, list[index])
        }
        if list.capacity > normalFlowListScratchCapacityLimit {
            list = UniqueArray()
        } else {
            list.removeAll()
        }
    }

    /// Rebuilds the layer's z-order lists if it is a stacking context, and returns whether the negative list has a layer
    /// and the compositing dirty bits of the layers added. Frees them and returns nil otherwise.
    static func updateZOrderLists(_ layer: WebCore.RenderLayer) -> (hasNegativeZOrderList: Bool, dirtyBits: UInt16)? {
        if !layer.isStackingContext() {
            releaseZOrderLists(layer)
            return nil
        }
        var dirtyBits: UInt16 = 0
        let hasNegativeZOrderList = rebuildZOrderLists(layer, &dirtyBits)
        return (hasNegativeZOrderList, dirtyBits)
    }

    /// Rebuilds the stacking context's z-order lists from the layers below it, and adds their compositing dirty bits to
    /// dirtyBits. Returns whether the negative list has a layer. The lists hold only the layers whose removal dirties
    /// the stacking context's lists, so this traps for a layer that is not one.
    fileprivate static func rebuildZOrderLists(_ layer: WebCore.RenderLayer, _ dirtyBits: inout UInt16) -> Bool {
        precondition(layer.isStackingContext())
        assert(WebCore.RenderLayer.layerFreeForbidden())
        if let hasNegativeZOrderList = zOrderEntriesScratch.withLockIfAvailable({ entries in
            rebuildZOrderLists(layer, &dirtyBits, &entries)
        }) {
            return hasNegativeZOrderList
        }
        var entries: [ZOrderEntry] = []
        return rebuildZOrderLists(layer, &dirtyBits, &entries)
    }

    /// Rebuilds the stacking context's z-order lists, collecting the entries in entries, which starts and ends empty.
    private static func rebuildZOrderLists(_ layer: WebCore.RenderLayer, _ dirtyBits: inout UInt16, _ entries: inout [ZOrderEntry]) -> Bool
    {
        collectChildLayers(layer, &entries, &dirtyBits)
        // One stable sort by z-index orders both lists as sorting each separately would: the negative entries form the
        // prefix, and each group keeps its collection order.
        entries.sort { $0.zIndex < $1.zIndex }
        let firstPositive = entries.firstIndex { $0.zIndex >= 0 } ?? entries.endIndex
        // By index, not by slice: a slice would hold the array's buffer, and the removeAll below would copy it.
        reset(layer, .Positive, entries.count - firstPositive, true)
        for index in firstPositive..<entries.count {
            append(layer, .Positive, entries[index].layer)
        }
        reset(layer, .Negative, firstPositive, true)
        for index in 0..<firstPositive {
            append(layer, .Negative, entries[index].layer)
        }
        if entries.capacity > zOrderEntriesScratchCapacityLimit {
            entries = []
        } else {
            entries.removeAll(keepingCapacity: true)
        }
        return firstPositive > 0
    }

    /// Collects the layer's children's entries, but not its reflection's. One binding per step: the loop holds only the
    /// child it is on, and reads the next one from it.
    private static func collectChildLayers(
        _ layer: WebCore.RenderLayer,
        _ entries: inout [ZOrderEntry],
        _ accumulatedDirtyBits: inout UInt16
    ) {
        var nextChild = layer.firstChild()
        while let current = nextChild.take() {
            // Ignore reflections.
            if !isReflectionLayer(current, of: layer) {
                collectLayers(current, &entries, &accumulatedDirtyBits)
            }
            nextChild = current.nextSibling()
        }
    }

    /// Whether child is the layer of layer's reflection.
    private static func isReflectionLayer(_ child: WebCore.RenderLayer, of layer: WebCore.RenderLayer) -> Bool {
        guard let reflectionLayer = layer.reflectionLayer() else {
            return false
        }
        return isSameRenderLayer(child, reflectionLayer)
    }

    fileprivate static func collectLayers(
        _ layer: WebCore.RenderLayer,
        _ entries: inout [ZOrderEntry],
        _ accumulatedDirtyBits: inout UInt16
    ) {
        assert(!layer.descendantDependentFlagsAreDirty())
        let layerRenderer = layer.renderer()
        if layerRenderer.isInTopLayerOrBackdropForSwift() || layerRenderer.isViewTransitionContainingBlock() {
            return
        }

        let isStacking = layer.isStackingContext()
        let layerOrDescendantsAreVisible =
            layer.hasVisibleContent() || layer.hasVisibleDescendant() || isAlwaysIncludedInZOrderLists(layer)
            || layer.page().hasEverSetVisibilityAdjustment()
        // Normal flow layers are just painted by their enclosing layers, so they don't get put in zorder lists.
        if !layer.isNormalFlowOnly() {
            if layerOrDescendantsAreVisible {
                if entries.capacity == 0 {
                    entries.reserveCapacity(16)
                }
                entries.append(ZOrderEntry(zIndex: layer.zIndex(), layer: WebCore.LayerRef(layer)))
                accumulatedDirtyBits |= compositingDirtyBits(layer)
                if wasOmittedFromZOrderTree(WebCore.LayerRef(layer)) {
                    setWasIncludedInZOrderTree(WebCore.LayerRef(layer))
                }
            } else if !wasOmittedFromZOrderTree(WebCore.LayerRef(layer)) {
                setWasOmittedFromZOrderTree(layer)
            }
        }

        // Recur into our children to collect more layers, but only if we don't establish
        // a stacking context/container.
        if !isStacking {
            collectChildLayers(layer, &entries, &accumulatedDirtyBits)
        }
    }
}
