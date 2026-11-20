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

// The walks that take no count per step, for RenderLayerTree.swift. WebCore.RenderLayerAncestorWalker names this file in
// SWIFT_PRIVATE_FILEID: only this file can name a layer by LayerRef and step along its links. Each walk starts from a
// layer the caller holds a reference to, and between its steps, which read or write the layers' own members and call
// nothing, it holds a LayerRef, so nothing can free a layer the walk names. A walk that does work on a layer on its way
// takes a reference to it first, and holds no LayerRef across that work. No walk returns or stores a LayerRef.

internal import WebCore_Private

// The walker's private members are reachable only from an extension in this file.
extension WebCore.RenderLayerAncestorWalker {
    /// Marks the layer's ancestors as having a descendant that needs a position update, up to the first that already has.
    static func setAncestorsDescendantNeedsPositionUpdate(_ layer: WebCore.RenderLayer) {
        setAncestorsDescendantNeedsPositionUpdate(WebCore.LayerRef(layer))
    }

    /// Marks the layer and its ancestors as having a dirty self-painting-descendant status, up to the first already marked,
    /// and each layer marked as needing a position update.
    static func dirtyAncestorChainHasSelfPaintingLayerDescendantStatus(_ layer: WebCore.RenderLayer) {
        var current = WebCore.LayerRef(layer)
        while dirtyHasSelfPaintingLayerDescendantStatus(current) {
            setNeedsPositionUpdate(current)
            current = parent(current)
        }
    }

    /// Marks the layer as needing a position update, and the layer and its ancestors as having a dirty visible-descendant
    /// status, up to the first already marked. The walk tests for the end after each step, so the layer's own step is
    /// the loop's first.
    @inline(always)
    static func dirtyAncestorChainVisibleDescendantStatus(_ layer: WebCore.RenderLayer) {
        var current = WebCore.LayerRef(layer)
        setNeedsPositionUpdate(current)
        repeat {
            guard dirtyVisibleDescendantStatus(current) else {
                break
            }
            current = parent(current)
        } while !(current == WebCore.LayerRef())
    }

    /// RenderLayer::dirtyPaintOrderListsOnChildChange(child): dirties layer's normal-flow and SVG children DOM order
    /// lists and the z-order lists of child's stacking context, testing child by LayerRef.
    @inline(always)
    static func dirtyPaintOrderListsOnChildChange(_ layer: WebCore.RenderLayer, _ child: WebCore.RenderLayer) {
        if isNormalFlowOnly(WebCore.LayerRef(child)) {
            layer.dirtyNormalFlowListBody()
        }
        if !isNormalFlowOnly(WebCore.LayerRef(child)) || hasChildren(WebCore.LayerRef(child)) {
            // Dirty the z-order list in which we are contained. The stacking context can be null in the
            // case where we're building up generated content layers. This is ok, since the lists will start
            // off dirty in that case anyway.
            stackingContext(child)?.dirtyZOrderListsBody()
        }

        // SVG layers that are not normal-flow-only still need to dirty the parent's
        // SVG children DOM order list. dirtyNormalFlowList() handles this for normal-flow
        // children, and dirtyStackingContextZOrderLists() dirties the stacking context
        // ancestor (not necessarily this layer).
        if layer.isSVGLayer() && child.renderer().isSVGLayerAwareRenderer() && !isNormalFlowOnly(WebCore.LayerRef(child)) {
            layer.dirtyChildrenInDOMOrderForSVG()
        }
    }

    /// dirtyPaintOrderListsOnChildChange(_:_:) on the child's own parent, for a removal from a layer that is not its
    /// parent. Out of line: no valid removal reaches it.
    @inline(never)
    static func dirtyPaintOrderListsOfParent(_ child: WebCore.RenderLayer) {
        if let parent = layer(parent(WebCore.LayerRef(child))) {
            dirtyPaintOrderListsOnChildChange(parent, child)
        }
    }

    /// The layer's nearest ancestor that is a stacking context, as a reference the caller holds.
    static func stackingContext(_ layer: WebCore.RenderLayer) -> WebCore.RenderLayer? {
        var current = parent(WebCore.LayerRef(layer))
        while isNonStackingContext(current) {
            current = parent(current)
        }
        return self.layer(current)
    }

    // The `layer` of the loops below is the LayerRef of a layer the caller holds a reference to, or one reached from it
    // through its links, with nothing called between.
    fileprivate static func setAncestorsDescendantNeedsPositionUpdate(_ layer: WebCore.LayerRef) {
        var current = parent(layer)
        while addDescendantNeedsPositionUpdate(current) {
            current = parent(current)
        }
    }

    // RenderLayer::setNeedsPositionUpdate().
    @inline(always)
    fileprivate static func setNeedsPositionUpdate(_ layer: WebCore.LayerRef) {
        addNeedsPositionUpdate(layer)
        setAncestorsDescendantNeedsPositionUpdate(layer)
    }
}
