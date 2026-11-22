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

/*
 * Copyright (C) 2006-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2019 Adobe. All rights reserved.
 * Copyright (C) 2014 Google. All rights reserved.
 * Copyright (C) 2020 Igalia S.L.
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
 * Copyright (C) 2003, 2009, 2012, 2015 Apple Inc. All rights reserved.
 * Copyright (C) 2020 Igalia S.L.
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
 * Copyright (C) 2026 Igalia S.L.
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
 */

/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Copyright (C) 2006-2024 Apple Inc. All rights reserved.
 * Copyright (C) 2013-2014 Google Inc. All rights reserved.
 * Copyright (C) 2019 Adobe. All rights reserved.
 * Copyright (c) 2020, 2021, 2022, 2026 Igalia S.L.
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
 */

// RenderLayer's tree: the five link members and the edits that keep them consistent, the paint-order lists and
// their dirty flags, the stacking context rules, and the flags that propagate along the ancestor chain. The layer
// declares these as private fields and this is the only code that writes them, so it is the only file that
// WebCore.RenderLayer names in SWIFT_PRIVATE_FILEID.

internal import WebCore_Private

/// Taken by RenderLayerLinks' edits. Only this file can make one (its stored property is private to this file, so an
/// initializer elsewhere cannot initialize it): every link edit is one of this file's, which update what depends on
/// the links around it.
struct RenderLayerLinkEdit: ~Copyable {
    private let seal: RenderLayerLinkEditSeal

    fileprivate init() {
        seal = RenderLayerLinkEditSeal()
    }
}

private struct RenderLayerLinkEditSeal {}

private func hasAncestorRenderer(_ renderer: WebCore.RenderObject, where predicate: (WebCore.RenderObject) -> Bool) -> Bool {
    var ancestor = parentRendererOfRenderObject(renderer)
    while let current = ancestor {
        if predicate(current) {
            return true
        }
        ancestor = parentRendererOfRenderObject(current)
    }
    return false
}

extension WebCore.RenderLayer {
    // Links newChild in front of beforeChild, or last; C++ then updates what depends on the tree.
    @cxx
    @implementation
    public func addChild(_ newChild: WebCore.RenderLayer, _ beforeChild: WebCore.RenderLayer?) {
        addChildBody(newChild, before: beforeChild, compositor())
    }

    func addChildLinks(_ newChild: WebCore.RenderLayer, before beforeChild: WebCore.RenderLayer?) {
        addChildLinks(newChild, before: beforeChild, compositor())
    }

    // compositor must be this layer's compositor().
    func addChildLinks(
        _ newChild: WebCore.RenderLayer,
        before beforeChild: WebCore.RenderLayer?,
        _ compositor: WebCore.RenderLayerCompositor
    ) {
        addChildBody(newChild, before: beforeChild, compositor)
    }

    // Inlined into addChild, so that the call from C++ is one frame that holds its arguments once. The compositor is
    // read where it is tested, after the edits that update the tree.
    @inline(always)
    private func addChildBody(
        _ newChild: WebCore.RenderLayer,
        before beforeChild: WebCore.RenderLayer?,
        _ compositor: @autoclosure () -> WebCore.RenderLayerCompositor
    ) {
        RenderLayerLinks.add(newChild, to: self, before: beforeChild, RenderLayerLinkEdit())
        didAddChildBody(newChild, compositor())
    }

    @cxx
    @implementation
    public func removeChild(_ oldChild: WebCore.RenderLayer) {
        let renderTreeBeingDestroyed = renderer().renderTreeBeingDestroyed()
        removeChildBody(oldChild, compositor(), renderTreeBeingDestroyed: renderTreeBeingDestroyed)
    }

    func removeChildLinks(_ oldChild: WebCore.RenderLayer) {
        removeChildLinks(oldChild, compositor())
    }

    // compositor must be this layer's compositor().
    func removeChildLinks(_ oldChild: WebCore.RenderLayer, _ compositor: WebCore.RenderLayerCompositor) {
        removeChildBody(oldChild, compositor, renderTreeBeingDestroyed: renderer().renderTreeBeingDestroyed())
    }

    // Inlined into removeChild, so that the call from C++ is one frame that holds its arguments once. The render
    // tree's teardown state is read once per removal.
    @inline(always)
    private func removeChildBody(
        _ oldChild: WebCore.RenderLayer,
        _ compositor: WebCore.RenderLayerCompositor,
        renderTreeBeingDestroyed: Bool
    ) {
        willRemoveChildBody(oldChild, compositor, renderTreeBeingDestroyed: renderTreeBeingDestroyed)
        RenderLayerLinks.remove(oldChild, from: self, RenderLayerLinkEdit())
        didRemoveChildBody(oldChild, compositor)
    }

    func moveToParentLinks(_ newParent: WebCore.RenderLayer) {
        let compositor = self.compositor()
        if let parent = self.parent() {
            parent.removeChildLinks(self, compositor)
        }
        newParent.addChildLinks(self, before: nil, compositor)
    }

    // MARK: Stacking contexts

    @inline(always)
    private func stackingContextLayer() -> WebCore.RenderLayer? {
        WebCore.RenderLayerAncestorWalker.stackingContext(self)
    }

    @inline(always)
    private func paintOrderParentLayer() -> WebCore.RenderLayer? {
        m_isNormalFlowOnly ? self.parent() : stackingContextLayer()
    }

    @cxx
    @implementation
    public func linkStackingContext() -> WebCore.LayerRef {
        WebCore.LayerRef(stackingContextLayer())
    }

    @cxx
    @implementation
    public func forceStackingContextIfNeeded() {
        if setIsCSSStackingContext(true) {
            _ = setIsNormalFlowOnlyBody(false)
        }
        updateEstablishesBlendingIsolationGroup()
    }

    @cxx
    @implementation
    public func setIsNormalFlowOnly(_ isNormalFlowOnly: Bool) -> Bool {
        setIsNormalFlowOnlyBody(isNormalFlowOnly)
    }

    // setIsNormalFlowOnly(), inlined into its Swift callers.
    @inline(always)
    fileprivate func setIsNormalFlowOnlyBody(_ isNormalFlowOnly: Bool) -> Bool {
        if isNormalFlowOnly == m_isNormalFlowOnly {
            return false
        }
        m_isNormalFlowOnly = isNormalFlowOnly
        self.parent()?.dirtyNormalFlowList()
        dirtyStackingContextZOrderLists()
        return true
    }

    @cxx
    @implementation
    public func isStackingContextChanged() {
        dirtyStackingContextZOrderLists()
        setSelfAndDescendantsNeedPositionUpdate()
        if isStackingContext() {
            dirtyZOrderLists()
        } else {
            clearZOrderLists()
        }
    }

    @cxx
    @implementation
    public func setIsOpportunisticStackingContext(_ isStacking: Bool) -> Bool {
        let wasStacking = isStackingContext()
        m_isOpportunisticStackingContext = isStacking
        if wasStacking == isStackingContext() {
            return false
        }
        isStackingContextChanged()
        return true
    }

    @cxx
    @implementation
    public func setIsCSSStackingContext(_ isCSSStackingContext: Bool) -> Bool {
        let wasStacking = isStackingContext()
        m_isCSSStackingContext = isCSSStackingContext
        if wasStacking == isStackingContext() {
            return false
        }
        isStackingContextChanged()
        return true
    }

    @cxx
    @implementation
    public func setCanBeBackdropRoot(_ canBeBackdropRoot: Bool) -> Bool {
        if m_canBeBackdropRoot == canBeBackdropRoot {
            return false
        }
        m_canBeBackdropRoot = canBeBackdropRoot
        return true
    }

    @cxx
    @implementation
    public func isDescendantOf(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        let target: WebCore.RenderLayer? = copy layer
        var ancestor: WebCore.RenderLayer? = self
        while let current = ancestor {
            if isSameRenderLayer(current, target) {
                return true
            }
            ancestor = current.parent()
        }
        return false
    }

    // MARK: Paint-order lists

    // The lists are written by WebCore.RenderLayerPaintOrderListWriter, which traps if a walk that forbids list mutation
    // on the layer is in progress.
    @cxx
    @implementation
    public func dirtyNormalFlowList() {
        dirtyNormalFlowListBody()
    }

    @inline(always)
    func dirtyNormalFlowListBody() {
        WebCore.RenderLayerPaintOrderListWriter.clearNormalFlowList(self)
        m_normalFlowListDirty = true
        if isSVGLayer() {
            dirtyChildrenInDOMOrderForSVG()
        }
        if hasCompositingDescendant() {
            setNeedsCompositingPaintOrderChildrenUpdate()
        }
    }

    @cxx
    @implementation
    public func dirtyZOrderLists() {
        dirtyZOrderListsBody()
    }

    @inline(always)
    func dirtyZOrderListsBody() {
        assert(isStackingContext())
        WebCore.RenderLayerPaintOrderListWriter.clearZOrderLists(self)
        m_zOrderListsDirty = true
        if isSVGLayer() {
            dirtyChildrenInDOMOrderForSVG()
        }
        if hasCompositingDescendant() {
            setNeedsCompositingPaintOrderChildrenUpdate()
        }
    }

    @cxx
    @implementation
    public func dirtyStackingContextZOrderLists() {
        stackingContextLayer()?.dirtyZOrderLists()
    }

    @cxx
    @implementation
    public func dirtyHiddenStackingContextAncestorZOrderLists() {
        var context = stackingContextLayer()
        while let current = context {
            current.dirtyZOrderLists()
            if current.m_hasVisibleContent {
                break
            }
            context = current.stackingContextLayer()
        }
    }

    @cxx
    @implementation
    public func clearZOrderLists() {
        assert(!isStackingContext())
        WebCore.RenderLayerPaintOrderListWriter.releaseZOrderLists(self)
    }

    @cxx
    @implementation
    public func rebuildNormalFlowList() {
        WebCore.RenderLayerPaintOrderListWriter.rebuildNormalFlowList(self)
        m_normalFlowListDirty = false
    }

    @cxx
    @implementation
    public func updateDirtyZOrderLists() {
        assert(!isStackingContext() || isDirtyStackingContext())
        guard let (hasNegativeZOrderList, childDirtyBits) = WebCore.RenderLayerPaintOrderListWriter.updateZOrderLists(self) else {
            m_zOrderListsDirty = false
            return
        }
        rebuildLists(hasNegativeZOrderList, childDirtyBits)
    }

    private func rebuildLists(_ hasNegativeZOrderList: Bool, _ childDirtyBits: UInt16) {
        appendViewLayersToPositiveList()
        m_zOrderListsDirty = false
        let childDirtyFlags = WebCore.RenderLayer.CompositingBits.fromRaw(childDirtyBits)

        // Having negative z-order lists affect whether a compositing layer needs a foreground layer.
        // Ideally we'd only trigger this when having z-order children changes, but we blow away the old z-order
        // lists on dirtying so we don't know the old state.
        if hasNegativeZOrderList != m_hadNegativeZOrderList {
            m_hadNegativeZOrderList = hasNegativeZOrderList
            if isComposited() {
                setNeedsCompositingConfigurationUpdate()
            }
        }

        // Building lists may have added layers with dirty flags, so make sure we propagate dirty bits up the tree.
        // The bits are read through the C++ getters: a read of the stored field takes a dynamic exclusivity check.
        if descendantsNeedCompositingRequirementsTraversal() && descendantsNeedUpdateBackingAndHierarchyTraversal() {
            return
        }
        if childDirtyFlags.containsAny(WebCore.RenderLayer.computeCompositingRequirementsFlags()) {
            setDescendantsNeedCompositingRequirementsTraversal()
        }
        if childDirtyFlags.containsAny(WebCore.RenderLayer.updateBackingOrHierarchyFlags()) {
            setDescendantsNeedUpdateBackingAndHierarchyTraversal()
        }
    }

    @cxx
    @implementation
    public func setWasOmittedFromZOrderTree() {
        if m_wasOmittedFromZOrderTree {
            return
        }
        assert(!m_isNormalFlowOnly)
        removeSelfFromCompositor()
        setSelfAndDescendantsNeedPositionUpdate()

        // Omitting a stacking context removes the whole subtree, otherwise collectLayers will
        // visit and omit/include descendants separately.
        if isStackingContext() {
            removeDescendantsFromCompositor()
        }
        if compositor().hasContentCompositingLayers() {
            self.parent()?.setDescendantsNeedCompositingRequirementsTraversal()
        }
        m_wasOmittedFromZOrderTree = true
    }

    @cxx
    @implementation
    public func setWasIncludedInZOrderTree() {
        if !m_wasOmittedFromZOrderTree {
            return
        }
        m_wasOmittedFromZOrderTree = false
        setSelfAndDescendantsNeedPositionUpdate()
    }

    @cxx
    @implementation
    public func updateLayerListsIfNeeded() {
        updateDescendantDependentFlags()
        updateZOrderLists()
        updateNormalFlowList()

        if let reflection = reflectionLayer() {
            reflection.updateZOrderLists()
            reflection.updateNormalFlowList()
        }
    }

    // MARK: What a child change updates

    private var isViewportConstrainedSelfOrDescendant: Bool {
        isViewportConstrained() || m_hasViewportConstrainedDescendant
    }

    private var hasHiddenUsedVisibility: Bool {
        renderer().usedVisibility() != .Visible
    }

    private var isBlendingSelfOrDescendant: Bool {
        hasBlendMode() || (hasNotIsolatedBlendingDescendants() && !isolatesBlending())
    }

    @cxx
    @implementation
    public func dirtyPaintOrderListsOnChildChange(_ child: WebCore.RenderLayer) {
        WebCore.RenderLayerAncestorWalker.dirtyPaintOrderListsOnChildChange(self, child)
    }

    @cxx
    @implementation
    public func didAddChild(_ child: WebCore.RenderLayer) {
        didAddChildBody(child, compositor())
    }

    // compositor must be this layer's compositor(), read where the edit tests it.
    @inline(always)
    func didAddChildBody(_ child: WebCore.RenderLayer, _ compositor: @autoclosure () -> WebCore.RenderLayerCompositor) {
        child.setSelfAndDescendantsNeedPositionUpdateBody()

        WebCore.RenderLayerAncestorWalker.dirtyPaintOrderListsOnChildChange(self, child)

        child.updateAncestorDependentStateBody()
        WebCore.RenderLayerAncestorWalker.dirtyAncestorChainVisibleDescendantStatus(self)
        child.updateDescendantDependentFlags()

        if child.isSelfPaintingLayer() || child.m_hasSelfPaintingLayerDescendant {
            setAncestorChainHasSelfPaintingLayerDescendantBody()
        }
        if child.isViewportConstrainedSelfOrDescendant {
            setAncestorChainHasViewportConstrainedDescendant()
        }
        if compositor().hasContentCompositingLayers() {
            setDescendantsNeedCompositingRequirementsTraversal()
        }
        if child.hasDescendantNeedingCompositingRequirementsTraversal() || child.needsCompositingRequirementsTraversal() {
            child.setAncestorsHaveCompositingDirtyFlag(.HasDescendantNeedingRequirementsTraversal)
        }
        if child.hasDescendantNeedingUpdateBackingOrHierarchyTraversal() || child.needsUpdateBackingOrHierarchyTraversal() {
            child.setAncestorsHaveCompositingDirtyFlag(.HasDescendantNeedingBackingOrHierarchyTraversal)
        }
        if child.isBlendingSelfOrDescendant {
            updateAncestorChainHasBlendingDescendants()
        }
        didAddChildEventRegion(child)
    }

    @cxx
    @implementation
    public func didRemoveChild(_ oldChild: WebCore.RenderLayer) {
        didRemoveChildBody(oldChild, compositor())
    }

    // compositor must be this layer's compositor(), read once by the edit.
    @inline(always)
    func didRemoveChildBody(_ oldChild: WebCore.RenderLayer, _ compositor: WebCore.RenderLayerCompositor) {
        oldChild.updateDescendantDependentFlags()
        if oldChild.m_hasVisibleContent || oldChild.m_hasVisibleDescendant {
            WebCore.RenderLayerAncestorWalker.dirtyAncestorChainVisibleDescendantStatus(self)
        }
        if oldChild.isSelfPaintingLayer() || oldChild.m_hasSelfPaintingLayerDescendant {
            dirtyAncestorChainHasSelfPaintingLayerDescendantStatus()
        }
        if oldChild.isViewportConstrainedSelfOrDescendant {
            dirtyAncestorChainHasViewportConstrainedDescendantStatus()
        }
        if compositor.hasContentCompositingLayers() {
            setDescendantsNeedCompositingRequirementsTraversal()
        }
        if oldChild.isBlendingSelfOrDescendant {
            dirtyAncestorChainHasBlendingDescendants()
        }
        if hasHiddenUsedVisibility {
            dirtyVisibleContentStatus()
        }
    }

    @cxx
    @implementation
    public func willRemoveChild(_ oldChild: WebCore.RenderLayer) {
        willRemoveChildBody(oldChild, compositor(), renderTreeBeingDestroyed: renderer().renderTreeBeingDestroyed())
    }

    // compositor must be this layer's compositor(), and renderTreeBeingDestroyed is the renderer's, each read once
    // by the edit.
    @inline(always)
    func willRemoveChildBody(_ oldChild: WebCore.RenderLayer, _ compositor: WebCore.RenderLayerCompositor, renderTreeBeingDestroyed: Bool) {
        if !renderTreeBeingDestroyed && !isReflectionLayerBody(oldChild) {
            compositor.layerWillBeRemovedWhileRenderTreeLives(oldChild)
        }
    }

    // Takes this layer out of the tree, reattaching its children to its parent in its place. The caller
    // destroys the layer afterwards: a Swift member holds its layer across the call and cannot end it.
    @cxx
    @implementation
    public func detachKeepingChildren() {
        guard let parent = self.parent() else {
            return
        }
        let compositor = self.compositor()
        compositor.layerWillBeRemovedBody(parent, self)

        // Dirty the clip rects.
        clearClipRectsIncludingDescendants()

        let nextSibling = self.nextSibling()

        // Remove the child reflection layer before moving other child layers.
        // The reflection layer should not be moved to the parent.
        if let reflection = reflectionLayer() {
            removeChildLinks(reflection, compositor)
        }

        // Now walk our kids and reattach them to our parent.
        var current = self.firstChild()
        while let layer = current {
            let next = layer.nextSibling()
            removeChildLinks(layer, compositor)
            parent.addChildLinks(layer, before: nextSibling, compositor)
            layer.setRepaintStatusBody(.NeedsFullRepaint)
            if isComposited() {
                layer.updateRepaintRectsIncludingDescendants(.Recompute)
            }
            current = next
        }

        // Remove us from the parent.
        parent.removeChildLinks(self, compositor)
    }

    @cxx
    @implementation
    public func removeDescendantsFromCompositor() {
        var child = self.firstChild()
        while let current = child {
            current.removeSelfFromCompositor()
            current.removeDescendantsFromCompositor()
            child = current.nextSibling()
        }
    }

    @cxx
    @implementation
    public func willRemoveChildWithBlendMode() {
        self.parent()!.dirtyAncestorChainHasBlendingDescendants()
    }

    @cxx
    @implementation
    public func dirty3DTransformedDescendantStatus() {
        var current = stackingContextLayer()
        current?.m_3DTransformedDescendantStatusDirty = true

        // This propagates up through preserve-3d hierarchies to the enclosing flattening layer.
        // Note that preserves3D() creates stacking context, so we can just run up the stacking containers.
        while let layer = current, layer.preserves3D() {
            layer.m_3DTransformedDescendantStatusDirty = true
            current = layer.stackingContextLayer()
        }
    }

    @cxx
    @implementation
    public func setIntrinsicallyComposited(_ composited: Bool) {
        m_intrinsicallyComposited = composited
        updateAlwaysIncludedInZOrderLists()
    }

    // MARK: Flags that propagate along the ancestor chain

    @cxx
    @implementation
    public func setNeedsPositionUpdate() {
        setNeedsPositionUpdateBody()
    }

    @inline(always)
    func setNeedsPositionUpdateBody() {
        _ = addLayerPositionDirtyBit(.NeedsPositionUpdate)
        WebCore.RenderLayerAncestorWalker.setAncestorsDescendantNeedsPositionUpdate(self)
    }

    @cxx
    @implementation
    public func needsPositionUpdate() -> Bool {
        if m_layerPositionDirtyBits.contains(.NeedsPositionUpdate) || m_layerPositionDirtyBits.contains(.DescendantNeedsPositionUpdate) {
            return true
        }
        if let parent = self.parent(), parent.m_layerPositionDirtyBits.contains(.AllChildrenNeedPositionUpdate) {
            return true
        }
        return false
    }

    @cxx
    @implementation
    public func setSelfAndChildrenNeedPositionUpdate() {
        setNeedsPositionUpdate()
        _ = addLayerPositionDirtyBit(.DescendantNeedsPositionUpdate)
        _ = addLayerPositionDirtyBit(.AllChildrenNeedPositionUpdate)
    }

    @cxx
    @implementation
    public func setSelfAndDescendantsNeedPositionUpdate() {
        setSelfAndDescendantsNeedPositionUpdateBody()
    }

    @inline(always)
    func setSelfAndDescendantsNeedPositionUpdateBody() {
        setNeedsPositionUpdateBody()
        _ = addLayerPositionDirtyBit(.DescendantNeedsPositionUpdate)
        _ = addLayerPositionDirtyBit(.AllDescendantsNeedPositionUpdate)
    }

    @cxx
    @implementation
    private func setAncestorsHaveCompositingDirtyFlag(_ flag: WebCore.RenderLayer.Compositing) {
        var layer = paintOrderParentLayer()
        while let current = layer {
            if current.m_compositingDirtyBits.contains(flag) {
                break
            }
            current.m_compositingDirtyBits.add(WebCore.RenderLayer.CompositingBits(flag))
            layer = current.paintOrderParentLayer()
        }
    }

    @cxx
    @implementation
    public func setAncestorChainHasSelfPaintingLayerDescendant() {
        setAncestorChainHasSelfPaintingLayerDescendantBody()
    }

    @inline(always)
    func setAncestorChainHasSelfPaintingLayerDescendantBody() {
        var current = self
        while true {
            if current.renderer().shouldApplyPaintContainment() {
                current.m_hasSelfPaintingLayerDescendant = true
                current.m_hasSelfPaintingLayerDescendantDirty = false
                break
            }
            if !current.m_hasSelfPaintingLayerDescendantDirty && current.m_hasSelfPaintingLayerDescendant {
                break
            }
            current.m_hasSelfPaintingLayerDescendantDirty = false
            current.m_hasSelfPaintingLayerDescendant = true
            guard let next = current.parent() else {
                break
            }
            current = next
        }
    }

    @cxx
    @implementation
    public func dirtyAncestorChainHasSelfPaintingLayerDescendantStatus() {
        WebCore.RenderLayerAncestorWalker.dirtyAncestorChainHasSelfPaintingLayerDescendantStatus(self)
    }

    @cxx
    @implementation
    public func setAncestorChainHasViewportConstrainedDescendant() {
        var layer: WebCore.RenderLayer? = self
        while let current = layer {
            if !current.m_hasViewportConstrainedDescendantStatusDirty && current.m_hasViewportConstrainedDescendant {
                break
            }
            current.m_hasViewportConstrainedDescendant = true
            current.m_hasViewportConstrainedDescendantStatusDirty = false
            layer = current.parent()
        }
    }

    @cxx
    @implementation
    public func dirtyAncestorChainHasViewportConstrainedDescendantStatus() {
        var layer: WebCore.RenderLayer? = self
        while let current = layer {
            if current.m_hasViewportConstrainedDescendantStatusDirty {
                break
            }
            current.m_hasViewportConstrainedDescendantStatusDirty = true
            layer = current.parent()
        }
    }

    @cxx
    @implementation
    public func updateAncestorChainHasBlendingDescendants() {
        var layer: WebCore.RenderLayer? = self
        while let current = layer {
            if !current.m_hasNotIsolatedBlendingDescendantsStatusDirty && current.m_hasNotIsolatedBlendingDescendants {
                break
            }
            current.m_hasNotIsolatedBlendingDescendants = true
            current.m_hasNotIsolatedBlendingDescendantsStatusDirty = false

            current.updateSelfPaintingLayer()

            if current.m_establishesBlendingIsolationGroup {
                break
            }
            layer = current.parent()
        }
    }

    @cxx
    @implementation
    public func computeEstablishesBlendingIsolationGroup() -> Bool {
        if !isCSSStackingContext() {
            return false
        }

        if !isSVGLayer() {
            return true
        }

        let layerRenderer = renderer()
        if layerRenderer.createsGroup() || layerRenderer.isRenderSVGForeignObject() || layerRenderer.isDocumentElementRenderer() {
            return true
        }

        if layerRenderer[.Style].isolation() != .Auto {
            return true
        }

        if layerRenderer.isRenderSVGRoot() {
            return zIndexMakesOutermostSVGAStackingContext() || shouldBeCSSStackingContextIgnoringZIndexBody()
        }

        return layerRenderer.hasSVGGroupingWillChangeProperty() || layerRenderer.hasSVG3DTransformRelatedProperty()
    }

    @cxx
    @implementation
    public func updateEstablishesBlendingIsolationGroup() {
        let establishesBlendingIsolationGroup = computeEstablishesBlendingIsolationGroup()
        if establishesBlendingIsolationGroup == m_establishesBlendingIsolationGroup {
            return
        }

        m_establishesBlendingIsolationGroup = establishesBlendingIsolationGroup
        guard let parent = self.parent() else {
            return
        }

        // Isolation only matters for compositing if there are blending descendants.
        if hasNotIsolatedBlendingDescendantsStatusDirty() || hasNotIsolatedBlendingDescendants() {
            setNeedsPostLayoutCompositingUpdate()
            setChildrenNeedCompositingGeometryUpdate()
        }

        if establishesBlendingIsolationGroup {
            if !hasNotIsolatedBlendingDescendantsStatusDirty() && hasNotIsolatedBlendingDescendants() {
                parent.dirtyAncestorChainHasBlendingDescendants()
            }
        } else {
            if hasNotIsolatedBlendingDescendantsStatusDirty() {
                parent.dirtyAncestorChainHasBlendingDescendants()
            } else if hasNotIsolatedBlendingDescendants() {
                parent.updateAncestorChainHasBlendingDescendants()
            }
        }
    }

    @cxx
    @implementation
    public func dirtyAncestorChainHasBlendingDescendants() {
        var layer: WebCore.RenderLayer? = self
        while let current = layer {
            if current.m_hasNotIsolatedBlendingDescendantsStatusDirty {
                break
            }
            current.m_hasNotIsolatedBlendingDescendantsStatusDirty = true
            current.setNeedsPositionUpdate()
            layer = current.parent()
        }
    }

    @cxx
    @implementation
    public func updateAlwaysIncludedInZOrderLists() {
        let alwaysIncluded = m_intrinsicallyComposited || renderer().hasViewTransitionName()
        if m_alwaysIncludedInZOrderLists != alwaysIncluded {
            m_alwaysIncludedInZOrderLists = alwaysIncluded
            if alwaysIncluded {
                updateAncestorChainHasAlwaysIncludedInZOrderListsDescendants()
            } else {
                dirtyAncestorChainHasAlwaysIncludedInZOrderListsDescendants()
            }
            if !m_hasVisibleContent && !m_isNormalFlowOnly {
                dirtyHiddenStackingContextAncestorZOrderLists()
            }
        }
    }

    @cxx
    @implementation
    public func updateAncestorChainHasAlwaysIncludedInZOrderListsDescendants() {
        var layer: WebCore.RenderLayer? = self
        while let current = layer {
            if !current.m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty && current.m_hasAlwaysIncludedInZOrderListsDescendants {
                break
            }
            current.m_hasAlwaysIncludedInZOrderListsDescendants = true
            current.m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty = false
            layer = current.parent()
        }
    }

    @cxx
    @implementation
    public func dirtyAncestorChainHasAlwaysIncludedInZOrderListsDescendants() {
        var layer: WebCore.RenderLayer? = self
        while let current = layer {
            if current.m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty {
                break
            }
            current.m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty = true
            layer = current.parent()
        }
    }

    @cxx
    @implementation
    public func dirtyAncestorChainVisibleDescendantStatus() {
        WebCore.RenderLayerAncestorWalker.dirtyAncestorChainVisibleDescendantStatus(self)
    }

    @cxx
    @implementation
    public func dirtyVisibleContentStatus() {
        m_visibleContentStatusDirty = true
        setNeedsPositionUpdate()
        self.parent()?.dirtyAncestorChainVisibleDescendantStatus()
    }

    // MARK: Enclosing layers

    @cxx
    @implementation
    public func linkEnclosingOverflowClipLayer(_ includeSelf: WebCore.IncludeSelfOrNot) -> WebCore.LayerRef {
        var layer = includeSelf == WebCore.IncludeSelf ? self : self.parent()
        while let current = layer {
            if current.renderer().hasPotentiallyScrollableOverflow() {
                return WebCore.LayerRef(current)
            }
            layer = current.parent()
        }
        return WebCore.LayerRef()
    }

    @cxx
    @implementation
    public func ancestorLayerIsInContainingBlockChain(_ ancestor: borrowing WebCore.RenderLayer, _ checkLimit: WebCore.RenderLayer?) -> Bool
    {
        let ancestorRef = WebCore.LayerRef(copy ancestor)
        if ancestorRef == WebCore.LayerRef(self) {
            return true
        }

        var currentBlock = renderer().containingBlock()
        while let block = currentBlock, !block.isRenderView() {
            let currentLayer = block.layer()
            let currentRef = WebCore.LayerRef(currentLayer)
            if currentRef == ancestorRef {
                return true
            }
            if currentLayer != nil && currentRef == WebCore.LayerRef(checkLimit) {
                return false
            }
            currentBlock = block.containingBlock()
        }
        return false
    }

    @cxx
    @implementation
    public func linkEnclosingLayerInContainingBlockOrder() -> WebCore.LayerRef {
        var currentBlock = renderer().containingBlock()
        while let block = currentBlock {
            if let layer = block.layer() {
                return WebCore.LayerRef(layer)
            }
            currentBlock = block.containingBlock()
        }
        return WebCore.LayerRef()
    }

    @cxx
    @implementation
    public func linkEnclosingCompositingLayer(_ includeSelf: WebCore.IncludeSelfOrNot) -> WebCore.LayerRef {
        if includeSelf == WebCore.IncludeSelf && isComposited() {
            return WebCore.LayerRef(self)
        }
        var current = paintOrderParentLayer()
        while let layer = current {
            if layer.isComposited() {
                return WebCore.LayerRef(layer)
            }
            current = layer.paintOrderParentLayer()
        }
        return WebCore.LayerRef()
    }

    private func repaintTarget() -> WebCore.RenderLayer? {
        if WebCore.compositedWithOwnBackingStore(self) {
            return self
        }
        if paintsIntoProvidedBacking() {
            return backingProviderLayer()
        }
        return nil
    }

    @cxx
    @implementation
    public func linkEnclosingRepaintTargetLayer(_ includeSelf: WebCore.IncludeSelfOrNot) -> WebCore.LayerRef {
        if includeSelf == WebCore.IncludeSelf, let target = repaintTarget() {
            return WebCore.LayerRef(target)
        }
        var current = paintOrderParentLayer()
        while let layer = current {
            if let target = layer.repaintTarget() {
                return WebCore.LayerRef(target)
            }
            current = layer.paintOrderParentLayer()
        }
        return WebCore.LayerRef()
    }

    @cxx
    @implementation
    public func linkEnclosingPixelMovingFilterLayer(_ includeSelf: WebCore.IncludeSelfOrNot) -> WebCore.LayerRef {
        var current = includeSelf == WebCore.IncludeSelf ? self : self.parent()
        while let layer = current {
            if layer.requiresFullLayerImageForFilters() {
                return WebCore.LayerRef(layer)
            }
            current = layer.parent()
        }
        return WebCore.LayerRef()
    }

    @cxx
    @implementation
    public func linkEnclosingFilterRepaintLayer() -> WebCore.LayerRef {
        let selfRef = WebCore.LayerRef(self)
        var current: WebCore.RenderLayer? = self
        while let layer = current {
            if (!(WebCore.LayerRef(layer) == selfRef) && layer.requiresFullLayerImageForFilters())
                || WebCore.compositedWithOwnBackingStore(layer) || layer.isRenderViewLayer()
            {
                return WebCore.LayerRef(layer)
            }
            current = layer.parent()
        }
        return WebCore.LayerRef()
    }

    @cxx
    @implementation
    public func hasAncestorWithFilterOutsets() -> Bool {
        var current: WebCore.RenderLayer? = self
        while let layer = current {
            if layer.hasFilterOutsets() {
                return true
            }
            current = layer.parent()
        }
        return false
    }

    // MARK: Pagination

    // FIXME: This is terrible. Bring back a cached bit for this someday. This crawl is going to slow down all
    // painting of content inside paginated layers.
    @cxx
    @implementation
    public func hasCompositedLayerInEnclosingPaginationChain() -> Bool {
        // No enclosing layer means no compositing in the chain.
        guard let paginationLayer = enclosingPaginationLayerInStore() else {
            return false
        }

        // If the enclosing layer is composited, we don't have to check anything in between us and that
        // layer.
        if paginationLayer.isComposited() {
            return true
        }

        // If we are the enclosing pagination layer, then we can't be composited or we'd have passed the
        // previous check.
        if isSameRenderLayer(paginationLayer, self) {
            return false
        }

        // The enclosing paginated layer is our ancestor and is not composited, so we have to check
        // intermediate layers between us and the enclosing pagination layer. Start with our own layer.
        if isComposited() {
            return true
        }

        // For normal flow layers, we can recur up the layer tree.
        if m_isNormalFlowOnly {
            return self.parent()!.hasCompositedLayerInEnclosingPaginationChain()
        }

        // Otherwise we have to go up the containing block chain. Find the first enclosing
        // containing block layer ancestor, and check that.
        var containingBlock = renderer().containingBlock()
        while let block = containingBlock, !block.isRenderView() {
            if block.hasLayer() {
                return block.layer()!.hasCompositedLayerInEnclosingPaginationChain()
            }
            containingBlock = block.containingBlock()
        }
        return false
    }

    @cxx
    @implementation
    public func linkEnclosingPaginationLayerInSubtree(
        _ rootLayer: WebCore.RenderLayer?,
        _ mode: WebCore.RenderLayer.PaginationInclusionMode
    ) -> WebCore.LayerRef {
        // If we don't have an enclosing layer, or if the root layer is the same as the enclosing layer,
        // then just return the enclosing pagination layer (it will be 0 in the former case and the rootLayer in the latter case).
        let paginationLayer = enclosingPaginationLayer(mode)
        let paginationRef = WebCore.LayerRef(paginationLayer)
        let rootRef = WebCore.LayerRef(rootLayer)
        if paginationLayer == nil || rootRef == paginationRef {
            return paginationRef
        }

        // Walk up the layer tree and see which layer we hit first. If it's the root, then the enclosing pagination
        // layer isn't in our subtree and we return nullptr. If we hit the enclosing pagination layer first, then
        // we can return it.
        var current: WebCore.RenderLayer? = self
        while let layer = current {
            let layerRef = WebCore.LayerRef(layer)
            if layerRef == rootRef {
                return WebCore.LayerRef()
            }
            if layerRef == paginationRef {
                return paginationRef
            }
            current = layer.parent()
        }

        // This should never be reached, since an enclosing layer should always either be the rootLayer or be
        // our enclosing pagination layer.
        assertionFailure()
        return WebCore.LayerRef()
    }

    // MARK: Self-painting

    @cxx
    @implementation
    public func shouldBeSelfPaintingLayer() -> Bool {
        shouldBeSelfPaintingLayerBody()
    }

    // shouldBeSelfPaintingLayer(), inlined into its Swift callers.
    @inline(always)
    fileprivate func shouldBeSelfPaintingLayerBody() -> Bool {
        if !m_isNormalFlowOnly {
            return true
        }
        let layerRenderer = renderer()
        return hasOverlayScrollbars()
            || hasCompositedScrollableOverflow()
            || layerRenderer.isRenderTableRow()
            || layerRenderer.isRenderHTMLCanvas()
            || layerRenderer.isRenderVideo()
            || layerRenderer.isRenderEmbeddedObject()
            || layerRenderer.isRenderIFrame()
            || layerRenderer.isRenderFragmentedFlow()
            || isScreenCaptureProtectionLayer()
    }

    // RenderLayerScrollableArea calls this private member after its layout.
    func updateSelfPaintingLayerForScrollableArea() {
        updateSelfPaintingLayer()
    }

    @cxx
    @implementation
    public func updateSelfPaintingLayer() {
        let isSelfPaintingLayer = shouldBeSelfPaintingLayerBody()
        if m_isSelfPaintingLayer == isSelfPaintingLayer {
            return
        }

        m_isSelfPaintingLayer = isSelfPaintingLayer
        setNeedsPositionUpdate()

        guard let parent = self.parent() else {
            return
        }

        // We are part of what a hidden ancestor paints now.
        parent.dirtyVisibleContentStatusIncludingAncestors()

        if isSelfPaintingLayer {
            parent.setAncestorChainHasSelfPaintingLayerDescendant()
        } else {
            parent.dirtyAncestorChainHasSelfPaintingLayerDescendantStatus()
            clearRepaintRects()
            if let box = renderBox(), box.isFloating() {
                box.updateFloatPainterAfterSelfPaintingLayerChange()
            }
        }
    }

    @cxx
    @implementation
    public func setAncestorsHaveDescendantNeedingEventRegionUpdate() {
        var layer = self.parent()
        while let current = layer {
            if current.m_hasDescendantNeedingEventRegionUpdate {
                break
            }
            current.m_hasDescendantNeedingEventRegionUpdate = true
            layer = current.parent()
        }
    }

    // MARK: Insertion into the tree

    @cxx
    @implementation
    public func insertOnlyThisLayer() {
        let layerRenderer = renderer()
        if self.parent() == nil && parentRendererOfRenderObject(layerRenderer) != nil {
            // We need to connect ourselves when our renderer() has a parent.
            // Find our enclosingLayer and add ourselves.
            guard let parentLayer = layerRenderer.parentLayerRespectingTopLayer() else {
                return
            }
            let beforeChild =
                !isSameRenderLayer(parentLayer.reflectionLayer(), self)
                ? layerRenderer.nextSiblingLayerRespectingTopLayer(parentLayer) : nil
            parentLayer.addChildLinks(self, before: beforeChild)
        }

        // Remove all descendant layers from the hierarchy and add them to the new position.
        var child = layerRenderer.firstChild()
        while let current = child {
            current.asRenderElement()?.moveLayersInSubtree(self)
            child = current.nextSibling()
        }

        // Clear out all the clip rects.
        clearClipRectsIncludingDescendants()
    }

    @cxx
    @implementation
    public func establishesTopLayer() -> Bool {
        establishesTopLayerBody()
    }

    // establishesTopLayer(), inlined into its Swift callers.
    @inline(always)
    func establishesTopLayerBody() -> Bool {
        renderer().isInTopLayerOrBackdropForSwift()
    }

    @cxx
    @implementation
    public func establishesTopLayerWillChange() {
        topLayerWillChange()
    }

    @cxx
    @implementation
    public func establishesTopLayerDidChange() {
        topLayerDidChange()
    }

    // The renderer's top-layer change calls these; the members above are for C++ callers.
    func topLayerWillChange() {
        compositor().establishesTopLayerWillChangeForLayer(self)
        if let parentLayer = self.parent() {
            parentLayer.removeChildLinks(self)
        }
    }

    func topLayerDidChange() {
        let layerRenderer = renderer()
        if let parentLayer = layerRenderer.parentLayerRespectingTopLayer() {
            _ = setIsNormalFlowOnlyBody(shouldBeNormalFlowOnlyBody())
            let beforeChild = layerRenderer.nextSiblingLayerRespectingTopLayer(parentLayer)
            parentLayer.addChildLinks(self, before: beforeChild)
        }
    }

    // MARK: Pagination and visibility

    @cxx
    @implementation
    public func updatePagination() {
        setEnclosingPaginationLayerInStore(nil)

        guard let parent = self.parent() else {
            return
        }

        // Each layer that is inside a multicolumn flow thread has to be checked individually and
        // genuinely know if it is going to have to split itself up when painting only its contents (and not any other descendant
        // layers). We track an enclosingPaginationLayer instead of using a simple bit, since we want to be able to get back
        // to that layer easily.
        if renderer().isRenderFragmentedFlow() {
            setEnclosingPaginationLayerInStore(self)
            return
        }

        if m_isNormalFlowOnly {
            // Content inside a transform is not considered to be paginated, since we simply
            // paint the transform multiple times in each column, so we don't have to use
            // fragments for the transformed content.
            if parent.isTransformed() {
                setEnclosingPaginationLayerInStore(nil)
            } else {
                setEnclosingPaginationLayerInStore(parent.enclosingPaginationLayer(WebCore.RenderLayer.IncludeCompositedPaginatedLayers))
            }
            return
        }

        // For the new columns code, we want to walk up our containing block chain looking for an enclosing layer. Once
        // we find one, then we just check its pagination status.
        var containingBlock = renderer().containingBlock()
        while let block = containingBlock, !block.isRenderView() {
            if block.hasLayer() {
                let blockLayer = block.layer()!
                // Content inside a transform is not considered to be paginated, since we simply
                // paint the transform multiple times in each column, so we don't have to use
                // fragments for the transformed content.
                if blockLayer.isTransformed() {
                    setEnclosingPaginationLayerInStore(nil)
                } else {
                    setEnclosingPaginationLayerInStore(
                        blockLayer.enclosingPaginationLayer(WebCore.RenderLayer.IncludeCompositedPaginatedLayers)
                    )
                }
                return
            }
            containingBlock = block.containingBlock()
        }
    }

    @cxx
    @implementation
    public func setHasVisibleContent() {
        if m_hasVisibleContent && !m_visibleContentStatusDirty {
            assert(self.parent() == nil || self.parent()!.m_visibleDescendantStatusDirty || self.parent()!.hasVisibleDescendant())
            return
        }

        m_visibleContentStatusDirty = false
        m_hasVisibleContent = true
        computeRepaintRects(renderer().containerForRepaint().renderer.get())
        setNeedsPositionUpdate()
        if !m_isNormalFlowOnly {
            // We don't collect invisible layers in z-order lists if they are not composited.
            // As we became visible, we need to dirty our stacking containers ancestors to be properly
            // collected.
            dirtyHiddenStackingContextAncestorZOrderLists()
        }

        self.parent()?.dirtyAncestorChainVisibleDescendantStatus()
    }

    @cxx
    @implementation
    public func computeHasVisibleContent() -> Bool {
        if m_isHiddenByOverflowTruncation {
            return false
        }

        let layerRenderer = renderer()
        if layerRenderer.isSkippedContent() {
            return false
        }

        if layerRenderer.usedVisibility() == .Visible {
            return true
        }

        if isSVGLayer() && layerRenderer[.Style].hasFilter() {
            return true
        }

        // Layer's renderer has visibility:hidden, but a child we paint ourselves may have visibility:visible.
        func nextRenderer(_ renderer: WebCore.RenderObject) -> WebCore.RenderObject? {
            var ancestor: WebCore.RenderObject? = renderer
            while let current = ancestor, !WebCore.RenderObject.isSameRenderer(current, layerRenderer) {
                if let sibling = current.nextSibling() {
                    return sibling
                }
                ancestor = current.parent()
            }
            return nil
        }
        var current = layerRenderer.firstChild()
        while let renderer = current {
            if let renderElement = renderer.asRenderElement(), !renderElement.hasSelfPaintingLayer() {
                if renderElement.usedVisibility() == .Visible {
                    return true
                }
                if let firstChild = renderElement.firstChild() {
                    current = firstChild
                    continue
                }
            }
            current = nextRenderer(renderer)
        }
        return false
    }

    // Return true if this layer or any preserve-3d descendants have 3d.
    @cxx
    @implementation
    public func update3DTransformedDescendantStatus() -> Bool {
        if m_3DTransformedDescendantStatusDirty {
            m_has3DTransformedDescendant = false

            updateZOrderLists()

            // Transformed or preserve-3d descendants can only be in the z-order lists, not
            // in the normal flow list, so we only need to check those.
            func update(_ which: WebCore.PaintOrderList) {
                var index = 0
                while index < paintOrderListSize(which) {
                    if paintOrderListLayerAt(which, index).update3DTransformedDescendantStatus() {
                        m_has3DTransformedDescendant = true
                    }
                    index += 1
                }
            }
            update(.Positive)

            // Now check our negative z-index children.
            update(.Negative)

            m_3DTransformedDescendantStatusDirty = false
        }

        // If we live in a 3d hierarchy, then the layer at the root of that hierarchy needs
        // the m_has3DTransformedDescendant set.
        if preserves3D() {
            return has3DTransform() || m_has3DTransformedDescendant
        }
        return has3DTransform()
    }

    @cxx
    @implementation
    public func participatesInPreserve3D() -> Bool {
        let parent = self.parent()
        return ancestorLayerIsDOMParent(parent) && parent!.preserves3D()
            && (transformValue().value != nil || renderer()[.Style].backfaceVisibility() == .Hidden || preserves3D())
    }

    // MARK: Enclosing layers by position and transform

    private func isContainerForPositioned(_ position: WebCore.PositionType, _ establishesTopLayer: Bool) -> Bool {
        if establishesTopLayer {
            return isRenderViewLayer()
        }
        switch position {
        case .Fixed:
            return renderer().canContainFixedPositionObjectsForSwift()
        case .Absolute:
            return renderer().canContainAbsolutelyPositionedObjectsForSwift()
        default:
            assertionFailure()
            return false
        }
    }

    @cxx
    @implementation
    public func linkEnclosingAncestorForPosition(_ position: WebCore.PositionType) -> WebCore.LayerRef {
        let topLayer = establishesTopLayerBody()
        var current = self.parent()
        while let layer = current, !layer.isContainerForPositioned(position, topLayer) {
            current = layer.parent()
        }
        assert(!topLayer || current == nil || isSameRenderLayer(current, renderer().view().layer()))
        return WebCore.LayerRef(current)
    }

    @cxx
    @implementation
    public func linkEnclosingFrameRenderLayer() -> WebCore.LayerRef {
        guard let ownerElement = renderer().document().ownerElement(), let ownerRenderer = ownerElement.renderer() else {
            return WebCore.LayerRef()
        }
        return WebCore.LayerRef(ownerRenderer.enclosingLayer())
    }

    @cxx
    @implementation
    public func linkEnclosingTransformedAncestor() -> WebCore.LayerRef {
        var current = self.parent()
        while let layer = current, !layer.isRenderViewLayer(), layer.transformValue().value == nil {
            current = layer.parent()
        }
        return WebCore.LayerRef(current)
    }

    @cxx
    @implementation
    public func linkClippingRootForPainting() -> WebCore.LayerRef {
        if isComposited() {
            return WebCore.LayerRef(self)
        }

        if paintsIntoProvidedBacking() {
            return WebCore.LayerRef(backingProviderLayer())
        }

        let backfaceVisibilityInteroperability = renderer().settings().css3DTransformBackfaceVisibilityInteroperabilityEnabled()
        var current: WebCore.RenderLayer? = self
        while let layer = current {
            if layer.isRenderViewLayer() {
                return WebCore.LayerRef(layer)
            }

            let next = layer.paintOrderParentLayer()!
            if next.transformValue().value != nil || WebCore.compositedWithOwnBackingStore(next) {
                return WebCore.LayerRef(next)
            }

            if backfaceVisibilityInteroperability && next.participatesInPreserve3D()
                && next.renderer()[.Style].backfaceVisibility() == .Hidden
            {
                return WebCore.LayerRef(next)
            }

            if next.paintsIntoProvidedBacking() {
                return WebCore.LayerRef(next.backingProviderLayer())
            }
            current = next
        }

        assertionFailure()
        return WebCore.LayerRef()
    }

    // MARK: Stacking and backdrop roots from style

    @inline(always)
    private func canCreateStackingContext() -> Bool {
        let layerRenderer = renderer()
        // RenderObject's isPositioned(): the renderer also sees its layout box's.
        let rendererObject: WebCore.RenderObject = layerRenderer
        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        let hasAppleVisualEffect = layerRenderer.hasAppleVisualEffect()
        #else
        let hasAppleVisualEffect = false
        #endif
        return layerRenderer.hasTransformRelatedProperty()
            || layerRenderer.hasClipPath()
            || layerRenderer.hasFilter()
            || layerRenderer.hasMask()
            || layerRenderer.hasBackdropFilter()
            || hasAppleVisualEffect
            || layerRenderer.hasBlendMode()
            || layerRenderer.isTransparent()
            || layerRenderer.requiresRenderingConsolidationForViewTransition()
            || layerRenderer.isRenderViewTransitionCapture()
            || rendererObject.isPositioned() // Note that this only creates stacking context in conjunction with explicit z-index.
            || layerRenderer.hasReflection()
            || layerRenderer[.Style].isolation() != .Auto
            || layerRenderer.shouldApplyPaintContainment()
            || !layerRenderer[.Style].usedZIndexIsAuto()
            || layerRenderer[.Style].willChangeCanCreateStackingContext()
            || establishesTopLayerBody()
            || (layerRenderer.isSVGLayerAwareRenderer() && layerRenderer.document().settings().layerBasedSVGEngineEnabled())
    }

    @cxx
    @implementation
    public func shouldBeNormalFlowOnly() -> Bool {
        shouldBeNormalFlowOnlyBody()
    }

    // shouldBeNormalFlowOnly(), inlined into its Swift callers.
    @inline(always)
    fileprivate func shouldBeNormalFlowOnlyBody() -> Bool {
        if canCreateStackingContext() {
            return false
        }
        let layerRenderer = renderer()
        return layerRenderer.hasNonVisibleOverflow()
            || layerRenderer.isRenderHTMLCanvas()
            || layerRenderer.isRenderVideo()
            || layerRenderer.isRenderEmbeddedObject()
            || layerRenderer.isRenderIFrame()
            || (layerRenderer[.Style].specifiesColumns() && !isRenderViewLayer())
            || layerRenderer.isRenderFragmentedFlow()
    }

    @cxx
    @implementation
    public func shouldBeCSSStackingContext() -> Bool {
        shouldBeCSSStackingContextBody()
    }

    // shouldBeCSSStackingContext(), inlined into its Swift callers.
    @inline(always)
    fileprivate func shouldBeCSSStackingContextBody() -> Bool {
        !renderer()[.Style].usedZIndexIsAuto() || shouldBeCSSStackingContextIgnoringZIndexBody()
    }

    @cxx
    @implementation
    public func shouldBeCSSStackingContextIgnoringZIndex() -> Bool {
        shouldBeCSSStackingContextIgnoringZIndexBody()
    }

    // shouldBeCSSStackingContextIgnoringZIndex(), inlined into its Swift callers.
    @inline(always)
    fileprivate func shouldBeCSSStackingContextIgnoringZIndexBody() -> Bool {
        let layerRenderer = renderer()
        return layerRenderer.shouldApplyLayoutContainment()
            || layerRenderer.shouldApplyPaintContainment()
            || layerRenderer.requiresRenderingConsolidationForViewTransition()
            || layerRenderer.isRenderViewTransitionCapture()
            || layerRenderer.isViewTransitionRoot()
            || layerRenderer.isViewTransitionContainingBlock()
            || isRenderViewLayer()
    }

    @cxx
    @implementation
    public func computeCanBeBackdropRoot() -> Bool {
        let layerRenderer = renderer()
        if !layerRenderer.settings().cssUnprefixedBackdropFilterEnabled() {
            return false
        }
        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        let hasAppleVisualEffect = layerRenderer.hasAppleVisualEffect()
        #else
        let hasAppleVisualEffect = false
        #endif

        // In order to match other impls and not the spec, the document element should
        // only be a backdrop root (and be isolated from the base background color) if
        // another group rendering effect is present.
        // https://github.com/w3c/fxtf-drafts/issues/557
        return isRenderViewLayer()
            || layerRenderer.isTransparent()
            || layerRenderer.hasBackdropFilter()
            || hasAppleVisualEffect
            || layerRenderer.hasClipPath()
            || layerRenderer.hasFilter()
            || layerRenderer.hasBlendMode()
            || layerRenderer.hasMask()
            || (layerRenderer.requiresRenderingConsolidationForViewTransition() && !layerRenderer.isDocumentElementRenderer())
            || layerRenderer[.Style].willChangeCanBeBackdropRoot()
    }

    // MARK: Ancestor-dependent state

    @cxx
    @implementation
    public func updateAncestorDependentState() {
        updateAncestorDependentStateBody()
    }

    @inline(always)
    func updateAncestorDependentStateBody() {
        if isSVGLayer() {
            updateAncestorDependentStateForSVG()
        }

        let layerRenderer = renderer()
        var insideSVGForeignObject = false
        if layerRenderer.document().mayHaveRenderedSVGForeignObjects() {
            if hasAncestorRenderer(layerRenderer, where: { $0.isLegacyRenderSVGForeignObject() }) {
                insideSVGForeignObject = true
            } else if isSVGLayer() && hasAncestorRenderer(layerRenderer, where: { $0.isRenderSVGForeignObject() }) {
                insideSVGForeignObject = true
            }
        }

        let insideDrawableCanvas = layerRenderer.settings().htmlInCanvasEnabled() && layerRenderer.isInsideDrawableCanvas()

        if insideSVGForeignObject == m_insideSVGForeignObject && insideDrawableCanvas == m_insideDrawableCanvas {
            return
        }

        m_insideSVGForeignObject = insideSVGForeignObject
        m_insideDrawableCanvas = insideDrawableCanvas
        updateSelfPaintingLayer()
    }

    // MARK: Repaint state

    @cxx
    @implementation
    public func setRepaintStatus(_ status: WebCore.RepaintStatus) {
        setRepaintStatusBody(status)
    }

    // setRepaintStatus(), inlined into its Swift callers.
    @inline(always)
    func setRepaintStatusBody(_ status: WebCore.RepaintStatus) {
        if status != m_repaintStatus {
            m_repaintStatus = status
            setNeedsPositionUpdate()
        }
    }

    @cxx
    @implementation
    public func clearRepaintRects() {
        m_repaintRectsValid = false
    }

    @cxx
    @implementation
    public func compositingStatusChanged(_ layoutUpToDate: WebCore.LayoutUpToDate) {
        updateDescendantDependentFlags()
        if self.parent() != nil || isRenderViewLayer() {
            updateRepaintRectsIncludingDescendants(.Recompute)
        }
        if layoutUpToDate == .No {
            setSelfAndDescendantsNeedPositionUpdate()
        }
    }

    @cxx
    @implementation
    public func repaintRectIncludingNonCompositingDescendants() -> WebCore.LayoutRect {
        var repaintRect = WebCore.LayoutRect()
        if m_repaintRectsValid {
            repaintRect = m_repaintRects.clippedOverflowRect
        }
        var child = self.firstChild()
        while let current = child {
            // Don't include repaint rects for composited child layers; they will paint themselves and have a different origin.
            if !current.isComposited() {
                repaintRect.uniteIfNonZero(current.repaintRectIncludingNonCompositingDescendants())
            }
            child = current.nextSibling()
        }
        return repaintRect
    }

    @cxx
    @implementation
    public func updateBlendMode() {
        let hadBlendMode = m_blendMode != UInt32(WebCore.BlendMode.Normal.rawValue)
        if let parent = self.parent(), hadBlendMode != hasBlendMode() {
            if hasBlendMode() {
                parent.updateAncestorChainHasBlendingDescendants()
            } else {
                parent.dirtyAncestorChainHasBlendingDescendants()
            }
        }

        let newBlendMode = UInt32(renderer()[.Style].usedBlendMode().rawValue)
        if newBlendMode != m_blendMode {
            m_blendMode = newBlendMode
        }
    }

    // MARK: Painting state

    @cxx
    @implementation
    public func cannotBlitToWindow() -> Bool {
        if isTransparent() || hasReflection() || isTransformed() {
            return true
        }
        guard let parent = self.parent() else {
            return false
        }
        return parent.cannotBlitToWindow()
    }

    @cxx
    @implementation
    public func canRender3DTransforms() -> Bool {
        compositor().canRender3DTransforms()
    }

    @cxx
    @implementation
    public func repaintIncludingDescendants() {
        renderer().repaint()
        var child = self.firstChild()
        while let current = child {
            current.repaintIncludingDescendants()
            child = current.nextSibling()
        }
    }

    @cxx
    @implementation
    public func canUseOffsetFromAncestor(_ ancestor: borrowing WebCore.RenderLayer) -> Bool {
        let ancestorRef = WebCore.LayerRef(copy ancestor)
        var current: WebCore.RenderLayer? = self
        while let layer = current, !(WebCore.LayerRef(layer) == ancestorRef) {
            if !layer.canUseOffsetFromAncestor() {
                return false
            }
            current = layer.parent()
        }
        return true
    }

    @cxx
    @implementation
    public func hasVisibleBoxDecorationsOrBackground() -> Bool {
        let layerRenderer = renderer()
        return layerRenderer.hasVisibleBoxDecorations() || layerRenderer[.Style].hasOutline()
    }

    // MARK: Flags that depend on the descendants

    @cxx
    @implementation
    public func setBehavesAsFixed(_ behavesAsFixed: Bool) {
        if m_behavesAsFixed != behavesAsFixed && renderer().isFixedPositioned() {
            setNeedsCompositingConfigurationUpdate()
        }
        m_behavesAsFixed = behavesAsFixed
    }

    // A fixed layer is not composited while it has nothing to paint (RenderLayerCompositor::requiresCompositingForPosition()).
    // When it gains visible content or a visible descendant, it needs to be reevaluated; otherwise it keeps painting into
    // its ancestor's backing store and does not stay fixed during rubberbanding.
    @cxx
    @implementation
    public func updateCompositingForViewportConstrainedLayerWithNoVisibleContent() {
        if viewportConstrainedNotCompositedReason() == WebCore.RenderLayer.NotCompositedForNoVisibleContent {
            setNeedsPostLayoutCompositingUpdate()
        }
    }

    @cxx
    @implementation
    public func updateDescendantDependentFlags() {
        if m_visibleDescendantStatusDirty || m_hasSelfPaintingLayerDescendantDirty || m_hasNotIsolatedBlendingDescendantsStatusDirty
            || m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty || m_hasViewportConstrainedDescendantStatusDirty
        {
            var hasVisibleDescendant = false
            var hasSelfPaintingLayerDescendant = false
            var hasNotIsolatedBlendingDescendants = false
            var hasAlwaysIncludedInZOrderListsDescendants = false
            var hasViewportConstrainedDescendant = false

            if m_hasNotIsolatedBlendingDescendantsStatusDirty {
                m_hasNotIsolatedBlendingDescendantsStatusDirty = false
                updateSelfPaintingLayer()
            }

            // One binding per step: the loop holds only the child it is on. The update of a child whose flags are
            // clean does nothing, so only a dirty child is updated.
            var nextChild = self.firstChild()
            while let current = nextChild.take() {
                if current.descendantDependentFlagsAreDirty() {
                    current.updateDescendantDependentFlags()
                }

                let childRenderer = current.renderer()
                if current.m_hasVisibleContent || current.m_hasVisibleDescendant {
                    hasVisibleDescendant = true
                }
                if current.m_isSelfPaintingLayer || current.m_hasSelfPaintingLayerDescendant {
                    hasSelfPaintingLayerDescendant = true
                }
                if childRenderer.hasBlendMode() || (current.m_hasNotIsolatedBlendingDescendants && !current.isolatesBlending()) {
                    hasNotIsolatedBlendingDescendants = true
                }
                if current.m_alwaysIncludedInZOrderLists || current.m_hasAlwaysIncludedInZOrderListsDescendants {
                    hasAlwaysIncludedInZOrderListsDescendants = true
                }
                if current.m_hasViewportConstrainedDescendant || childRenderer.isFixedPositioned() || childRenderer.isStickilyPositioned() {
                    hasViewportConstrainedDescendant = true
                }
                nextChild = current.nextSibling()
            }

            if hasVisibleDescendant != m_hasVisibleDescendant {
                m_hasVisibleDescendant = hasVisibleDescendant
                if !m_isNormalFlowOnly {
                    dirtyHiddenStackingContextAncestorZOrderLists()
                }
                updateCompositingForViewportConstrainedLayerWithNoVisibleContent()
            }
            m_visibleDescendantStatusDirty = false
            m_hasSelfPaintingLayerDescendant = hasSelfPaintingLayerDescendant
            m_hasSelfPaintingLayerDescendantDirty = false
            m_hasAlwaysIncludedInZOrderListsDescendants = hasAlwaysIncludedInZOrderListsDescendants
            m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty = false
            m_hasViewportConstrainedDescendant = hasViewportConstrainedDescendant
            m_hasViewportConstrainedDescendantStatusDirty = false

            m_hasNotIsolatedBlendingDescendants = hasNotIsolatedBlendingDescendants
        }

        if m_visibleContentStatusDirty {
            // We need the parent to know if we have skipped content or content-visibility root.
            let layerRenderer: WebCore.RenderObject = renderer()
            if layerRenderer[.Style].isSkippedRootOrSkippedContent() && layerRenderer.parent() == nil {
                return
            }
            let hasVisibleContent = computeHasVisibleContent()
            if hasVisibleContent != m_hasVisibleContent {
                m_hasVisibleContent = hasVisibleContent
                if !m_isNormalFlowOnly {
                    // We don't collect invisible layers in z-order lists if they are not composited.
                    // As we change visibility, we need to dirty our stacking containers ancestors to be properly
                    // collected.
                    dirtyHiddenStackingContextAncestorZOrderLists()
                }
                updateCompositingForViewportConstrainedLayerWithNoVisibleContent()
            }
            m_visibleContentStatusDirty = false
        }

        assert(!descendantDependentFlagsAreDirty())
    }

    @cxx
    @implementation
    public func dirtyVisibleContentStatusIncludingAncestors() {
        dirtyVisibleContentStatus()

        // computeHasVisibleContent() looks past a hidden layer into the children it paints, so those
        // ancestors are stale too. That walk stops at the first self-painting layer.
        if isSelfPaintingLayer() {
            return
        }
        var ancestor = self.parent()
        while let current = ancestor {
            if current.hasHiddenUsedVisibility {
                current.dirtyVisibleContentStatus()
            }
            if current.isSelfPaintingLayer() {
                break
            }
            ancestor = current.parent()
        }
    }
    // MARK: Position update flags

    @cxx
    @implementation
    private static func flagsForUpdateLayerPositions(_ startingLayer: WebCore.RenderLayer) -> WebCore.RenderLayer.UpdateLayerPositionsFlags
    {
        typealias Flags = WebCore.RenderLayer.UpdateLayerPositionsFlags
        var flags = Flags(WebCore.RenderLayer.CheckForRepaint)

        if let parent = startingLayer.parent() {
            let parentRenderer = parent.renderer()
            let parentTransform = parent.transformValue().value
            if parent.hasFixedContainingBlockAncestor()
                || (!parent.isRenderViewLayer() && parentRenderer.canContainFixedPositionObjectsForSwift())
            {
                flags.add(Flags(WebCore.RenderLayer.SeenFixedContainingBlockLayer))
            }
            if parent.hasTransformedAncestor() || parentTransform != nil {
                flags.add(Flags(WebCore.RenderLayer.SeenTransformedLayer))
            }
            if parent.has3DTransformedAncestor() || (parentTransform != nil && !parentTransform!.isAffine()) {
                flags.add(Flags(WebCore.RenderLayer.Seen3DTransformedLayer))
            }
            if parent.behavesAsFixed() || (parentRenderer.isFixedPositioned() && !parent.hasFixedContainingBlockAncestor()) {
                flags.add(Flags(WebCore.RenderLayer.SeenFixedLayer))
            }
            if parentRenderer.isStickilyPositioned() {
                flags.add(Flags(WebCore.RenderLayer.SeenStickyLayer))
            }
            if parent.hasCompositedScrollingAncestor() || parent.hasCompositedScrollableOverflow() {
                flags.add(Flags(WebCore.RenderLayer.SeenCompositedScrollingLayer))
            }
        }
        return flags
    }

    @cxx
    @implementation
    private func ancestorLayerPositionStateChanged(_ flags: WebCore.RenderLayer.UpdateLayerPositionsFlags) -> Bool {
        m_hasFixedContainingBlockAncestor != flags.contains(WebCore.RenderLayer.SeenFixedContainingBlockLayer)
            || m_hasTransformedAncestor != flags.contains(WebCore.RenderLayer.SeenTransformedLayer)
            || m_has3DTransformedAncestor != flags.contains(WebCore.RenderLayer.Seen3DTransformedLayer)
            || m_hasFixedAncestor != flags.contains(WebCore.RenderLayer.SeenFixedLayer)
            || m_hasPaginatedAncestor != flags.contains(WebCore.RenderLayer.UpdatePagination)
            || m_hasCompositedScrollingAncestor != flags.contains(WebCore.RenderLayer.SeenCompositedScrollingLayer)
            || m_hasStickyAncestor != flags.contains(WebCore.RenderLayer.SeenStickyLayer)
    }

    // MARK: Repaint rects

    @cxx
    @implementation
    public func shouldRepaintAfterLayout() -> Bool {
        if isSVGLayer() && shouldSkipRepaintAfterLayoutForSVG() {
            return false
        }

        if m_repaintStatus == .NeedsNormalRepaint || m_repaintStatus == .NeedsFullRepaint {
            return true
        }

        // Composited layers that were moved during a positioned movement only
        // layout, don't need to be repainted. They just need to be recomposited.
        assert(m_repaintStatus == .NeedsFullRepaintForOutOfFlowMovementLayout)
        return !WebCore.compositedWithOwnBackingStore(self)
    }

    @cxx
    @implementation
    public func scheduledFullRepaintCoversContentPaintedBy(_ paintingLayer: borrowing WebCore.RenderLayer) -> Bool {
        // Only NeedsFullRepaint is repainted in full after layout, and only within this layer's visual overflow.
        if !isSelfPaintingLayer() || m_repaintStatus != .NeedsFullRepaint {
            return false
        }
        let painting: WebCore.RenderLayer = copy paintingLayer
        if isSameRenderLayer(painting, self) {
            return true
        }
        guard let paintingLayerRect = painting.cachedClippedOverflowRect().value, let layerRect = cachedClippedOverflowRect().value else {
            return false
        }
        return WebCore.RenderObject.isSameRenderer(painting.repaintContainer(), repaintContainer()) && layerRect.contains(paintingLayerRect)
    }

    // MARK: Painting predicates

    @cxx
    @implementation
    public func renderableTransform(_ paintBehavior: WebCore.RenderLayer.PaintBehaviors) -> WebCore.TransformationMatrix {
        guard let transform = transformValue().value else {
            return WebCore.TransformationMatrix()
        }
        if paintBehavior.contains(.FlattenCompositingLayers) {
            // During snapshotting (e.g., for view transitions), use currentTransform(),
            // which already handles accelerated transform animations instead of relying
            // on potentially stale m_transform values.
            var matrix = paintBehavior.contains(.Snapshotting) ? currentTransform() : transform
            WebCore.makeMatrixRenderable(&matrix, false /* flatten 3d */)
            return matrix
        }
        return transform
    }

    // MARK: Visibility predicates

    @cxx
    @implementation
    public func hasVisibleBoxDecorations() -> Bool {
        if !m_hasVisibleContent {
            return false
        }
        return hasVisibleBoxDecorationsOrBackground() || (scrollableArea()?.hasOverflowControls() ?? false)
    }

    @cxx
    @implementation
    public func isVisibilityHiddenOrOpacityZero() -> Bool {
        !m_hasVisibleContent || renderer()[.Style].opacityIsTransparent()
    }

    @cxx
    @implementation
    public func isSubtreeVisibilityHiddenOrOpacityZero() -> Bool {
        (!m_hasVisibleContent && !m_hasVisibleDescendant) || renderer()[.Style].opacityIsTransparent()
    }

    @cxx
    @implementation
    public func isTransparentRespectingParentFrames() -> Bool {
        let minimumVisibleOpacity = 0.01

        var currentOpacity: Float = 1
        var layer: WebCore.RenderLayer? = self
        while let current = layer {
            currentOpacity *= current.renderer()[.Style].opacityValue()
            if Double(currentOpacity) < minimumVisibleOpacity {
                return true
            }
            layer = current.parent() ?? current.enclosingFrameRenderLayer()
        }
        return false
    }

    // MARK: Containing block ancestor

    @cxx
    @implementation
    public func linkEnclosingContainingBlockLayer(_ crossFrameBoundaries: WebCore.CrossFrameBoundaries) -> WebCore.LayerRef {
        WebCore.LayerRef(enclosingContainingBlockLayerOrNil(crossFrameBoundaries))
    }

    private func enclosingContainingBlockLayerOrNil(_ crossFrameBoundaries: WebCore.CrossFrameBoundaries) -> WebCore.RenderLayer? {
        if let ancestor = enclosingLayerInContainingBlockOrder() {
            return ancestor
        }
        if crossFrameBoundaries.rawValue == false {
            return nil
        }
        return enclosingFrameRenderLayer()
    }

    // MARK: Coordinate conversion

    @cxx
    @implementation
    public func linkCommonAncestorWithLayer(_ layer: borrowing WebCore.RenderLayer) -> WebCore.LayerRef {
        let other: WebCore.RenderLayer = copy layer
        return WebCore.LayerRef(commonAncestor(with: other))
    }

    private func commonAncestor(with other: WebCore.RenderLayer) -> WebCore.RenderLayer? {
        if isSameRenderLayer(self, other) {
            return self
        }
        // The first ancestor of the other layer that is also an ancestor of this one.
        var candidate: WebCore.RenderLayer? = other
        while let current = candidate {
            var ancestor: WebCore.RenderLayer? = self
            while let chainLayer = ancestor {
                if isSameRenderLayer(chainLayer, current) {
                    return current
                }
                ancestor = chainLayer.parent()
            }
            candidate = current.parent()
        }
        return nil
    }

    @cxx
    @implementation
    public func convertToLayerCoords(
        _ ancestorLayer: WebCore.RenderLayer?,
        _ location: WebCore.LayoutPoint,
        _ adjustForColumns: WebCore.RenderLayer.ColumnOffsetAdjustment
    ) -> WebCore.LayoutPoint {
        if isSameRenderLayer(ancestorLayer, self) {
            return location
        }

        var currentLayer: WebCore.RenderLayer? = self
        var locationInLayerCoords = location
        while let current = currentLayer, !isSameRenderLayer(current, ancestorLayer) {
            currentLayer = current.accumulateOffset(towards: ancestorLayer, &locationInLayerCoords, adjustForColumns)
        }

        // Pixel snap the whole SVG subtree as one "block" -- not individual layers down the SVG render tree.
        let layerRenderer = renderer()
        if isSVGLayer() && layerRenderer.isRenderSVGRoot() {
            return WebCore.LayoutPoint(
                WebCore.roundPointToDevicePixels(locationInLayerCoords, layerRenderer.document().deviceScaleFactor())
            )
        }
        return locationInLayerCoords
    }

    @cxx
    @implementation
    public func offsetFromAncestor(
        _ ancestorLayer: WebCore.RenderLayer?,
        _ adjustForColumns: WebCore.RenderLayer.ColumnOffsetAdjustment
    ) -> WebCore.LayoutSize {
        WebCore.toLayoutSize(convertToLayerCoords(ancestorLayer, WebCore.LayoutPoint(), adjustForColumns))
    }

    // Returns the layer reached on the walk up towards the ancestor.
    private func accumulateOffset(
        towards ancestorLayer: WebCore.RenderLayer?,
        _ location: inout WebCore.LayoutPoint,
        _ adjustForColumns: WebCore.RenderLayer.ColumnOffsetAdjustment
    ) -> WebCore.RenderLayer? {
        assert(!isSameRenderLayer(ancestorLayer, self))

        let layerRenderer = renderer()
        let position = layerRenderer[.Style].position()

        // FIXME: Positioning of out-of-flow(fixed, absolute) elements collected in a RenderFragmentedFlow
        // may need to be revisited in a future patch.
        // If the fixed renderer is inside a RenderFragmentedFlow, we should not compute location using localToAbsolute,
        // since localToAbsolute maps the coordinates from named flow to regions coordinates and regions can be
        // positioned in a completely different place in the viewport (RenderView).
        if position == .Fixed && (ancestorLayer == nil || isSameRenderLayer(ancestorLayer, layerRenderer.view().layer())) {
            // If the fixed layer's container is the root, just add in the offset of the view. We can obtain this by calling
            // localToAbsolute() on the RenderView.
            location.moveBy(WebCore.LayoutPoint(layerRenderer.fixedOriginToAbsoluteForSwift()))
            return ancestorLayer
        }

        // For the fixed positioned elements inside a render flow thread, we should also skip the code path below
        // Otherwise, for the case of ancestorLayer == rootLayer and fixed positioned element child of a transformed
        // element in render flow thread, we will hit the fixed positioned container before hitting the ancestor layer.
        if position == .Fixed {
            // For a fixed layers, we need to walk up to the root to see if there's a fixed position container
            // (e.g. a transformed layer). It's an error to call offsetFromAncestor() across a layer with a transform,
            // so we should always find the ancestor at or before we find the fixed position container, if
            // the container is transformed.
            var fixedPositionContainerLayer: WebCore.RenderLayer? = nil
            var foundAncestor = false
            var currentLayer = self.parent()
            while let current = currentLayer {
                if isSameRenderLayer(current, ancestorLayer) {
                    foundAncestor = true
                }
                if current.isContainerForPositioned(.Fixed, establishesTopLayerBody()) {
                    fixedPositionContainerLayer = current
                    // A layer that has a transform-related property but not a
                    // transform still acts as a fixed-position container.
                    // Accumulating offsets across such layers is allowed.
                    if current.transformValue().value != nil {
                        assert(foundAncestor)
                    }
                    break
                }
                currentLayer = current.parent()
            }

            assert(fixedPositionContainerLayer != nil) // We should have hit the RenderView's layer at least.

            if !isSameRenderLayer(fixedPositionContainerLayer, ancestorLayer) {
                let fixedContainerCoords = offsetFromAncestor(fixedPositionContainerLayer, WebCore.RenderLayer.DontAdjustForColumns)
                let ancestorCoords =
                    foundAncestor
                    ? ancestorLayer!.offsetFromAncestor(fixedPositionContainerLayer, WebCore.RenderLayer.DontAdjustForColumns)
                    : WebCore.LayoutSize()
                location.move(fixedContainerCoords - ancestorCoords)
                return foundAncestor ? ancestorLayer : fixedPositionContainerLayer
            }
        }

        if position == .Fixed {
            assert(ancestorLayer != nil)
            if isSameRenderLayer(ancestorLayer, layerRenderer.view().layer()) {
                // Add location in flow thread coordinates.
                location.moveBy(m_topLeft)

                // Add flow thread offset in view coordinates since the view may be scrolled.
                location.moveBy(WebCore.LayoutPoint(layerRenderer.view().fixedOriginToAbsoluteForSwift()))
                return ancestorLayer
            }
        }

        var parentLayer: WebCore.RenderLayer?
        if position == .Absolute || position == .Fixed {
            // Do what enclosingAncestorForPosition() does, but check for ancestorLayer along the way.
            parentLayer = self.parent()
            var foundAncestorFirst = false
            // Read once: the walk reads only the ancestors' state.
            let topLayer = establishesTopLayerBody()
            while let current = parentLayer {
                // RenderFragmentedFlow is a positioned container, child of RenderView, positioned at (0,0).
                // This implies that, for out-of-flow positioned elements inside a RenderFragmentedFlow,
                // we are bailing out before reaching root layer.
                if current.isContainerForPositioned(position, topLayer) {
                    break
                }
                if isSameRenderLayer(current, ancestorLayer) {
                    foundAncestorFirst = true
                    break
                }
                parentLayer = current.parent()
            }

            if foundAncestorFirst {
                // Found ancestorLayer before the abs. positioned container, so compute offset of both relative
                // to enclosingAncestorForPosition and subtract.
                let positionedAncestor = parentLayer!.enclosingAncestorForPosition(position)
                let thisCoords = offsetFromAncestor(positionedAncestor, WebCore.RenderLayer.DontAdjustForColumns)
                let ancestorCoords = ancestorLayer!.offsetFromAncestor(positionedAncestor, WebCore.RenderLayer.DontAdjustForColumns)
                location.move(thisCoords - ancestorCoords)
                return ancestorLayer
            }
        } else {
            parentLayer = self.parent()
        }

        guard let parentLayer else {
            return nil
        }

        location.moveBy(m_topLeft)

        if adjustForColumns == WebCore.RenderLayer.AdjustForColumns {
            adjustLocationForColumns(ancestorLayer, &location)
        }

        return parentLayer
    }

    // MARK: Position updates

    @cxx
    @implementation
    public func updateLayerPositionsAfterStyleChange(_ environmentChanged: Bool) {
        if environmentChanged {
            setSelfAndDescendantsNeedPositionUpdate()
        }

        willUpdateLayerPositions()

        var flags = WebCore.RenderLayer.flagsForUpdateLayerPositions(self)
        if environmentChanged {
            flags.add(WebCore.RenderLayer.UpdateLayerPositionsFlags(WebCore.RenderLayer.EnvironmentChanged))
        }
        recursiveUpdateLayerPositions(flags, verifyOnly: false)
    }

    @cxx
    @implementation
    public func updateLayerPositionsAfterLayout(_ didFullRepaint: Bool, _ environmentChanged: Bool) {
        typealias Flags = WebCore.RenderLayer.UpdateLayerPositionsFlags
        assert(isRenderViewLayer())

        if environmentChanged {
            setSelfAndDescendantsNeedPositionUpdate()
        }

        willUpdateLayerPositions()

        var flags = WebCore.RenderLayer.flagsForUpdateLayerPositions(self)
        if didFullRepaint {
            flags.remove(Flags(WebCore.RenderLayer.CheckForRepaint))
            flags.add(Flags(WebCore.RenderLayer.NeedsFullRepaintInBacking))
        }
        if environmentChanged {
            flags.add(Flags(WebCore.RenderLayer.EnvironmentChanged))
        }
        recursiveUpdateLayerPositions(flags, verifyOnly: false)
    }

    // With verifyOnly, which runs only where layerPositionsAssertEnabled() is true, it checks that a layer whose subtree the update
    // skipped is already up to date.
    private func recursiveUpdateLayerPositions(_ flags: WebCore.RenderLayer.UpdateLayerPositionsFlags, verifyOnly: Bool) {
        typealias Flags = WebCore.RenderLayer.UpdateLayerPositionsFlags
        let writing = !verifyOnly
        var flags = flags

        if ancestorLayerPositionStateChanged(flags) {
            flags.add(Flags(WebCore.RenderLayer.SubtreeNeedsUpdate))
        }

        if writing && !needsPositionUpdate() && !flags.containsAny(WebCore.RenderLayer.invalidationLayerPositionsFlags()) {
            if WebCore.RenderLayer.layerPositionsAssertEnabled() {
                recursiveUpdateLayerPositions(flags, verifyOnly: true)
            }
            return
        }

        if m_layerPositionDirtyBits.contains(.AllDescendantsNeedPositionUpdate) {
            layerPositionsAssert(writing)
            flags.add(Flags(WebCore.RenderLayer.SubtreeNeedsUpdate))
        }

        if updateLayerPosition(&flags, recordingFlags: true, verifyOnly: verifyOnly) {
            flags.add(Flags(WebCore.RenderLayer.SubtreeNeedsUpdate))
        }

        if let scrollableArea = scrollableArea() {
            layerPositionsAssert(writing || !scrollableArea.hasPostLayoutScrollPosition())
            scrollableArea.applyPostLayoutScrollPositionIfNeeded()
        }

        // Clear our cached clip rect information.
        if writing {
            clearClipRects(WebCore.AllClipRectTypes)
        } else {
            verifyClipRects()
        }

        if writing, let scrollableArea = scrollableArea(), scrollableArea.hasOverflowControls() {
            // FIXME: It looks suspicious to call convertToLayerCoords here
            // as canUseOffsetFromAncestor may be true for an ancestor layer.
            let offsetFromRoot = offsetFromAncestor(root(), WebCore.RenderLayer.DontAdjustForColumns)
            _ = scrollableArea.positionOverflowControls(WebCore.roundedIntSize(offsetFromRoot))
        }

        if writing {
            updateLayerListsIfNeeded()
        } else {
            layerPositionsAssert(!m_visibleDescendantStatusDirty)
            layerPositionsAssert(!m_hasSelfPaintingLayerDescendantDirty)
            layerPositionsAssert(!m_hasViewportConstrainedDescendantStatusDirty)
            layerPositionsAssert(!hasNotIsolatedBlendingDescendantsStatusDirty())
            layerPositionsAssert(!m_visibleContentStatusDirty)
        }

        let layerRenderer = renderer()
        if flags.contains(WebCore.RenderLayer.UpdatePagination) {
            let oldEnclosingPaginationLayer = enclosingPaginationLayerInStore()
            updatePagination()
            layerPositionsAssert(writing || isSameRenderLayer(enclosingPaginationLayerInStore(), oldEnclosingPaginationLayer))
        } else if layerRenderer.isRenderFragmentedFlow() {
            layerPositionsAssert(writing || isSameRenderLayer(enclosingPaginationLayerInStore(), self))
            setEnclosingPaginationLayerInStore(self)
            flags.add(Flags(WebCore.RenderLayer.UpdatePagination))
        } else {
            layerPositionsAssert(writing || enclosingPaginationLayerInStore() == nil)
            setEnclosingPaginationLayerInStore(nil)
        }

        if isSVGLayer() {
            assert(layerRenderer.isRenderSVGRoot() || !layerRenderer.isFixedPositioned())
        }

        if writing {
            repaintAfterLayoutIfNecessary(flags.contains(WebCore.RenderLayer.CheckForRepaint))

            m_repaintStatus = .NeedsNormalRepaint
            m_hasFixedContainingBlockAncestor = flags.contains(WebCore.RenderLayer.SeenFixedContainingBlockLayer)
            m_hasTransformedAncestor = flags.contains(WebCore.RenderLayer.SeenTransformedLayer)
            m_has3DTransformedAncestor = flags.contains(WebCore.RenderLayer.Seen3DTransformedLayer)
            m_hasFixedAncestor = flags.contains(WebCore.RenderLayer.SeenFixedLayer)
            m_hasStickyAncestor = flags.contains(WebCore.RenderLayer.SeenStickyLayer)
            m_hasPaginatedAncestor = flags.contains(WebCore.RenderLayer.UpdatePagination)
            m_hasCompositedScrollingAncestor = flags.contains(WebCore.RenderLayer.SeenCompositedScrollingLayer)
        } else {
            verifyRepaintAfterLayout()

            layerPositionsAssert(m_repaintStatus == .NeedsNormalRepaint)
            layerPositionsAssert(m_hasFixedContainingBlockAncestor == flags.contains(WebCore.RenderLayer.SeenFixedContainingBlockLayer))
            layerPositionsAssert(m_hasTransformedAncestor == flags.contains(WebCore.RenderLayer.SeenTransformedLayer))
            layerPositionsAssert(m_has3DTransformedAncestor == flags.contains(WebCore.RenderLayer.Seen3DTransformedLayer))
            layerPositionsAssert(m_hasFixedAncestor == flags.contains(WebCore.RenderLayer.SeenFixedLayer))
            layerPositionsAssert(m_hasStickyAncestor == flags.contains(WebCore.RenderLayer.SeenStickyLayer))
            layerPositionsAssert(m_hasPaginatedAncestor == flags.contains(WebCore.RenderLayer.UpdatePagination))
            layerPositionsAssert(m_hasCompositedScrollingAncestor == flags.contains(WebCore.RenderLayer.SeenCompositedScrollingLayer))
        }

        // Update the reflection's position and size.
        layoutReflectionAfterPositionUpdate(!writing)

        if !isRenderViewLayer() {
            if layerRenderer.canContainFixedPositionObjectsForSwift() {
                flags.add(Flags(WebCore.RenderLayer.SeenFixedContainingBlockLayer))
            }
            if let transform = transformValue().value {
                flags.add(Flags(WebCore.RenderLayer.SeenTransformedLayer))
                if !transform.isAffine() {
                    flags.add(Flags(WebCore.RenderLayer.Seen3DTransformedLayer))
                }
            }
        }

        // Fixed inside transform behaves like absolute (per spec).
        if m_hasFixedAncestor || (layerRenderer.isFixedPositioned() && !m_hasFixedContainingBlockAncestor) {
            layerPositionsAssert(writing || behavesAsFixed())
            setBehavesAsFixed(true)
            flags.add(Flags(WebCore.RenderLayer.SeenFixedLayer))
        }

        if m_hasStickyAncestor || layerRenderer.isStickilyPositioned() {
            flags.add(Flags(WebCore.RenderLayer.SeenStickyLayer))
        }

        if hasCompositedScrollableOverflow() {
            flags.add(Flags(WebCore.RenderLayer.SeenCompositedScrollingLayer))
        }

        if flags.containsAny(WebCore.RenderLayer.invalidationLayerPositionsFlags())
            || m_layerPositionDirtyBits.contains(.DescendantNeedsPositionUpdate)
        {
            var child = self.firstChild()
            while let current = child {
                current.recursiveUpdateLayerPositions(flags, verifyOnly: verifyOnly)
                child = current.nextSibling()
            }
        } else if WebCore.RenderLayer.layerPositionsAssertEnabled() {
            var child = self.firstChild()
            while let current = child {
                current.recursiveUpdateLayerPositions(flags, verifyOnly: true)
                child = current.nextSibling()
            }
        }

        // FIXME: Verify?
        if writing, let scrollableArea = scrollableArea() {
            scrollableArea.updateMarqueePosition()
        }

        if layerRenderer.isFixedPositioned() && layerRenderer.settings().acceleratedCompositingForFixedPositionEnabled() {
            let intersectsViewport = compositor().fixedLayerIntersectsViewport(self)
            assert(writing || intersectsViewport == m_isFixedIntersectingViewport)
            if intersectsViewport != m_isFixedIntersectingViewport {
                m_isFixedIntersectingViewport = intersectsViewport
                setNeedsPostLayoutCompositingUpdate()
            }
        }

        assert(writing || !flags.contains(WebCore.RenderLayer.ContainingClippingLayerChangedSize))
        assert(writing || !flags.contains(WebCore.RenderLayer.NeedsFullRepaintInBacking))
        if writing && isComposited() {
            updateBackingAfterLayout(
                flags.contains(WebCore.RenderLayer.ContainingClippingLayerChangedSize),
                flags.contains(WebCore.RenderLayer.NeedsFullRepaintInBacking)
            )
        }

        assert(writing || m_layerPositionDirtyBits.isEmpty())
        assert(isSameRenderLayer(backingProviderLayer(), backingProviderLayerAtEndOfCompositingUpdate()))
        clearLayerPositionDirtyBits()
    }

    // MARK: Position updates after scrolling

    @cxx
    @implementation
    public func updateLayerPositionsAfterOverflowScroll() {
        willUpdateLayerPositions()

        // FIXME: why is it OK to not check the ancestors of this layer in order to
        // initialize the HasSeenViewportConstrainedAncestor and HasSeenAncestorWithOverflowClip flags?
        recursiveUpdateLayerPositionsAfterScroll(
            WebCore.RenderLayer.UpdateLayerPositionsAfterScrollFlags(WebCore.RenderLayer.IsOverflowScroll)
        )
    }

    @cxx
    @implementation
    public func updateLayerPositionsAfterDocumentScroll() {
        assert(isRenderViewLayer())

        willUpdateLayerPositions()

        // FIXME(rdar://188839922): Enable for all configs, not just when Site Isolation is enabled.
        var flags = WebCore.RenderLayer.UpdateLayerPositionsAfterScrollFlags()
        if renderer().settings().siteIsolationEnabled() {
            flags.add(WebCore.RenderLayer.UpdateLayerPositionsAfterScrollFlags(WebCore.RenderLayer.SkipsUnconstrainedSubtrees))
        }

        recursiveUpdateLayerPositionsAfterScroll(flags)
    }

    private func recursiveUpdateLayerPositionsAfterScroll(_ flags: WebCore.RenderLayer.UpdateLayerPositionsAfterScrollFlags) {
        typealias Flags = WebCore.RenderLayer.UpdateLayerPositionsAfterScrollFlags
        var flags = flags

        // FIXME: This shouldn't be needed, but there are some corner cases where
        // these flags are still dirty. Update so that the check below is valid.
        updateDescendantDependentFlags()

        // If we have no visible content and no visible descendants, there is no point recomputing
        // our rectangles as they will be empty. If our visibility changes, we are expected to
        // recompute all our positions anyway.
        if !m_hasVisibleDescendant && !m_hasVisibleContent {
            return
        }

        // A document scroll moves only fixed and sticky layers and their descendants, so skip subtrees
        // that contain none of these layers.
        if flags.contains(WebCore.RenderLayer.SkipsUnconstrainedSubtrees) && !flags.contains(WebCore.RenderLayer.IsOverflowScroll)
            && !flags.contains(WebCore.RenderLayer.HasSeenViewportConstrainedAncestor) && !isViewportConstrained()
            && !m_hasViewportConstrainedDescendant
        {
            if WebCore.RenderLayer.layerPositionsAssertEnabled() {
                verifySkippedLayerPositionsAfterDocumentScroll()
            }
            return
        }

        var unusedFlags = WebCore.RenderLayer.UpdateLayerPositionsFlags()
        if updateLayerPosition(&unusedFlags, recordingFlags: false, verifyOnly: false) {
            flags.add(Flags(WebCore.RenderLayer.HasChangedAncestor))
        }

        if flags.contains(WebCore.RenderLayer.HasChangedAncestor) || flags.contains(WebCore.RenderLayer.HasSeenViewportConstrainedAncestor)
            || flags.contains(WebCore.RenderLayer.IsOverflowScroll)
        {
            clearClipRects(WebCore.AllClipRectTypes)
        }

        let layerRenderer = renderer()
        if layerRenderer[.Style].hasViewportConstrainedPosition() {
            flags.add(Flags(WebCore.RenderLayer.HasSeenViewportConstrainedAncestor))
        }

        if layerRenderer.hasNonVisibleOverflow() {
            flags.add(Flags(WebCore.RenderLayer.HasSeenAncestorWithOverflowClip))
        }

        let shouldComputeRepaintRects =
            (flags.contains(WebCore.RenderLayer.HasSeenViewportConstrainedAncestor)
                || (flags.contains(WebCore.RenderLayer.IsOverflowScroll)
                    && flags.contains(WebCore.RenderLayer.HasSeenAncestorWithOverflowClip)))
            && isSelfPaintingLayer()
        // FIXME: We could track the repaint container as we walk down the tree.
        if shouldComputeRepaintRects {
            computeRepaintRects(layerRenderer.containerForRepaint().renderer.get())
        }

        var child = self.firstChild()
        while let current = child {
            current.recursiveUpdateLayerPositionsAfterScroll(flags)
            child = current.nextSibling()
        }

        // We don't update our reflection as scrolling is a translation which does not change the size()
        // of an object, thus RenderReplica will still repaint itself properly as the layer position was
        // updated above.

        scrollableArea()?.updateMarqueePosition()
    }

    // The layer-position checks, made where RenderLayer.cpp's LAYER_POSITIONS_ASSERT makes them.
    private func layerPositionsAssert(_ condition: @autoclosure () -> Bool) {
        if WebCore.RenderLayer.layerPositionsAssertEnabled() {
            assertLayerPosition(condition())
        }
    }

    private func verifySkippedLayerPositionsAfterDocumentScroll() {
        layerPositionsAssert(!isViewportConstrained())
        layerPositionsAssert(!m_hasViewportConstrainedDescendantStatusDirty)

        // recursiveUpdateLayerPositionsAfterScroll() also skips invisible subtrees.
        if !m_hasVisibleDescendant && !m_hasVisibleContent {
            return
        }

        var unusedFlags = WebCore.RenderLayer.UpdateLayerPositionsFlags()
        _ = updateLayerPosition(&unusedFlags, recordingFlags: false, verifyOnly: true)

        var child = self.firstChild()
        while let current = child {
            current.verifySkippedLayerPositionsAfterDocumentScroll()
            child = current.nextSibling()
        }
    }

    // MARK: Backing and painting predicates

    @cxx
    @implementation
    public func hasCompositedMask() -> Bool {
        backing()?.hasMaskLayer() ?? false
    }

    private func paintsToWindow() -> Bool {
        guard let backing = backing() else {
            return true
        }
        return backing.paintsIntoWindow()
    }

    @cxx
    @implementation
    public func paintsWithTransform(_ paintBehavior: WebCore.RenderLayer.PaintBehaviors) -> Bool {
        let paintsToWindow = paintsToWindow()
        return transformValue().value != nil && (paintBehavior.contains(.FlattenCompositingLayers) || paintsToWindow)
    }

    @cxx
    @implementation
    public func shouldPaintMask(
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) -> Bool {
        if !renderer().hasMask() {
            return false
        }
        if paintsToWindow() || paintBehavior.contains(.FlattenCompositingLayers) {
            return true
        }
        return paintFlags.contains(.PaintingCompositingMaskPhase)
    }

    @cxx
    @implementation
    public func shouldApplyClipPath(
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) -> Bool {
        if !renderer().hasClipPath() {
            return false
        }
        if paintsToWindow() || paintBehavior.contains(.FlattenCompositingLayers) {
            return true
        }
        return paintFlags.contains(.PaintingCompositingClipPathPhase) || paintFlags.contains(.CollectingEventRegion)
    }

    @cxx
    @implementation
    public func blendModeAppliesToSVGRootContentsOnly() -> Bool {
        if !hasBlendMode() {
            return false
        }
        let layerRenderer = renderer()
        if layerRenderer.isLegacyRenderSVGRoot() {
            guard let parent = self.parent() else {
                return false
            }
            return parent.isRenderViewLayer()
        }
        // The root background is painted into this layer and must not be blended.
        return layerRenderer.isRenderSVGRoot() && layerRenderer.isDocumentElementRenderer()
    }

    @cxx
    @implementation
    public func setBackingNeedsRepaint(_ shouldClip: WebCore.GraphicsLayerShouldClipToLayer) {
        assert(isComposited())
        let backing = backing()!
        if backing.paintsIntoWindow() {
            // If we're trying to repaint the placeholder document layer, propagate the
            // repaint to the native view system.
            renderer().view().repaintViewRectangle(WebCore.LayoutRect(absoluteBoundingBox()))
        } else {
            backing.setContentsNeedDisplay(shouldClip)
        }
    }

    @cxx
    @implementation
    public func setBackingNeedsRepaintInRect(_ r: WebCore.LayoutRect, _ shouldClip: WebCore.GraphicsLayerShouldClipToLayer) {
        // https://bugs.webkit.org/show_bug.cgi?id=61159 describes an unreproducible crash here,
        // so assert but check that the layer is composited.
        assert(isComposited())
        guard let backing = backing(), !backing.paintsIntoWindow() else {
            // If we're trying to repaint the placeholder document layer, propagate the
            // repaint to the native view system.
            var absRect = r
            absRect.move(offsetFromAncestor(root(), WebCore.RenderLayer.DontAdjustForColumns))
            renderer().view().repaintViewRectangle(absRect)
            return
        }
        backing.setContentsNeedDisplayInRect(r, shouldClip)
    }

    @cxx
    @implementation
    public func disconnectFromBackingProviderLayer(_ flags: WebCore.UpdateBackingSharingFlagSet) {
        guard let provider = backingProviderLayer() else {
            return
        }
        assert(provider.isComposited())
        if let providerBacking = provider.backing() {
            providerBacking.removeBackingSharingLayer(self, flags)
        }
    }

    @cxx
    @implementation
    public func setBackingProviderLayer(_ backingProvider: WebCore.RenderLayer?, _ flags: WebCore.UpdateBackingSharingFlagSet) {
        // The provider may be the layer being destroyed (RenderLayerBacking::clearBackingSharingLayers()), which Swift must
        // not retain, so the comparison is made in C++.
        if backingProviderLayerIs(backingProvider) {
            assert(
                flags.contains(.DuringCompositingUpdate)
                    || isSameRenderLayer(backingProvider, backingProviderLayerAtEndOfCompositingUpdate())
            )
            return
        }

        if !renderer().renderTreeBeingDestroyed() {
            clearClipRectsIncludingDescendants()
        }

        setBackingProviderLayerInStore(backingProvider)
        if !flags.contains(.DuringCompositingUpdate) {
            setBackingProviderLayerAtEndOfCompositingUpdate(backingProvider)
        }
    }

    // MARK: Anchor scroll adjustment

    @cxx
    @implementation
    public func setAnchorScrollAdjustment(_ offset: WebCore.LayoutSize) -> Bool {
        if let current = m_anchorScrollAdjustment.value, current == offset {
            return false
        }
        if renderer().renderTreeBeingDestroyed() {
            return false
        }
        // FIXME: Scroll offset should be adjusted in the scrolling tree so layers stay exactly in sync.
        m_anchorScrollAdjustment = type(of: m_anchorScrollAdjustment).init(offset)
        updateTransform()
        if isComposited() {
            setNeedsCompositingGeometryUpdate()
        }
        return true
    }

    @cxx
    @implementation
    public func clearAnchorScrollAdjustment() {
        if m_anchorScrollAdjustment.value == nil {
            return
        }
        if renderer().renderTreeBeingDestroyed() {
            return
        }
        m_anchorScrollAdjustment = type(of: m_anchorScrollAdjustment).init()
        updateTransform()
        if isComposited() {
            setNeedsCompositingGeometryUpdate()
        }
    }

    // MARK: Layer position

    private func layerPositionAndIntegralSize() -> WebCore.LayoutRect {
        let layerRenderer = renderer()
        let rendererObject: WebCore.RenderObject = layerRenderer
        if rendererObject.isInlineBox() {
            return WebCore.LayoutRect(WebCore.LayoutPoint(), layerRenderer.asRenderBoxModelObject()!.borderBoxRectInContainer().size())
        }

        if let boxRenderer = layerRenderer.asRenderBox() {
            let borderBox = boxRenderer.borderBoxRectInContainer()
            return WebCore.LayoutRect(
                boxRenderer.topLeftLocation(),
                WebCore.LayoutSize(WebCore.snappedIntSize(borderBox.size(), borderBox.location()))
            )
        }

        if let svgModelObjectRenderer = layerRenderer.asRenderSVGModelObject() {
            let frameRect = svgModelObjectRenderer.frameRectEquivalent()
            return WebCore.LayoutRect(
                svgModelObjectRenderer.topLeftLocationEquivalent(),
                WebCore.LayoutSize(WebCore.enclosingIntRect(frameRect).size())
            )
        }

        assertionFailure()
        return WebCore.LayoutRect()
    }

    // Returns true if the position changed. Adds to flags only when recordingFlags is set.
    private func updateLayerPosition(
        _ flags: inout WebCore.RenderLayer.UpdateLayerPositionsFlags,
        recordingFlags: Bool,
        verifyOnly: Bool
    ) -> Bool {
        let layerRenderer = renderer()
        // RenderObject's positioning predicates: the renderer also sees its layout box's.
        let rendererObject: WebCore.RenderObject = layerRenderer
        let layerRect = layerPositionAndIntegralSize()
        var localPoint = layerRect.location()

        var geometryChanged = false
        var sizeChanged = false
        let newSize = WebCore.IntSize(layerRect.width().toInt(), layerRect.height().toInt())
        if !(newSize == m_layerSize) {
            geometryChanged = true
            sizeChanged = true
            m_layerSize = newSize

            layerPositionsAssert(!verifyOnly)

            if recordingFlags && layerRenderer.hasNonVisibleOverflow() {
                flags.add(WebCore.RenderLayer.UpdateLayerPositionsFlags(WebCore.RenderLayer.ContainingClippingLayerChangedSize))
            }

            // Trigger RenderLayerCompositor::requiresCompositingForFrame() which depends on the contentBoxRect size.
            if WebCore.RenderLayerCompositor.hasCompositedWidgetContents(layerRenderer) {
                setNeedsPostLayoutCompositingUpdate()
            }
        }

        if !rendererObject.isOutOfFlowPositioned() {
            // We must adjust our position by walking up the render tree looking for the
            // nearest enclosing object with a layer.
            var ancestor = parentRendererOfRenderObject(layerRenderer)
            while let current = ancestor, !current.hasLayer() {
                if let boxRenderer = current.asRenderBox() {
                    localPoint += boxRenderer.topLeftLocationOffset()
                } else if let svgModelObject = current.asRenderSVGModelObject() {
                    localPoint += svgModelObject.locationOffsetEquivalent()
                }
                ancestor = parentRendererOfRenderObject(current)
            }
        }

        // Subtract our parent's scroll offset.
        let oldBoxScrollingScope = boxScrollingScope().value
        let oldContentsScrollingScope = contentsScrollingScope().value
        if rendererObject.isOutOfFlowPositioned(), let positionedParent = enclosingAncestorForPosition(layerRenderer[.Style].position()) {
            // For positioned layers, we subtract out the enclosing positioned layer's scroll offset.
            let positionedParentRenderer = positionedParent.renderer()
            if positionedParentRenderer.hasNonVisibleOverflow(), let positionedParentScrollableArea = positionedParent.scrollableArea() {
                localPoint -= WebCore.toLayoutSize(WebCore.LayoutPoint(positionedParentScrollableArea.scrollPosition()))
            }
            let positionedParentObject: WebCore.RenderObject = positionedParentRenderer
            if positionedParentObject.isInlineBox() {
                localPoint = locationInInlineBoxContainingBlock(positionedParentRenderer)
            }

            assert(positionedParent.contentsScrollingScope().value != nil)
            m_boxScrollingScope = type(of: m_boxScrollingScope).init(positionedParent.contentsScrollingScope())
        } else if let parentLayer = self.parent() {
            if parentLayer.renderer().hasNonVisibleOverflow(), let parentLayerScrollableArea = parentLayer.scrollableArea() {
                localPoint -= WebCore.toLayoutSize(WebCore.LayoutPoint(parentLayerScrollableArea.scrollPosition()))
            }

            assert(parentLayer.contentsScrollingScope().value != nil)
            m_boxScrollingScope = type(of: m_boxScrollingScope).init(parentLayer.contentsScrollingScope())
        }

        if hasCompositedScrollableOverflow() {
            if contentsScrollingScope().value == nil || contentsScrollingScope().value == boxScrollingScope().value {
                // FIXME: Pass the scope directly once the importer maps uint64_t to UInt64 inside template arguments
                // too (KIT docs/interop-limitations.md, "uint64_t in a template argument"): Markable<ScrollingScope>
                // takes a UInt on LP64 Linux.
                m_contentsScrollingScope = type(of: m_boxScrollingScope).init(
                    numericCast(WebCore.RenderLayer.nextScrollingScope()))
            }
        } else if contentsScrollingScope().value == nil || contentsScrollingScope().value != boxScrollingScope().value {
            m_contentsScrollingScope = type(of: m_boxScrollingScope).init(boxScrollingScope())
        }

        var oldLocationWithoutInFlowOffset = m_topLeft
        oldLocationWithoutInFlowOffset -= m_offsetForPosition
        let newLocationWithoutInFlowOffset = localPoint

        if rendererObject.isInFlowPositioned(), let boxModelObject = layerRenderer.asRenderBoxModelObject() {
            let newOffset = boxModelObject.offsetForInFlowPosition()
            geometryChanged = geometryChanged || !(newOffset == m_offsetForPosition)
            m_offsetForPosition = newOffset
            localPoint.move(m_offsetForPosition)
        }

        geometryChanged = geometryChanged || !(m_topLeft == localPoint)
        layerPositionsAssert(!verifyOnly || !geometryChanged)
        layerPositionsAssert(!verifyOnly || oldBoxScrollingScope == boxScrollingScope().value)
        layerPositionsAssert(!verifyOnly || oldContentsScrollingScope == contentsScrollingScope().value)
        m_topLeft = localPoint

        if geometryChanged && compositor().hasContentCompositingLayers() {
            if isComposited() {
                setNeedsCompositingGeometryUpdate()
            }
            // Scrolling only changed the sticky offset (flags are not recorded on the scroll path).
            let onlyStickyOffsetChanged = !recordingFlags && !sizeChanged
                && oldLocationWithoutInFlowOffset == newLocationWithoutInFlowOffset
                && compositor().canSkipRequirementsTraversalForStickyOffsetChange(self)
            // This layer's footprint can affect the location of a composited descendant (which may be a sibling in z-order),
            // so trigger a descendant walk from the enclosing stacking context.
            if let stackingContext = stackingContextLayer(), !onlyStickyOffsetChanged {
                stackingContext.setDescendantsNeedCompositingRequirementsTraversal()
                stackingContext.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
            }
        }

        return geometryChanged
    }

    // MARK: Repaint target

    private func isEligibleForFullRepaintCheck() -> Bool {
        isSelfPaintingLayer() && !renderer().hasPotentiallyScrollableOverflow() && !renderer().isRenderView()
    }

    @cxx
    @implementation
    public func enclosingCompositingLayerForRepaint(
        _ includeSelf: WebCore.IncludeSelfOrNot
    ) -> WebCore.RenderLayer.EnclosingCompositingLayerStatus {
        var fullRepaintAlreadyScheduled = isEligibleForFullRepaintCheck() && scheduledFullRepaintCoversContentPaintedBy(self)
        if includeSelf == WebCore.IncludeSelf, let target = repaintTarget() {
            return WebCore.RenderLayer.EnclosingCompositingLayerStatus(fullRepaintAlreadyScheduled, WebCore.LayerRef(target))
        }

        var paintingLayer: WebCore.RenderLayer? = isSelfPaintingLayer() ? self : nil
        var current = paintOrderParentLayer()
        while let layer = current {
            if paintingLayer == nil && layer.isSelfPaintingLayer() {
                paintingLayer = layer
            }
            if !fullRepaintAlreadyScheduled, let paintingLayer, layer.isEligibleForFullRepaintCheck() {
                fullRepaintAlreadyScheduled = layer.scheduledFullRepaintCoversContentPaintedBy(paintingLayer)
            }
            if let target = layer.repaintTarget() {
                return WebCore.RenderLayer.EnclosingCompositingLayerStatus(fullRepaintAlreadyScheduled, WebCore.LayerRef(target))
            }
            current = layer.paintOrderParentLayer()
        }

        return WebCore.RenderLayer.EnclosingCompositingLayerStatus()
    }

    // MARK: Repaint rects of the subtree

    @cxx
    @implementation
    public func cachedClippedOverflowRect() -> WebCore.RenderLayer.OptionalLayoutRect {
        if !m_repaintRectsValid {
            return WebCore.RenderLayer.OptionalLayoutRect()
        }
        return WebCore.RenderLayer.OptionalLayoutRect(m_repaintRects.clippedOverflowRect)
    }

    @cxx
    @implementation
    public func computeRepaintRects(_ repaintContainer: WebCore.RenderLayerModelObject?) {
        assert(!m_visibleContentStatusDirty)

        if isSubtreeVisibilityHiddenOrOpacityZero() || !isSelfPaintingLayer() {
            clearRepaintRects()
        } else {
            setRepaintRects(renderer().rectsForRepaintingAfterLayout(repaintContainer, .Yes))
        }

        if isSVGLayer() && renderer().isRenderSVGContainer() {
            updateContainerTransformForRepaintRectsForSVG()
        }

        setRepaintContainer(repaintContainer)
    }

    @cxx
    @implementation
    public func updateRepaintRectsIncludingDescendants(_ update: WebCore.RenderLayer.RepaintRectsUpdate) {
        // FIXME: computeRepaintRects() has to walk up the parent chain for every layer to compute the rects.
        // We should make this more efficient.
        if update == .Recompute {
            computeRepaintRects(renderer().containerForRepaint().renderer.get())
            clearClipRects(WebCore.PaintingClipRects)
        } else {
            clearRepaintRects()
            setRepaintContainer(renderer().containerForRepaint().renderer.get())
        }

        var child = self.firstChild()
        while let current = child {
            current.updateRepaintRectsIncludingDescendants(update)
            child = current.nextSibling()
        }
    }

    // MARK: Style change

    @cxx
    @implementation
    public func styleChanged(_ diff: WebCore.Style.Difference) {
        let layerRenderer = renderer()
        let hasOldStyle = layerRenderer.hasOldStyle()

        updateStackingAfterStyleChange()

        if hasOldStyle {
            compareWithOldStyle(diff, layerRenderer[.OldStyle])
        }

        if let scrollableArea = scrollableArea() {
            scrollableArea.createOrDestroyMarquee()
            if hasOldStyle {
                scrollableArea.updateScrollbarsAfterStyleChange(layerRenderer[.OldStyle])
            } else {
                scrollableArea.updateScrollbarsAfterStyleChangeWithoutOldStyle()
            }
        }
        // Overlay scrollbars can make this layer self-painting so we need
        // to recompute the bit once scrollbars have been updated.
        updateSelfPaintingLayer()

        updateReflectionAfterStyleChange()

        // FIXME: Need to detect a swap from custom to native scrollbars (and vice versa).
        scrollableArea()?.updateAllScrollbarRelatedStyle()

        updateDescendantDependentFlags()
        updateBlendMode()
        if hasOldStyle {
            updateFiltersAfterStyleChange(diff, layerRenderer[.OldStyle])
        } else {
            updateReferenceFiltersAfterStyleChange()
        }
        clearClipRects(WebCore.AllClipRectTypes)

        compositor().layerStyleChanged(diff, self, hasOldStyle)

        updateTransform()
        updateFilterPaintingStrategy()

        if hasOldStyle && layerRenderer[.OldStyle].hasViewportConstrainedPosition() != isViewportConstrained() {
            dirtyAncestorChainHasViewportConstrainedDescendantStatus()
        }
    }

    private func updateStackingAfterStyleChange() {
        _ = setIsNormalFlowOnlyBody(shouldBeNormalFlowOnlyBody())
        _ = setCanBeBackdropRoot(computeCanBeBackdropRoot())

        // Make every SVG layer a stacking context, so a composited child ("anchor") stays in this layer's
        // own paint-order lists rather than escaping to an ancestor's, which the paint-order segmentation
        // relies on. Done here at style time, where mutating the z-order lists is allowed.
        if isSVGLayer() {
            _ = setIsOpportunisticStackingContext(true)
        }

        _ = setIsCSSStackingContext(shouldBeCSSStackingContextBody())
        updateEstablishesBlendingIsolationGroup()

        updateLayerScrollableArea()
    }

    // FIXME: RenderLayer already handles visibility changes through our visibility dirty bits. This logic could
    // likely be folded along with the rest.
    private func compareWithOldStyle(_ diff: WebCore.Style.Difference, _ oldStyle: borrowing WebCore.Style.ComputedStyle) {
        let layerRenderer = renderer()
        let visibilityChanged =
            oldStyle.visibility() != layerRenderer[.Style].visibility() || oldStyle.isForceHidden() != layerRenderer[.Style].isForceHidden()
        if !oldStyle.hasSameUsedZIndex(layerRenderer[.Style])
            || oldStyle.usedContentVisibility() != layerRenderer[.Style].usedContentVisibility() || visibilityChanged
        {
            dirtyStackingContextZOrderLists()
            if isStackingContext() {
                dirtyZOrderLists()
            }
            // Also dirty the parent layer's SVG children list since z-index affects sort order.
            if let parentLayer = self.parent(), parentLayer.isSVGLayer() {
                parentLayer.dirtyChildrenInDOMOrderForSVG()
            }
        }

        if !oldStyle.viewTransitionNameIsNone() != layerRenderer.hasViewTransitionName() {
            updateAlwaysIncludedInZOrderLists()
        }

        // Visibility and scrollability are input to canUseCompositedScrolling().
        if let scrollableArea = scrollableArea() {
            if !oldStyle.hasSameWritingMode(layerRenderer[.Style]) {
                scrollableArea.invalidateScrollCornerRect(WebCore.IntRect())
            }
            if visibilityChanged || oldStyle.isOverflowVisible() != layerRenderer[.Style].isOverflowVisible() {
                scrollableArea.computeHasCompositedScrollableOverflow(
                    diff.result.rawValue <= WebCore.Style.DifferenceResult.RepaintLayer.rawValue ? .Yes : .No
                )
            }
        }

        if oldStyle.isOverflowVisible() != layerRenderer[.Style].isOverflowVisible() {
            setSelfAndDescendantsNeedPositionUpdate()
        }

        if oldStyle.opacityIsTransparent() != layerRenderer[.Style].opacityIsTransparent() {
            setNeedsPositionUpdate()
        }

        if (oldStyle.usedTransformStyle3D() == .Preserve3D) != preserves3D() {
            dirty3DTransformedDescendantStatus()
            setNeedsPostLayoutCompositingUpdateOnAncestors()
        }
    }

    // MARK: Content and background

    @cxx
    @implementation
    public func contentChanged(_ changeType: WebCore.ContentChangeType, _ dirtyRect: WebCore.RenderLayer.OptionalFloatRect) {
        if changeType == .Canvas || changeType == .Video || changeType == .FullScreen || changeType == .Model || changeType == .HDRImage {
            setNeedsPostLayoutCompositingUpdate()
            setNeedsCompositingConfigurationUpdate()
        }

        if let backing = backing() {
            backing.contentChanged(changeType, dirtyRect)
        }
    }

    // MARK: Block selection gaps

    @cxx
    @implementation
    public func addBlockSelectionGapsBounds(_ bounds: WebCore.LayoutRect) {
        var gapsBounds = m_blockSelectionGapsBounds
        gapsBounds.unite(WebCore.enclosingIntRect(bounds))
        m_blockSelectionGapsBounds = gapsBounds
    }

    @cxx
    @implementation
    public func clearBlockSelectionGapsBounds() {
        m_blockSelectionGapsBounds = WebCore.IntRect()
        var child = self.firstChild()
        while let current = child {
            current.clearBlockSelectionGapsBounds()
            child = current.nextSibling()
        }
    }

    @cxx
    @implementation
    public func repaintBlockSelectionGaps() {
        var child = self.firstChild()
        while let current = child {
            current.repaintBlockSelectionGaps()
            child = current.nextSibling()
        }

        if m_blockSelectionGapsBounds.isEmpty() {
            return
        }

        var rect = WebCore.LayoutRect(m_blockSelectionGapsBounds)
        if let scrollableArea = scrollableArea() {
            let scrollPosition = scrollableArea.scrollPosition()
            // Wraps at INT_MIN, as int negation does in practice.
            rect.moveBy(WebCore.LayoutPoint(WebCore.IntPoint(0 &- scrollPosition.x(), 0 &- scrollPosition.y())))
        }
        let layerRenderer = renderer()
        if layerRenderer.hasNonVisibleOverflow() && !usesCompositedScrolling() {
            rect.intersect(
                layerRenderer.asRenderBox()!.overflowClipRect(WebCore.LayoutPoint(), .IgnoreOverlayScrollbarSize, .BlockBackground)
            )
        }
        if layerRenderer.hasClip() {
            rect.intersect(layerRenderer.asRenderBox()!.clipRect(WebCore.LayoutPoint()))
        }
        // m_blockSelectionGapsBounds is in physical coordinates, but repaintRectangle() expects block-start relative coordinates.
        if let box = layerRenderer.asRenderBox() {
            box.physicalToBlockStartRelative(&rect)
        }
        if !rect.isEmpty() {
            layerRenderer.repaintRectangle(rect)
        }
    }
}

extension WebCore.RenderLayer {
    // MARK: Transform

    @cxx
    @implementation
    public func updateTransform() {
        let hasTransform = isTransformed()
        let had3DTransform = has3DTransform()

        let oldTransform = transformValue().value
        if hasTransform != (oldTransform != nil) {
            if hasTransform {
                makeTransform()
            } else {
                resetTransform()
            }

            // Layers with transforms act as clip rects roots, so clear the cached clip rects here.
            clearClipRectsIncludingDescendants(WebCore.AllClipRectTypes)
            setSelfAndDescendantsNeedPositionUpdate()
        }

        if hasTransform {
            var transform = WebCore.TransformationMatrix()
            updateTransformFromStyle(&transform, renderer()[.Style], WebCore.RenderLayer.allTransformOperations())
            setTransformMatrix(transform)
        }

        if had3DTransform != has3DTransform() {
            dirty3DTransformedDescendantStatus()
            // Having a 3D transform affects whether enclosing perspective and preserve-3d layers composite, so trigger an update.
            setNeedsPostLayoutCompositingUpdateOnAncestors()
        }

        let newTransform = transformValue().value
        if let oldTransform, let newTransform, !(oldTransform == newTransform) {
            setSelfAndDescendantsNeedPositionUpdate()
        }

        let layerRenderer = renderer()
        if layerRenderer.mayHaveNonScalingStrokeInSubtree() {
            let oldAffineTransform = oldTransform?.toAffineTransform() ?? WebCore.AffineTransform()
            let newAffineTransform = newTransform?.toAffineTransform() ?? WebCore.AffineTransform()
            layerRenderer.invalidateNonScalingStrokeCachesInSubtreeForSVG(
                WebCore.RenderLayer.OptionalAffineTransform(oldAffineTransform),
                newAffineTransform
            )
        }
    }

    @cxx
    @implementation
    public func currentTransform(_ options: WebCore.RenderLayer.TransformResolverOptions) -> WebCore.TransformationMatrix {
        guard let transform = transformValue().value else {
            return WebCore.TransformationMatrix()
        }

        // m_transform includes transform-origin and is affected by the choice of the transform-box.
        // Therefore we can only use the cached m_transform, if the animation doesn't alter transform-box or excludes transform-origin.

        // Query the animatedStyle() to obtain the current transformation, when accelerated transform animations are running.
        if isRunningAcceleratedTransformRelatedAnimation() || !WebCore.RenderLayer.includesTransformOrigin(options) {
            return animatedStyleTransform(options)
        }

        return transform
    }

    @cxx
    @implementation
    public func currentTransform() -> WebCore.TransformationMatrix {
        currentTransform(WebCore.RenderLayer.allTransformOperations())
    }

    @cxx
    @implementation
    public func perspectiveTransform() -> WebCore.TransformationMatrix {
        let layerRenderer = renderer()
        if !layerRenderer.hasTransformRelatedProperty() {
            return WebCore.TransformationMatrix()
        }

        if layerRenderer[.Style].perspectiveIsNone() {
            return WebCore.TransformationMatrix()
        }

        let transformReferenceBoxRect = WebCore.snapRectToDevicePixelsIfNeeded(
            layerRenderer.transformReferenceBoxRect(layerRenderer[.Style]),
            layerRenderer
        )
        let perspectiveOrigin = WebCore.RenderLayer.computePerspectiveOrigin(layerRenderer[.Style], transformReferenceBoxRect)

        // In the regular case of a non-clipped, non-scrolled GraphicsLayer, all transformations
        // (via CSS 'transform' / 'perspective') are applied with respect to a predefined anchor point,
        // which depends on the chosen CSS 'transform-box' / 'transform-origin' properties.
        //
        // A transformation given by the CSS 'transform' property is applied, by translating
        // to the 'transform origin', applying the transformation, and translating back.
        // When an element specifies a CSS 'perspective' property, the perspective transformation matrix
        // that's computed here is propagated to the GraphicsLayer by calling setChildrenTransform().
        //
        // However the GraphicsLayer platform implementations (e.g. CA on macOS) apply the children transform,
        // defined on the parent, with respect to the anchor point of the parent, when rendering child elements.
        // This is wrong, as the perspective transformation (applied to a child of the element defining the
        // 3d effect), must be independent of the chosen transform-origin (the parents transform origin
        // must not affect its children).
        //
        // To circumvent this, explicitly remove the transform-origin dependency in the perspective matrix.
        let transformOrigin = transformOriginPixelSnappedIfNeeded()

        var transform = WebCore.TransformationMatrix()
        if !transformOrigin.isZero() {
            transform.translateBy(Double(-transformOrigin.x()), Double(-transformOrigin.y()), Double(-transformOrigin.z()))
        }
        transform = WebCore.RenderLayer.applyingPerspective(transform, layerRenderer[.Style], perspectiveOrigin)
        if !transformOrigin.isZero() {
            transform.translateBy(Double(transformOrigin.x()), Double(transformOrigin.y()), Double(transformOrigin.z()))
        }

        return transform
    }

    @cxx
    @implementation
    public func transformOriginPixelSnappedIfNeeded() -> WebCore.FloatPoint3D {
        let layerRenderer = renderer()
        if !layerRenderer.hasTransformRelatedProperty() {
            return WebCore.FloatPoint3D()
        }

        let referenceBoxRect = layerRenderer.transformReferenceBoxRect(layerRenderer[.Style])

        var origin = WebCore.RenderLayer.computeTransformOrigin(layerRenderer[.Style], referenceBoxRect)
        if WebCore.rendererNeedsPixelSnapping(layerRenderer) {
            origin.setXY(WebCore.roundPointToDevicePixels(WebCore.LayoutPoint(origin.xy()), layerRenderer.document().deviceScaleFactor()))
        }
        return origin
    }

    @cxx
    @implementation
    public func perspectiveOrigin() -> WebCore.FloatPoint {
        let layerRenderer = renderer()
        if !layerRenderer.hasTransformRelatedProperty() {
            return WebCore.FloatPoint()
        }

        return WebCore.RenderLayer.evaluatePerspectiveOrigin(
            layerRenderer[.Style],
            layerRenderer.transformReferenceBoxRect(layerRenderer[.Style]).size()
        )
    }

    // MARK: Clip rects cache

    @cxx
    @implementation
    public func clearClipRectsIncludingDescendants(_ typeToClear: WebCore.ClipRectsType) {
        // FIXME: it's not clear how this layer not having clip rects guarantees that no descendants have any.
        if !hasClipRectsCache() {
            return
        }

        clearClipRects(typeToClear)

        var child = self.firstChild()
        while let current = child {
            current.clearClipRectsIncludingDescendants(typeToClear)
            child = current.nextSibling()
        }
    }

    @cxx
    @implementation
    public func clearClipRects(_ typeToClear: WebCore.ClipRectsType) {
        if typeToClear == WebCore.AllClipRectTypes {
            resetClipRectsCache()
        } else if hasClipRectsCache() {
            assert(typeToClear.rawValue < WebCore.NumCachedClipRectsTypes.rawValue)
            clearCachedClipRects(typeToClear)
        }
    }

    // MARK: Compositor

    @cxx
    @implementation
    private func removeSelfFromCompositor() {
        if let parent = parent() {
            compositor().layerWillBeRemoved(parent, self)
        }
        clearBacking(WebCore.UpdateBackingSharingFlagSet(), false)
    }

    // MARK: Opaque background

    @cxx
    @implementation
    public func backgroundIsKnownToBeOpaqueInRect(_ localRect: WebCore.LayoutRect) -> Bool {
        if !isSelfPaintingLayer() && !hasSelfPaintingLayerDescendant() {
            return false
        }

        if paintsWithTransparency(WebCore.RenderLayer.PaintBehaviors()) {
            return false
        }

        let layerRenderer = renderer()
        if layerRenderer.isDocumentElementRenderer() {
            // Normally the document element doens't have a layer.  If it does have a layer, its background propagates to the RenderView
            // so this layer doesn't draw it.
            return false
        }

        // We can't use hasVisibleContent(), because that will be true if our renderer is hidden, but some child
        // is visible and that child doesn't cover the entire rect.
        if layerRenderer.usedVisibility() != .Visible {
            return false
        }

        if shouldPaintWithFilters(WebCore.RenderLayer.PaintBehaviors()) && layerRenderer[.Style].filterHasFilterThatAffectsOpacity() {
            return false
        }

        // FIXME: Handle simple transforms.
        if paintsWithTransform(WebCore.RenderLayer.PaintBehaviors()) {
            return false
        }

        // FIXME: Remove this check.
        // This function should not be called when layer-lists are dirty.
        // It is somehow getting triggered during style update.
        if zOrderListsDirty() || normalFlowListDirty() {
            return false
        }

        // Table painting is special; a table paints its sections.
        if layerRenderer.isTablePart() {
            return false
        }

        // A fieldset with a legend will have an irregular shape, so can't be treated as opaque.
        if layerRenderer.isFieldset() {
            return false
        }

        // FIXME: We currently only check the immediate renderer, which will miss many cases.
        if let box = layerRenderer.asRenderBox(), box.backgroundIsKnownToBeOpaqueInRect(localRect) {
            return true
        }

        // We can't consult child layers if we clip, since they might cover
        // parts of the rect that are clipped out.
        if layerRenderer.hasNonVisibleOverflow() || layerRenderer.hasClipPath() || layerRenderer.hasMask() {
            return false
        }

        return listBackgroundIsKnownToBeOpaque(.Positive, localRect)
            || listBackgroundIsKnownToBeOpaque(.Negative, localRect)
            || listBackgroundIsKnownToBeOpaque(.NormalFlow, localRect)
    }

    private func listBackgroundIsKnownToBeOpaque(_ which: WebCore.PaintOrderList, _ localRect: WebCore.LayoutRect) -> Bool {
        var index = paintOrderListSize(which)
        while index > 0 {
            index -= 1
            let childLayer = paintOrderListLayerAt(which, index)
            if childLayer.isComposited() {
                continue
            }

            if !childLayer.canUseOffsetFromAncestor() {
                continue
            }

            var childLocalRect = localRect
            // LayoutSize's unary minus does not import; subtracting from zero saturates the same way.
            childLocalRect.move(WebCore.LayoutSize() - childLayer.offsetFromAncestor(self, WebCore.RenderLayer.DontAdjustForColumns))

            if childLayer.backgroundIsKnownToBeOpaqueInRect(childLocalRect) {
                return true
            }
        }
        return false
    }

    // MARK: Filters

    @cxx
    @implementation
    public func shouldPaintWithFilters(_ paintBehavior: WebCore.RenderLayer.PaintBehaviors) -> Bool {
        shouldPaintWithFilters(style: renderer()[.Style], paintBehavior)
    }

    @inline(always)
    func shouldPaintWithFilters(style: borrowing WebCore.Style.ComputedStyle, _ paintBehavior: WebCore.RenderLayer.PaintBehaviors) -> Bool {
        if !style.hasFilter() {
            return false
        }

        if renderer().isLegacyRenderSVGRoot() && WebCore.RenderLayer.filterIsReferenceFilter(style) {
            return false
        }

        if filterIsIdentity(style) {
            return false
        }

        if paintBehavior.contains(.FlattenCompositingLayers) {
            return true
        }

        if isComposited() && backing()!.canCompositeFilters() {
            return false
        }

        return true
    }

    @cxx
    @implementation
    public func requiresFullLayerImageForFilters() -> Bool {
        requiresFullLayerImageForFilters(style: renderer()[.Style])
    }

    func requiresFullLayerImageForFilters(style: borrowing WebCore.Style.ComputedStyle) -> Bool {
        if !shouldPaintWithFilters(style: style, WebCore.RenderLayer.PaintBehaviors()) {
            return false
        }

        return style.filterHasFilterThatMovesPixels()
    }

    private func updateReferenceFiltersAfterStyleChange() {
        if renderer()[.Style].filterHasReferenceFilter() {
            updateLayerFiltersReferenceClients()
        } else if !shouldPaintWithFilters(WebCore.RenderLayer.PaintBehaviors()) {
            clearLayerFilters()
        } else {
            removeLayerFiltersReferenceClients()
        }
    }

    private func updateFiltersAfterStyleChange(_ diff: WebCore.Style.Difference, _ oldStyle: borrowing WebCore.Style.ComputedStyle) {
        updateReferenceFiltersAfterStyleChange()

        let filterValueChanged = filterDiffersFromOldStyle(oldStyle)

        if filterValueChanged && requiresFullLayerImageForFilters(style: oldStyle) != requiresFullLayerImageForFilters() {
            updateRepaintRectsIncludingDescendants(.Discard)
        }

        if !hasLayerFilters() || diff.result.rawValue < WebCore.Style.DifferenceResult.RepaintLayer.rawValue {
            return
        }
        if filterValueChanged || currentColorChangeRequiresFilterRepaint(oldStyle) {
            clearLayerFilters()
        }
    }

    // FIXME: This needs a better name.
    @cxx
    @implementation
    public func setFilterBackendNeedsRepaintingInRect(_ rect: WebCore.LayoutRect, _ useFilterOutsets: WebCore.RenderLayer.UseFilterOutsets)
    {
        assert(requiresFullLayerImageForFilters())

        if rect.isEmpty() {
            return
        }

        var rectForRepaint = rect
        if useFilterOutsets == .Add {
            rectForRepaint.expand(WebCore.toLayoutBoxExtent(filterOutsets()))
        }

        expandLayerFiltersDirtySourceRect(rectForRepaint)

        let layerRenderer = renderer()
        guard var parentLayer = enclosingFilterRepaintLayer() else {
            assertionFailure()
            return
        }
        let repaintQuad = WebCore.FloatQuad(floatRect(rectForRepaint))
        var parentLayerRect = WebCore.LayoutRect(
            layerRenderer.localToContainerQuadForSwift(repaintQuad, parentLayer.renderer()).enclosingBoundingBox()
        )

        if parentLayer.isComposited() {
            if !parentLayer.backing()!.paintsIntoWindow() {
                parentLayer.setBackingNeedsRepaintInRect(parentLayerRect, .Clip)
                return
            }
            // If the painting goes to window, redirect the painting to the parent RenderView.
            parentLayer = layerRenderer.view().layer()!
            parentLayerRect = WebCore.LayoutRect(
                layerRenderer.localToContainerQuadForSwift(repaintQuad, parentLayer.renderer()).enclosingBoundingBox()
            )
        }

        if parentLayer.shouldPaintWithFilters(WebCore.RenderLayer.PaintBehaviors()) {
            parentLayer.setFilterBackendNeedsRepaintingInRect(parentLayerRect, .Add)
            return
        }

        if parentLayer.isRenderViewLayer() {
            parentLayer.renderer().view().repaintViewRectangle(parentLayerRect)
            return
        }

        assertionFailure()
    }

    @cxx
    @implementation
    public func updateFilterPaintingStrategy() {
        // RenderLayerFilters is only used to render the filters in software mode,
        // so we always need to run updateFilterPaintingStrategy() after the composited
        // mode might have changed for this layer.
        if !shouldPaintWithFilters(WebCore.RenderLayer.PaintBehaviors()) {
            // Don't delete the whole filter info here, because we might use it
            // for loading SVG reference filter files.
            clearFilters()

            // Early-return only if we *don't* have reference filters.
            // For reference filters, we still want the FilterEffect graph built
            // for us, even if we're composited.
            if !renderer()[.Style].filterHasReferenceFilter() {
                return
            }
        }

        makeLayerFilters()
    }

    @cxx
    @implementation
    public func filterOutsets() -> WebCore.IntOutsets {
        let layerRenderer = renderer()
        if !layerRenderer.hasFilter() {
            return WebCore.IntOutsets()
        }

        if hasLayerFilters() {
            return layerFiltersOutsets()
        }

        return layerRenderer.computeFilterOutsets()
    }

    // MARK: Scrollable area

    @cxx
    @implementation
    public func scrollWidth() -> Int32 {
        if let scrollableArea = scrollableArea() {
            return scrollableArea.scrollWidth()
        }

        let box = renderer().asRenderBox()!
        var overflowRect = box.layoutOverflowRect()
        box.blockStartRelativeToPhysical(&overflowRect)
        return WebCore.roundToInt(overflowRect.maxX() - overflowRect.x())
    }

    @cxx
    @implementation
    public func scrollHeight() -> Int32 {
        if let scrollableArea = scrollableArea() {
            return scrollableArea.scrollHeight()
        }

        let box = renderer().asRenderBox()!
        var overflowRect = box.layoutOverflowRect()
        box.blockStartRelativeToPhysical(&overflowRect)
        return WebCore.roundToInt(overflowRect.maxY() - overflowRect.y())
    }

    @cxx
    @implementation
    public func offsetFromResizeCorner(_ localPoint: WebCore.IntPoint) -> WebCore.IntSize {
        let resizerRect = overflowControlsRects().resizer
        let resizeCorner = renderer().shouldPlaceVerticalScrollbarOnLeft() ? resizerRect.minXMaxYCorner() : resizerRect.maxXMaxYCorner()
        return localPoint - resizeCorner
    }

    @cxx
    @implementation
    public func minimumSizeForResizing(_ zoomFactor: Float) -> WebCore.LayoutSize {
        // Use the resizer size as the strict minimum size
        let resizerRect = overflowControlsRects().resizer
        let containingBlockSize = renderer().containingBlock()!.borderBoundingBox().size()
        var minWidth = renderer()[.Style].evaluatedMinWidth(containingBlockSize.width())
        var minHeight = renderer()[.Style].evaluatedMinHeight(containingBlockSize.height())
        minWidth = maxLayoutUnit(WebCore.LayoutUnit(Double(minWidth.toFloat() / zoomFactor)), WebCore.LayoutUnit(resizerRect.width()))
        minHeight = maxLayoutUnit(WebCore.LayoutUnit(Double(minHeight.toFloat() / zoomFactor)), WebCore.LayoutUnit(resizerRect.height()))
        return WebCore.LayoutSize(minWidth, minHeight)
    }

    @cxx
    @implementation
    public func canResize() -> Bool {
        // We need a special case for <iframe> because they never have
        // hasNonVisibleOverflow(). However, they do "implicitly" clip their contents, so
        // we want to allow resizing them also.
        (renderer().hasNonVisibleOverflow() || renderer().isRenderIFrame()) && renderer()[.Style].hasResize()
    }

    @cxx
    @implementation
    public func isPointInResizeControl(_ localPoint: WebCore.IntPoint) -> Bool {
        if !canResize() {
            return false
        }

        return overflowControlsRects().resizer.contains(localPoint)
    }

    @cxx
    @implementation
    public func updateScrollbarSteps() {
        scrollableArea()?.updateScrollbarSteps()
    }

    @cxx
    @implementation
    public func canUseCompositedScrolling() -> Bool {
        scrollableArea()?.canUseCompositedScrolling() ?? false
    }

    @cxx
    @implementation
    public func hasCompositedScrollableOverflow() -> Bool {
        scrollableArea()?.hasCompositedScrollableOverflow() ?? false
    }

    @cxx
    @implementation
    public func computeHasCompositedScrollableOverflow(_ layoutUpToDate: WebCore.LayoutUpToDate) {
        scrollableArea()?.computeHasCompositedScrollableOverflow(layoutUpToDate)
    }

    // RenderLayerScrollableArea reads this private flag.
    fileprivate func insideSVGForeignObject() -> Bool {
        isInsideSVGForeignObject()
    }

    @cxx
    @implementation
    public func usesCompositedScrolling() -> Bool {
        scrollableArea()?.usesCompositedScrolling() ?? false
    }

    @cxx
    @implementation
    public func visibleSize() -> WebCore.IntSize {
        guard let box = renderBox() else {
            return WebCore.IntSize()
        }

        return WebCore.IntSize(WebCore.roundToInt(box.paddingBoxWidth()), WebCore.roundToInt(box.paddingBoxHeight()))
    }

    @cxx
    @implementation
    public func overflowControlsRects() -> WebCore.RenderLayer.OverflowControlRects {
        if let scrollableArea = scrollableArea() {
            return scrollableArea.overflowControlsRects()
        }

        let renderBox = renderer().asRenderBox()!
        // Scrollbars sit inside the border box.
        let overflowControlsPositioningRect = WebCore.snappedIntRect(renderBox.paddingBoxRectIncludingScrollbar())

        let placeVerticalScrollbarOnTheLeft = renderBox.shouldPlaceVerticalScrollbarOnLeft()
        let haveResizer = renderer()[.Style].hasResize() && renderer()[.Style].pseudoElementType().value == nil

        var result = WebCore.RenderLayer.OverflowControlRects()

        if haveResizer {
            let scrollbarThickness = WebCore.RenderLayerScrollableArea.themeScrollbarThickness(.Auto)
            result.resizer = overflowControlsCornerRect(
                overflowControlsPositioningRect,
                WebCore.IntSize(scrollbarThickness, scrollbarThickness),
                placeVerticalScrollbarOnTheLeft
            )
        }

        return result
    }

    @cxx
    @implementation
    public func updateLayerScrollableArea() {
        let hasScrollableArea = scrollableArea() != nil
        let needsScrollableArea = renderer().asRenderBox()?.requiresLayerWithScrollableArea() ?? false

        if needsScrollableArea == hasScrollableArea {
            return
        }

        if needsScrollableArea {
            _ = ensureLayerScrollableArea()
        } else {
            clearLayerScrollableArea()
            if renderer().settings().asyncOverflowScrollingEnabled() {
                setNeedsCompositingConfigurationUpdate()
            }
        }

        didAddOrRemoveScrollbars()
    }
}

// The root layer, type and options that clip rects are computed for.
struct RenderLayerClipRectsContext {
    var rootLayer: WebCore.RenderLayer?
    var clipRectsType: WebCore.ClipRectsType
    var options: WebCore.RenderLayer.ClipRectsOptions

    init(
        _ rootLayer: WebCore.RenderLayer?,
        _ clipRectsType: WebCore.ClipRectsType,
        _ options: WebCore.RenderLayer.ClipRectsOptions = WebCore.RenderLayer.clipRectDefaultOptionsForSwift()
    ) {
        self.rootLayer = rootLayer
        self.clipRectsType = clipRectsType
        self.options = options
        if clipRectsType == WebCore.RootRelativeClipRects {
            self.options.add(WebCore.RenderLayer.ClipRectsOptions(.IncludeOverlayScrollbarSize))
        }
    }

    // A context that C++ built, with its options as they are.
    init(passed rootLayer: WebCore.RenderLayer?, _ clipRectsType: WebCore.ClipRectsType, _ options: WebCore.RenderLayer.ClipRectsOptions) {
        self.rootLayer = rootLayer
        self.clipRectsType = clipRectsType
        self.options = options
    }

    var respectOverflowClip: Bool { options.contains(.RespectOverflowClip) }

    var overlayScrollbarSizeRelevancy: WebCore.OverlayScrollbarSizeRelevancy {
        options.contains(.IncludeOverlayScrollbarSize) ? .IncludeOverlayScrollbarSize : .IgnoreOverlayScrollbarSize
    }

    func adding(_ option: WebCore.RenderLayer.ClipRectsOption) -> RenderLayerClipRectsContext {
        var context = self
        context.options.add(WebCore.RenderLayer.ClipRectsOptions(option))
        return context
    }
}

private func assignClipRects(_ clipRects: WebCore.ClipRects, from other: WebCore.ClipRects) {
    clipRects.setOverflowClipRect(other.overflowClipRect())
    clipRects.setFixedClipRect(other.fixedClipRect())
    clipRects.setPosClipRect(other.posClipRect())
    clipRects.setFixed(other.fixed())
}

private func clipRectsAreEqual(_ a: WebCore.ClipRects, _ b: WebCore.ClipRects) -> Bool {
    a.overflowClipRect() == b.overflowClipRect()
        && a.fixedClipRect() == b.fixedClipRect()
        && a.posClipRect() == b.posClipRect()
        && a.fixed() == b.fixed()
}

private func backgroundClipRectForPosition(_ parentRects: WebCore.ClipRects, _ position: WebCore.PositionType) -> WebCore.ClipRect {
    if position == .Fixed {
        return parentRects.fixedClipRect()
    }

    if position == .Absolute {
        return parentRects.posClipRect()
    }

    return parentRects.overflowClipRect()
}

// LayoutRect's conversion to FloatRect does not import; this is its body.
private func floatRect(_ rect: WebCore.LayoutRect) -> WebCore.FloatRect {
    WebCore.FloatRect(rect.x().toFloat(), rect.y().toFloat(), rect.width().toFloat(), rect.height().toFloat())
}

private func computeLocalExposeRect(_ absoluteRect: WebCore.LayoutRect, _ box: WebCore.RenderBox) -> WebCore.LayoutRect {
    WebCore.LayoutRect(box.absoluteToLocalQuadForSwift(WebCore.FloatQuad(floatRect(absoluteRect))).boundingBox())
}

// `value *= factor` on a LayoutUnit: the product in float, converted back.
private func scaledLayoutUnit(_ value: WebCore.LayoutUnit, _ factor: Float) -> WebCore.LayoutUnit {
    WebCore.LayoutUnit(Double(value.toFloat() * factor))
}

// std::max of two LayoutUnits: the first unless it is less than the second.
private func maxLayoutUnit(_ a: WebCore.LayoutUnit, _ b: WebCore.LayoutUnit) -> WebCore.LayoutUnit {
    a.rawValue() < b.rawValue() ? b : a
}

private func negated(_ size: WebCore.LayoutSize) -> WebCore.LayoutSize {
    // LayoutSize's unary minus does not import; subtracting from zero saturates the same way.
    WebCore.LayoutSize() - size
}

extension WebCore.RenderLayer {
    // MARK: Clip rects

    // Computes, caches and returns clip rects computed with the given layer as the root.
    func updateClipRects(_ clipRectsContext: RenderLayerClipRectsContext) -> WebCore.ClipRects {
        let clipRectsType = clipRectsContext.clipRectsType
        assert(clipRectsType.rawValue < WebCore.NumCachedClipRectsTypes.rawValue)
        assert(!clipRectsContext.options.contains(.Temporary))
        assert(!clipRectsContext.options.contains(.OutsideFilter))
        if let clipRects = cachedClipRects(clipRectsType, clipRectsContext.respectOverflowClip, clipRectsContext.rootLayer) {
            return clipRects // We have the correct cached value.
        }

        ensureClipRectsCache(clipRectsType, clipRectsContext.rootLayer)
        assert(
            (clipRectsContext.overlayScrollbarSizeRelevancy == .IncludeOverlayScrollbarSize)
                == (clipRectsType == WebCore.RootRelativeClipRects)
        )

        let parentClipRects = self.parentClipRects(clipRectsContext)

        let clipRects = WebCore.ClipRects.createForSwift()
        calculateClipRects(clipRectsContext, clipRects)

        if let parentClipRects, clipRectsAreEqual(parentClipRects, clipRects) {
            setCachedClipRects(clipRectsType, clipRectsContext.respectOverflowClip, parentClipRects)
            return parentClipRects
        }

        setCachedClipRects(clipRectsType, clipRectsContext.respectOverflowClip, clipRects)
        return clipRects
    }

    @cxx
    @implementation
    public func clipCrossesPaintingBoundary(_ clipRectsType: WebCore.ClipRectsType) -> Bool {
        clipCrossesPaintingBoundaryBody(clipRectsType)
    }

    // clipCrossesPaintingBoundary(), inlined into its Swift callers.
    @inline(always)
    func clipCrossesPaintingBoundaryBody(_ clipRectsType: WebCore.ClipRectsType) -> Bool {
        let parent = parent()!
        if !isSameRenderLayer(
            parent.enclosingPaginationLayer(WebCore.RenderLayer.IncludeCompositedPaginatedLayers),
            enclosingPaginationLayer(WebCore.RenderLayer.IncludeCompositedPaginatedLayers)
        ) {
            return true
        }

        // Root-relative clip rects don't depend on the repaint target.
        if clipRectsType == WebCore.RootRelativeClipRects {
            return false
        }

        // In this case, enclosingRepaintTargetLayer() starts at parent() and finds the same target as
        // parent()->enclosingRepaintTargetLayer().
        if isSameRenderLayer(paintOrderParentLayer(), parent) && repaintTarget() == nil {
            return false
        }

        return !isSameRenderLayer(parent.enclosingRepaintTargetLayer(), enclosingRepaintTargetLayer())
    }

    @cxx
    @implementation
    public func calculateClipRects(
        _ rootLayer: WebCore.RenderLayer?,
        _ clipRectsType: WebCore.ClipRectsType,
        _ options: WebCore.RenderLayer.ClipRectsOptions,
        _ clipRects: WebCore.ClipRects
    ) {
        calculateClipRects(RenderLayerClipRectsContext(passed: rootLayer, clipRectsType, options), clipRects)
    }

    func calculateClipRects(_ clipRectsContext: RenderLayerClipRectsContext, _ clipRects: WebCore.ClipRects) {
        if parent() == nil {
            // The root layer's clip rect is always infinite.
            clipRects.reset()
            return
        }

        if let parentClipRects = self.parentClipRects(clipRectsContext) {
            assignClipRects(clipRects, from: parentClipRects)
        } else {
            clipRects.reset()
        }

        let layerRenderer = renderer()
        // A fixed object is essentially the root of its containing block hierarchy, so when
        // we encounter such an object, we reset our clip rects to the fixedClipRect.
        if layerRenderer.isFixedPositioned() {
            clipRects.setPosClipRect(clipRects.fixedClipRect())
            clipRects.setOverflowClipRect(clipRects.fixedClipRect())
            clipRects.setFixed(true)
        } else if (layerRenderer as WebCore.RenderObject).isInFlowPositioned() {
            clipRects.setPosClipRect(clipRects.overflowClipRect())
        } else if rendererShouldUsePositionedClipping() {
            clipRects.setOverflowClipRect(clipRects.posClipRect())
        }

        // Update the clip rects that will be passed to child layers.
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
        let establishesClip =
            layerRenderer.hasClipOrNonVisibleOverflow()
            && (clipRectsContext.respectOverflowClip || !isSameRenderLayer(self, clipRectsContext.rootLayer))
        #else
        let establishesClip =
            (layerRenderer.hasNonVisibleOverflow()
                && (clipRectsContext.respectOverflowClip || !isSameRenderLayer(self, clipRectsContext.rootLayer)))
            || layerRenderer.hasClip()
        #endif
        if establishesClip {
            // This layer establishes a clip of some kind.
            let rootLayer = clipRectsContext.rootLayer!

            // FIXME: Transforming a clip doesn't make a whole lot of sense, since it we have to round out to the
            // bounding box of the transformed quad.
            // It would be better for callers to transform rects into the coordinate space of the nearest clipped layer, apply
            // the clip in local space, and then repeat until the required coordinate space is reached.
            let needsTransform =
                clipRectsContext.clipRectsType == WebCore.AbsoluteClipRects
                ? m_hasTransformedAncestor || !canUseOffsetFromAncestor() : !canUseOffsetFromAncestor(rootLayer)

            var offset = WebCore.LayoutPoint()
            if !needsTransform {
                offset = WebCore.toLayoutPoint(offsetFromAncestor(rootLayer, WebCore.RenderLayer.AdjustForColumns))
            }

            if clipRects.fixed() && WebCore.RenderObject.isSameRenderer(rootLayer.renderer(), layerRenderer.view()) {
                offset = offset - WebCore.toLayoutSize(layerRenderer.view().frameViewScrollPositionForFixedPositionForSwift())
            }

            if layerRenderer.hasNonVisibleOverflow() {
                var newOverflowClip = WebCore.ClipRect(
                    rendererOverflowClipRectForChildLayers(WebCore.LayoutPoint(), clipRectsContext.overlayScrollbarSizeRelevancy)
                )

                if !newOverflowClip.isInfinite() {
                    if needsTransform {
                        newOverflowClip = WebCore.ClipRect(
                            WebCore.LayoutRect(
                                layerRenderer.localToContainerQuadForSwift(
                                    WebCore.FloatQuad(floatRect(newOverflowClip.rectValue())),
                                    rootLayer.renderer()
                                )
                                .boundingBox()
                            )
                        )
                    }
                    newOverflowClip.moveBy(offset)
                    newOverflowClip.setAffectedByRadius(layerRenderer[.Style].hasBorderRadius())
                    clipRects.setOverflowClipRect(WebCore.intersection(newOverflowClip, clipRects.overflowClipRect()))
                    if layerRenderer.canContainAbsolutelyPositionedObjectsForSwift() {
                        clipRects.setPosClipRect(WebCore.intersection(newOverflowClip, clipRects.posClipRect()))
                    }
                    if layerRenderer.canContainFixedPositionObjectsForSwift() {
                        clipRects.setFixedClipRect(WebCore.intersection(newOverflowClip, clipRects.fixedClipRect()))
                    }
                }
            }
            if layerRenderer.hasClip() {
                if let box = layerRenderer.asRenderBox() {
                    var newPosClip = box.clipRect(WebCore.LayoutPoint())
                    if needsTransform {
                        newPosClip = WebCore.LayoutRect(
                            layerRenderer.localToContainerQuadForSwift(WebCore.FloatQuad(floatRect(newPosClip)), rootLayer.renderer())
                                .boundingBox()
                        )
                    }
                    newPosClip.moveBy(offset)
                    let newPosClipRect = WebCore.ClipRect(newPosClip)
                    clipRects.setPosClipRect(WebCore.intersection(newPosClipRect, clipRects.posClipRect()))
                    clipRects.setOverflowClipRect(WebCore.intersection(newPosClipRect, clipRects.overflowClipRect()))
                    clipRects.setFixedClipRect(WebCore.intersection(newPosClipRect, clipRects.fixedClipRect()))
                }
            }
        } else if layerRenderer.hasNonVisibleOverflow() && transformValue().value != nil && layerRenderer[.Style].hasBorderRadius() {
            clipRects.setOverflowClipRectAffectedByRadius()
        }

        // A float painted as its own root layer (e.g. through its transform) is already clipped as a whole (see backgroundClipRect).
        if let box = layerRenderer.asRenderBox(), !isSameRenderLayer(clipRectsContext.rootLayer, self) {
            if let blockEndClipRect = box.blockEndClipRectForSwift(clipRectsContext.rootLayer!.renderer()).value {
                let blockEndClip = WebCore.ClipRect(blockEndClipRect)
                clipRects.setPosClipRect(WebCore.intersection(blockEndClip, clipRects.posClipRect()))
                clipRects.setOverflowClipRect(WebCore.intersection(blockEndClip, clipRects.overflowClipRect()))
                clipRects.setFixedClipRect(WebCore.intersection(blockEndClip, clipRects.fixedClipRect()))
            }
        }
    }

    func parentClipRects(_ clipRectsContext: RenderLayerClipRectsContext) -> WebCore.ClipRects? {
        guard let containerLayer = parent(), !isSameRenderLayer(clipRectsContext.rootLayer, self) else {
            return nil
        }

        if clipRectsContext.clipRectsType == WebCore.PaintingClipRects && m_suppressAncestorClippingInsideFilter
            && !clipRectsContext.options.contains(.OutsideFilter)
        {
            return nil
        }

        func temporaryParentClipRects(_ clipContext: RenderLayerClipRectsContext) -> WebCore.ClipRects {
            let parentClipRects = WebCore.ClipRects.createForSwift()
            containerLayer.calculateClipRects(clipContext, parentClipRects)
            return parentClipRects
        }

        if clipRectsContext.options.contains(.Temporary) || clipRectsContext.options.contains(.OutsideFilter) {
            return temporaryParentClipRects(clipRectsContext)
        }

        if clipRectsContext.clipRectsType != WebCore.AbsoluteClipRects && clipCrossesPaintingBoundaryBody(clipRectsContext.clipRectsType) {
            return temporaryParentClipRects(clipRectsContext.adding(.Temporary))
        }

        return containerLayer.updateClipRects(clipRectsContext)
    }

    @cxx
    @implementation
    public func backgroundClipRect(
        _ rootLayer: WebCore.RenderLayer?,
        _ clipRectsType: WebCore.ClipRectsType,
        _ options: WebCore.RenderLayer.ClipRectsOptions
    ) -> WebCore.ClipRect {
        backgroundClipRect(RenderLayerClipRectsContext(passed: rootLayer, clipRectsType, options))
    }

    func backgroundClipRect(_ clipRectsContext: RenderLayerClipRectsContext) -> WebCore.ClipRect {
        assert(parent() != nil)
        var backgroundClipRect = WebCore.ClipRect()
        guard let parentRects = parentClipRects(clipRectsContext) else {
            backgroundClipRect.reset()
            return backgroundClipRect
        }
        let layerRenderer = renderer()
        backgroundClipRect = backgroundClipRectForPosition(parentRects, layerRenderer[.Style].position())
        if let box = layerRenderer.asRenderBox() {
            if let blockEndClipRect = box.blockEndClipRectForSwift(clipRectsContext.rootLayer!.renderer()).value {
                backgroundClipRect.intersect(blockEndClipRect)
            }
        }
        // Note: infinite clipRects should not be scrolled here, otherwise they will accidentally no longer be considered infinite.
        if parentRects.fixed() {
            let view = layerRenderer.view()
            if WebCore.RenderObject.isSameRenderer(clipRectsContext.rootLayer!.renderer(), view) && !backgroundClipRect.isInfinite() {
                backgroundClipRect.moveBy(view.frameViewScrollPositionForFixedPositionForSwift())
            }
        }

        return backgroundClipRect
    }

    func calculateBackgroundClipRect(
        _ clipRectsContext: RenderLayerClipRectsContext,
        _ offsetFromRoot: WebCore.LayoutSize
    ) -> WebCore.ClipRect {
        var backgroundClipRect = WebCore.ClipRect(WebCore.LayoutRect.infiniteRect())

        if !isSameRenderLayer(clipRectsContext.rootLayer, self) && parent() != nil {
            backgroundClipRect = self.backgroundClipRect(clipRectsContext)
        }

        let shouldApplyClip =
            clipRectsContext.clipRectsType != WebCore.PaintingClipRects
            || !m_suppressAncestorClippingInsideFilter
            || clipRectsContext.options.contains(.OutsideFilter)

        if shouldApplyClip && renderer().hasClip() {
            if let box = renderer().asRenderBox() {
                // Clip applies to *us* as well, so update the damageRect.
                let newPosClip = box.clipRect(WebCore.toLayoutPoint(offsetFromRoot))
                backgroundClipRect.intersect(newPosClip)
            }
        }

        return backgroundClipRect
    }

    func calculateBackgroundRect(_ clipRectsContext: RenderLayerClipRectsContext, _ offsetFromRoot: WebCore.LayoutSize) -> WebCore.ClipRect
    {
        calculateBackgroundRect(clipRectsContext, offsetFromRoot, calculateBackgroundClipRect(clipRectsContext, offsetFromRoot))
    }

    // Most layers establish no clip, so that is tested before the rest of the calculation.
    @inline(always)
    func calculateBackgroundRect(
        _ clipRectsContext: RenderLayerClipRectsContext,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ backgroundClipRect: WebCore.ClipRect
    ) -> WebCore.ClipRect {
        if clipRectsContext.options.contains(.OutsideFilter) || !renderer().hasClipOrNonVisibleOverflow() {
            return backgroundClipRect
        }

        if isSameRenderLayer(clipRectsContext.rootLayer, self) && !clipRectsContext.respectOverflowClip {
            return backgroundClipRect
        }

        return calculateBackgroundRectForClip(offsetFromRoot, backgroundClipRect)
    }

    @inline(never)
    func calculateBackgroundRectForClip(_ offsetFromRoot: WebCore.LayoutSize, _ backgroundClipRect: WebCore.ClipRect) -> WebCore.ClipRect {
        var backgroundRect = backgroundClipRect
        let layerRenderer = renderer()

        // If we establish a clip at all, then make sure our background rect is intersected with our layer's bounds including our visual
        // overflow,
        // since any visual overflow like box-shadow or border-outset is not clipped by overflow:auto/hidden.
        if rendererHasVisualOverflow() {
            // FIXME: Does not do the right thing with CSS regions yet, since we don't yet factor in the
            // individual region boxes as overflow.
            var layerBoundsWithVisualOverflow = rendererVisualOverflowRect()
            if let box = layerRenderer.asRenderBox() {
                // Layers are in physical coordinates, so the overflow has to be converted.
                box.blockStartRelativeToPhysical(&layerBoundsWithVisualOverflow)
            }

            layerBoundsWithVisualOverflow.move(offsetFromRoot)
            backgroundRect.intersect(layerBoundsWithVisualOverflow)
            return backgroundRect
        }

        var bounds = rendererBorderBoxRect()

        // Shift the bounds to be for our region only.
        bounds.move(offsetFromRoot)
        backgroundRect.intersect(bounds)
        return backgroundRect
    }

    func calculateForegroundRect(_ clipRectsContext: RenderLayerClipRectsContext, _ offsetFromRoot: WebCore.LayoutSize) -> WebCore.ClipRect
    {
        calculateForegroundRect(clipRectsContext, offsetFromRoot, calculateBackgroundClipRect(clipRectsContext, offsetFromRoot))
    }

    // Most layers have no overflow clip, so that is tested before the rest of the calculation.
    @inline(always)
    func calculateForegroundRect(
        _ clipRectsContext: RenderLayerClipRectsContext,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ backgroundClipRect: WebCore.ClipRect
    ) -> WebCore.ClipRect {
        if clipRectsContext.options.contains(.OutsideFilter) || !renderer().hasNonVisibleOverflow() {
            return backgroundClipRect
        }

        return calculateForegroundRectForOverflowClip(clipRectsContext, offsetFromRoot, backgroundClipRect)
    }

    @inline(never)
    func calculateForegroundRectForOverflowClip(
        _ clipRectsContext: RenderLayerClipRectsContext,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ backgroundClipRect: WebCore.ClipRect
    ) -> WebCore.ClipRect {
        var foregroundRect = backgroundClipRect
        let layerRenderer = renderer()

        // This layer establishes a clip of some kind.
        if !isSameRenderLayer(self, clipRectsContext.rootLayer) || clipRectsContext.respectOverflowClip {
            let overflowClipRect = rendererOverflowClipRectForPainting(
                WebCore.toLayoutPoint(offsetFromRoot),
                clipRectsContext.overlayScrollbarSizeRelevancy
            )
            if !overflowClipRect.isInfinite() {
                foregroundRect.intersect(overflowClipRect)
                foregroundRect.setAffectedByRadius(true)
            }
            return foregroundRect
        }

        if transformValue().value != nil && layerRenderer[.Style].hasBorderRadius() {
            foregroundRect.setAffectedByRadius(true)
        }

        return foregroundRect
    }

    @cxx
    @implementation
    public func calculateRects(
        _ rootLayer: WebCore.RenderLayer?,
        _ clipRectsType: WebCore.ClipRectsType,
        _ options: WebCore.RenderLayer.ClipRectsOptions,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ paintDirtyRect: WebCore.LayoutRect
    ) -> WebCore.LayerFragment.Rects {
        calculateRects(RenderLayerClipRectsContext(passed: rootLayer, clipRectsType, options), offsetFromRoot, paintDirtyRect)
    }

    @inline(always)
    func calculateRects(
        _ clipRectsContext: RenderLayerClipRectsContext,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ paintDirtyRect: WebCore.LayoutRect = WebCore.LayoutRect.infiniteRect()
    ) -> WebCore.LayerFragment.Rects {
        let layerBounds = WebCore.LayoutRect(WebCore.toLayoutPoint(offsetFromRoot), rect().size())
        // Both rects start from the same ancestor-derived clip, which is costly to compute, so compute it once.
        let backgroundClipRect = calculateBackgroundClipRect(clipRectsContext, offsetFromRoot)
        let backgroundRect = calculateBackgroundRect(clipRectsContext, offsetFromRoot, backgroundClipRect)
        let foregroundRect = calculateForegroundRect(clipRectsContext, offsetFromRoot, backgroundClipRect)
        return WebCore.LayerFragment.Rects(
            layerBounds,
            paintDirtyRect,
            backgroundRect,
            foregroundRect,
            WebCore.RenderLayer.OptionalLayoutRect()
        )
    }

    @cxx
    @implementation
    public func childrenClipRect() -> WebCore.LayoutRect {
        // FIXME: border-radius not accounted for.
        // FIXME: Regions not accounted for.
        let clippingRootLayer = clippingRootForPainting()
        let clipRectsContext = RenderLayerClipRectsContext(
            clippingRootLayer,
            WebCore.PaintingClipRects,
            WebCore.RenderLayer.ClipRectsOptions(.Temporary)
        )
        // Need to use temporary clip rects, because the value of 'dontClipToOverflow' may be different from the painting path
        // (<rdar://problem/11844909>).
        let foregroundRect = calculateForegroundRect(
            clipRectsContext,
            offsetFromAncestor(clipRectsContext.rootLayer, WebCore.RenderLayer.DontAdjustForColumns)
        )
        let view = renderer().view()
        if foregroundRect.rectValue().isInfinite() {
            return WebCore.LayoutRect(view.unscaledDocumentRect())
        }

        let absoluteClippingRect = clippingRootLayer!.renderer()
            .localToAbsoluteQuadForSwift(WebCore.FloatQuad(floatRect(foregroundRect.rectValue()))).enclosingBoundingBox()
        return WebCore.LayoutRect(WebCore.intersection(absoluteClippingRect, view.unscaledDocumentRect()))
    }

    func clipRectRelativeToAncestor(
        _ ancestor: WebCore.RenderLayer?,
        _ offsetFromAncestor: WebCore.LayoutSize,
        _ constrainingRect: WebCore.LayoutRect,
        _ temporaryClipRects: Bool = false
    ) -> WebCore.LayoutRect {
        var options = WebCore.RenderLayer.clipRectDefaultOptionsForSwift()
        if let paginationLayer = enclosingPaginationLayerInStore(), !isSameRenderLayer(paginationLayer, ancestor) {
            options.add(WebCore.RenderLayer.ClipRectsOptions(.Temporary))
        } else if temporaryClipRects {
            options.add(WebCore.RenderLayer.ClipRectsOptions(.Temporary))
        }
        let clipRectsContext = RenderLayerClipRectsContext(ancestor, WebCore.PaintingClipRects, options)
        let backgroundRect = calculateBackgroundRect(clipRectsContext, offsetFromAncestor)
        return WebCore.intersection(backgroundRect.rectValue(), constrainingRect)
    }

    @cxx
    @implementation
    public func selfClipRect() -> WebCore.LayoutRect {
        // FIXME: border-radius not accounted for.
        // FIXME: Regions not accounted for.
        let clippingRootLayer = clippingRootForPainting()
        let clipRect = clipRectRelativeToAncestor(
            clippingRootLayer,
            offsetFromAncestor(clippingRootLayer, WebCore.RenderLayer.DontAdjustForColumns),
            WebCore.LayoutRect(renderer().view().documentRect())
        )
        return WebCore.LayoutRect(
            clippingRootLayer!.renderer().localToAbsoluteQuadForSwift(WebCore.FloatQuad(floatRect(clipRect))).enclosingBoundingBox()
        )
    }

    // MARK: Bounds

    @cxx
    @implementation
    public func intersectsDamageRect(
        _ layerBounds: WebCore.LayoutRect,
        _ damageRect: WebCore.LayoutRect,
        _ rootLayer: WebCore.RenderLayer?,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ cachedBoundingBox: WebCore.RenderLayer.OptionalLayoutRect
    ) -> Bool {
        let layerRenderer = renderer()
        // Always examine the canvas and the root.
        // FIXME: Could eliminate the isDocumentElementRenderer() check if we fix background painting so that the RenderView
        // paints the root's background.
        if isRenderViewLayer() || layerRenderer.isDocumentElementRenderer() {
            return true
        }

        if damageRect.isInfinite() {
            return true
        }

        if damageRect.isEmpty() {
            return false
        }

        // If we aren't an inline flow, and our layer bounds do intersect the damage rect, then we can return true.
        if !(layerRenderer as WebCore.RenderObject).isInlineBox() && layerBounds.intersects(damageRect) {
            return true
        }

        // Otherwise we need to compute the bounding box of this single layer and see if it intersects
        // the damage rect. It's possible the fragment computed the bounding box already, in which case we
        // can use the cached value.
        if let cachedBoundingBox = cachedBoundingBox.value {
            return cachedBoundingBox.intersects(damageRect)
        }

        return boundingBox(rootLayer, offsetFromRoot, WebCore.RenderLayer.CalculateLayerBoundsFlags()).intersects(damageRect)
    }

    @cxx
    @implementation
    public func boundingBox(
        _ ancestorLayer: WebCore.RenderLayer?,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ flags: WebCore.RenderLayer.CalculateLayerBoundsFlags
    ) -> WebCore.LayoutRect {
        var result = localBoundingBox(flags)
        let layerRenderer = renderer()
        if layerRenderer.view().frameViewHasFlippedBlockRenderersForSwift() {
            if let box = layerRenderer.asRenderBox() {
                box.blockStartRelativeToPhysical(&result)
            } else {
                layerRenderer.containingBlock()!.blockStartRelativeToPhysical(&result)
            }
        }

        var inclusionMode = WebCore.RenderLayer.ExcludeCompositedPaginatedLayers
        if flags.contains(WebCore.RenderLayer.UseFragmentBoxesIncludingCompositing) {
            inclusionMode = WebCore.RenderLayer.IncludeCompositedPaginatedLayers
        }

        var paginationLayer: WebCore.RenderLayer? = nil
        if flags.contains(WebCore.RenderLayer.UseFragmentBoxesExcludingCompositing)
            || flags.contains(WebCore.RenderLayer.UseFragmentBoxesIncludingCompositing)
        {
            paginationLayer = enclosingPaginationLayerInSubtree(ancestorLayer, inclusionMode)
        }

        var childLayer = self
        let isPaginated = paginationLayer != nil
        while let currentPaginationLayer = paginationLayer {
            // Split our box up into the actual fragment boxes that render in the columns/pages and unite those together to
            // get our true bounding box.
            result.move(childLayer.offsetFromAncestor(currentPaginationLayer, WebCore.RenderLayer.DontAdjustForColumns))

            result = currentPaginationLayer.renderer().fragmentsBoundingBoxForSwift(result)

            childLayer = currentPaginationLayer
            paginationLayer = currentPaginationLayer.parent()!.enclosingPaginationLayerInSubtree(ancestorLayer, inclusionMode)
        }

        if isPaginated {
            result.move(childLayer.offsetFromAncestor(ancestorLayer, WebCore.RenderLayer.DontAdjustForColumns))
            return result
        }

        result.move(offsetFromRoot)
        return result
    }

    @cxx
    @implementation
    public func absoluteBoundingBox() -> WebCore.IntRect {
        let rootLayer = root()
        return WebCore.snappedIntRect(
            boundingBox(
                rootLayer,
                offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns),
                WebCore.RenderLayer.CalculateLayerBoundsFlags()
            )
        )
    }

    @cxx
    @implementation
    public func absoluteBoundingBoxForPainting() -> WebCore.FloatRect {
        let rootLayer = root()
        return WebCore.snapRectToDevicePixels(
            boundingBox(
                rootLayer,
                offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns),
                WebCore.RenderLayer.CalculateLayerBoundsFlags()
            ),
            renderer().document().deviceScaleFactor()
        )
    }

    @cxx
    @implementation
    public func overlapBounds() -> WebCore.LayoutRect {
        if overlapBoundsIncludeChildren() || backing().map({ !$0.filterAnimationOutsetsForSwift().isZero() }) ?? false {
            var flags = WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.UseLocalClipRectExcludingCompositingIfPossible)
            flags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeFilterOutsets))
            flags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.UseFragmentBoxesExcludingCompositing))
            return calculateLayerBounds(self, WebCore.LayoutSize(), flags)
        }

        return localBoundingBox(WebCore.RenderLayer.CalculateLayerBoundsFlags())
    }

    @cxx
    @implementation
    public func calculateLayerBounds(
        _ ancestorLayer: WebCore.RenderLayer?,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ flags: WebCore.RenderLayer.CalculateLayerBoundsFlags
    ) -> WebCore.LayoutRect {
        if !isSelfPaintingLayer() {
            return WebCore.LayoutRect()
        }

        let layerRenderer = renderer()
        // FIXME: This could be improved to do a check like hasVisibleNonCompositingDescendantLayers() (bug 92580).
        if flags.contains(WebCore.RenderLayer.ExcludeHiddenDescendants) && !isSameRenderLayer(self, ancestorLayer) && !hasVisibleContent()
            && !hasVisibleDescendant()
        {
            return WebCore.LayoutRect()
        }

        if flags.contains(WebCore.RenderLayer.ExcludeViewTransitionCapturedDescendants) && !isSameRenderLayer(self, ancestorLayer)
            && layerRenderer.capturedInViewTransition() && !layerRenderer.isDocumentElementRenderer()
        {
            return WebCore.LayoutRect()
        }

        if isRenderViewLayer() {
            // The root layer is always just the size of the document.
            return WebCore.LayoutRect(layerRenderer.view().unscaledDocumentRect())
        }

        var localBoundingBoxFlags = flags
        localBoundingBoxFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeRootBackgroundPaintingArea))
        // When filters are composited, the compositor applies the filter effect, so the backing
        // layer should not be inflated by filter outsets; compute bounds excluding
        // filter outsets when possible.
        if isComposited() && layerRenderer.hasFilter() && !shouldPaintWithFilters(WebCore.RenderLayer.PaintBehaviors()) {
            localBoundingBoxFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.ExcludeFilterOutsetsFromSelfBounds))
        }

        var boundingBoxRect = localBoundingBox(localBoundingBoxFlags)
        if layerRenderer.view().frameViewHasFlippedBlockRenderersForSwift() {
            if let box = layerRenderer.asRenderBox() {
                box.blockStartRelativeToPhysical(&boundingBoxRect)
            } else {
                layerRenderer.containingBlock()!.blockStartRelativeToPhysical(&boundingBoxRect)
            }
        }

        var unionBounds = boundingBoxRect

        func computeLocalClipBounds() -> WebCore.LayoutRect {
            let infiniteRect = WebCore.LayoutRect.infiniteRect()
            if !flags.contains(WebCore.RenderLayer.UseLocalClipRectIfPossible)
                && !flags.contains(WebCore.RenderLayer.UseLocalClipRectExcludingCompositingIfPossible)
            {
                return infiniteRect
            }

            // FIXME: border-radius not accounted for.
            // FIXME: Regions not accounted for.
            let clippingRootLayer =
                flags.contains(WebCore.RenderLayer.UseLocalClipRectExcludingCompositingIfPossible) ? self : clippingRootForPainting()
            let offsetFromRoot = offsetFromAncestor(clippingRootLayer, WebCore.RenderLayer.DontAdjustForColumns)
            var clipRect = clipRectRelativeToAncestor(clippingRootLayer, offsetFromRoot, infiniteRect)
            if clipRect.isInfinite() {
                return infiniteRect
            }

            let renderableInfiniteRect = WebCore.LayoutRect.renderableInfiniteRect()
            if clipRect.width().rawValue() > renderableInfiniteRect.width().rawValue()
                || clipRect.height().rawValue() > renderableInfiniteRect.height().rawValue()
            {
                // Similar to the CSS clip check below, fall back to the descendant union if ancestor clipped
                // only one axis, leaving the other one unbounded. The clipRect.isInfinte() check doesn't
                // work here because it checks both axis. Checking either width or height matches
                // LayoutRect::infiniteRect doesn't work either because clipRectRelativeToAncestor() returns
                // a rectangle that has been moved and intersected, so it's close to infinite but not exactly
                // infinite. Comparing to LayoutRect::renderableInfiniteRect() we make sure that we don't return
                // a rectangle that can't be handled as layer bounds.
                return infiniteRect
            }

            if layerRenderer.hasClip() {
                if let box = layerRenderer.asRenderBox() {
                    // CSS clip may be larger than our border box.
                    let cssClipRect = box.clipRect(WebCore.LayoutPoint())
                    if !cssClipRect.isEmpty()
                        && (clipRect.width().rawValue() < cssClipRect.width().rawValue()
                            || clipRect.height().rawValue() < cssClipRect.height().rawValue())
                    {
                        return infiniteRect
                    }
                }
            }

            clipRect.move(negated(offsetFromRoot))
            return clipRect
        }

        var localClipRect = computeLocalClipBounds()
        if !localClipRect.isInfinite() {
            if flags.contains(WebCore.RenderLayer.IncludeSelfTransform) && paintsWithTransform(WebCore.RenderLayer.PaintBehaviors(.Normal))
            {
                localClipRect = transformValue().value!.mapRect(localClipRect)
            }

            localClipRect.move(offsetFromAncestor(ancestorLayer, WebCore.RenderLayer.DontAdjustForColumns))
            return localClipRect
        }

        // FIXME: should probably just pass 'flags' down to descendants.
        var descendantFlags = flags
        if !flags.contains(WebCore.RenderLayer.PreserveAncestorFlags) {
            descendantFlags = WebCore.RenderLayer.defaultCalculateLayerBoundsFlags()
            if flags.contains(WebCore.RenderLayer.ExcludeHiddenDescendants) {
                descendantFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.ExcludeHiddenDescendants))
            }
            if flags.contains(WebCore.RenderLayer.IncludeCompositedDescendants) {
                descendantFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeCompositedDescendants))
            }
        }
        if flags.contains(WebCore.RenderLayer.IncludeDescendantTransforms) {
            descendantFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeSelfTransform))
        }

        updateLayerListsIfNeeded()

        if let reflection = reflectionLayer() {
            if !reflection.isComposited() {
                let childUnionBounds = reflection.calculateLayerBounds(
                    self,
                    reflection.offsetFromAncestor(self, WebCore.RenderLayer.DontAdjustForColumns),
                    descendantFlags
                )
                unionBounds.unite(childUnionBounds)
            }
        }

        assert(isStackingContext() || paintOrderListSize(.Positive) == 0)

        func computeLayersUnion(_ which: WebCore.PaintOrderList) {
            let count = paintOrderListSize(which)
            var index = 0
            while index < count {
                let childLayer = paintOrderListLayerAt(which, index)
                index += 1
                if !flags.contains(WebCore.RenderLayer.IncludeCompositedDescendants)
                    && (childLayer.isComposited() || childLayer.paintsIntoProvidedBacking())
                {
                    continue
                }
                let childBounds = childLayer.calculateLayerBounds(
                    self,
                    childLayer.offsetFromAncestor(self, WebCore.RenderLayer.DontAdjustForColumns),
                    descendantFlags
                )
                // Ignore child layer (and behave as if we had overflow: hidden) when it is positioned off the parent layer so much
                // that we hit the max LayoutUnit value.
                unionBounds.checkedUnite(childBounds)
            }
        }

        return withLayerListMutationForbidden { () -> WebCore.LayoutRect in
            computeLayersUnion(.Negative)
            computeLayersUnion(.Positive)
            computeLayersUnion(.NormalFlow)

            let paintedFilterBehaviors =
                flags.contains(WebCore.RenderLayer.IncludeCompositedDescendants)
                ? WebCore.RenderLayer.PaintBehaviors(.FlattenCompositingLayers) : WebCore.RenderLayer.PaintBehaviors()
            if flags.contains(WebCore.RenderLayer.IncludeFilterOutsets)
                || (flags.contains(WebCore.RenderLayer.IncludePaintedFilterOutsets) && shouldPaintWithFilters(paintedFilterBehaviors))
            {
                var outsets = filterOutsets()
                if flags.contains(WebCore.RenderLayer.IncludeFilterOutsets), let backing = backing() {
                    outsets = WebCore.RenderLayerBacking.maxOutsetsForSwift(outsets, backing.filterAnimationOutsetsForSwift())
                }
                unionBounds.expand(WebCore.toLayoutBoxExtent(outsets))
            }

            if flags.contains(WebCore.RenderLayer.IncludeSelfTransform) && paintsWithTransform(WebCore.RenderLayer.PaintBehaviors(.Normal))
            {
                let affineTrans = transformValue().value!
                boundingBoxRect = affineTrans.mapRect(boundingBoxRect)
                unionBounds = affineTrans.mapRect(unionBounds)
            }
            unionBounds.move(offsetFromRoot)
            return unionBounds
        }
    }
}

// The paint-order lists and the private state that the compositor's Swift reads.
extension WebCore.RenderLayer {
    func paintOrderListCount(_ which: WebCore.PaintOrderList) -> Int {
        paintOrderListSize(which)
    }

    func paintOrderListLayer(_ which: WebCore.PaintOrderList, _ index: Int) -> WebCore.RenderLayer {
        paintOrderListLayerAt(which, index)
    }

    /// Runs body with the layer's list mutation forbidden where layerPositionsAssertEnabled() or securityAssertionsEnabled()
    /// (as the LayerListMutationDetectors under ASSERT_ENABLED || ENABLE(SECURITY_ASSERTIONS) do): a write to one of the
    /// layer's paint-order lists in body traps.
    @inline(always)
    func withLayerListMutationForbidden<Result>(_ body: () throws -> Result) rethrows -> Result {
        if !WebCore.RenderLayer.layerPositionsAssertEnabled() && !WebCore.RenderLayerCompositor.securityAssertionsEnabled() {
            return try body()
        }
        let wasAllowed = layerListMutationAllowed()
        setLayerListMutationAllowed(false)
        defer {
            setLayerListMutationAllowed(wasAllowed)
        }
        return try body()
    }

    func mustCompositeForIndirectReasonsForCompositor() -> Bool {
        mustCompositeForIndirectReasons()
    }

    func isInsideDrawableCanvasForCompositor() -> Bool {
        isInsideDrawableCanvas()
    }

    func has3DTransformedAncestorForCompositor() -> Bool {
        has3DTransformedAncestor()
    }

    func setIndirectCompositingReasonForCompositor(_ reason: WebCore.IndirectCompositingReason) {
        setIndirectCompositingReason(reason)
    }

    func setHasCompositingDescendantForCompositor(_ value: Bool) {
        setHasCompositingDescendant(value)
    }

    func setHasCompositedNonContainedDescendantsForCompositor(_ value: Bool) {
        setHasCompositedNonContainedDescendants(value)
    }

    func has3DTransformedDescendantForCompositor() -> Bool {
        has3DTransformedDescendant()
    }

    func update3DTransformedDescendantStatusForCompositor() {
        _ = update3DTransformedDescendantStatus()
    }

    func compositingStatusChangedForCompositor(_ layoutUpToDate: WebCore.LayoutUpToDate) {
        compositingStatusChanged(layoutUpToDate)
    }

    func setIntrinsicallyCompositedForCompositor(_ composited: Bool) {
        setIntrinsicallyComposited(composited)
    }

    func rendererBorderBoxRectForBacking() -> WebCore.LayoutRect {
        rendererBorderBoxRect()
    }
}

// MARK: - Hit testing

// The point and quads of a hit test mapped through the transforms of a 3D rendering context.
// lastPlanarPoint, lastPlanarQuad and lastPlanarArea are in the plane of the containing flattening layer;
// accumulatedTransform maps from that plane through the preserve-3d layers below it.
final class RenderLayerHitTestingTransformState {
    var lastPlanarPoint: WebCore.FloatPoint
    var lastPlanarQuad: WebCore.FloatQuad
    var lastPlanarArea: WebCore.FloatQuad
    var accumulatedTransform: WebCore.TransformationMatrix

    init(_ point: WebCore.FloatPoint, _ quad: WebCore.FloatQuad, _ area: WebCore.FloatQuad) {
        lastPlanarPoint = point
        lastPlanarQuad = quad
        lastPlanarArea = area
        accumulatedTransform = WebCore.TransformationMatrix()
    }

    init(copying other: RenderLayerHitTestingTransformState) {
        lastPlanarPoint = other.lastPlanarPoint
        lastPlanarQuad = other.lastPlanarQuad
        lastPlanarArea = other.lastPlanarArea
        accumulatedTransform = other.accumulatedTransform
    }

    func translate(_ x: Int32, _ y: Int32) {
        accumulatedTransform.translateBy(Double(x), Double(y))
    }

    func applyTransform(_ transformFromContainer: WebCore.TransformationMatrix) {
        accumulatedTransform.multiplyBy(transformFromContainer)
    }

    func flatten() {
        accumulatedTransform.flatten()
    }

    func mappedPoint() -> WebCore.FloatPoint {
        if let inverse = accumulatedTransform.inverse().value {
            return inverse.projectPoint(lastPlanarPoint)
        }
        return lastPlanarPoint
    }

    func mappedQuad() -> WebCore.FloatQuad {
        if let inverse = accumulatedTransform.inverse().value {
            return inverse.projectQuad(lastPlanarQuad)
        }
        return lastPlanarQuad
    }

    func boundsOfMappedArea() -> WebCore.LayoutRect {
        if let inverse = accumulatedTransform.inverse().value {
            return inverse.clampedBoundsOfProjectedQuad(lastPlanarArea)
        }
        return WebCore.TransformationMatrix().clampedBoundsOfProjectedQuad(lastPlanarArea)
    }

    func boundsOfMappedQuad() -> WebCore.LayoutRect {
        if let inverse = accumulatedTransform.inverse().value {
            return inverse.clampedBoundsOfProjectedQuad(lastPlanarQuad)
        }
        return WebCore.TransformationMatrix().clampedBoundsOfProjectedQuad(lastPlanarQuad)
    }
}

// The layer a hit test ended in, and the z offset of the hit point relative to the containing flattening layer.
struct RenderLayerHitLayer {
    var layer: WebCore.RenderLayer?
    var zOffset: Double

    init() {
        layer = nil
        zOffset = 0
    }

    init(_ layer: WebCore.RenderLayer?, _ zOffset: Double = 0) {
        self.layer = layer
        self.zOffset = zOffset
    }
}

// Compute the z-offset of the point in the transformState.
// This is effectively projecting a ray normal to the plane of ancestor, finding where that
// ray intersects target, and computing the z delta between those two points.
private func computeZOffset(_ transformState: RenderLayerHitTestingTransformState) -> Double {
    // We got an affine transform, so no z-offset
    if transformState.accumulatedTransform.isAffine() {
        return 0
    }

    // Flatten the point into the target plane
    let targetPoint = transformState.mappedPoint()

    // Now map the point back through the transform, which computes Z.
    let backmappedPoint = transformState.accumulatedTransform.mapPoint(WebCore.FloatPoint3D(targetPoint))
    return Double(backmappedPoint.z())
}

extension WebCore.RenderLayer {
    @cxx
    @implementation
    public func hitTestForSwift(
        _ request: WebCore.HitTestRequest,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ result: WebCore.HitTestResultView
    ) -> Bool {
        hitTest(request: request, location: hitTestLocation, result: &result.pointee)
    }

    func hitTest(
        request: WebCore.HitTestRequest,
        location hitTestLocation: WebCore.HitTestLocation,
        result: inout WebCore.HitTestResult
    ) -> Bool {
        let layerRenderer = renderer()
        let view = layerRenderer.view()
        var hitTestArea = WebCore.LayoutRect(view.documentRect())
        if !request.ignoreClipping() {
            let settings = layerRenderer.settings()
            if settings.visualViewportEnabled() && settings.clientCoordinatesRelativeToLayoutViewport() {
                var absoluteLayoutViewportRect = view.frameViewLayoutViewportRectForSwift()
                let scaleFactor = view.frameViewFrameScaleFactorForSwift()
                if scaleFactor > 1 {
                    absoluteLayoutViewportRect.scale(scaleFactor)
                }
                hitTestArea.intersect(absoluteLayoutViewportRect)
            } else {
                hitTestArea.intersect(WebCore.LayoutRect(view.frameViewLegacyIOSDocumentVisibleRectForSwift()))
            }
        }

        var insideLayer = hitTestLayer(self, nil, request, &result, hitTestArea, hitTestLocation, false)
        if insideLayer.layer == nil {
            // We didn't hit any layer. If we are the root layer and the mouse is -- or just was -- down,
            // return ourselves. We do this so mouse events continue getting delivered after a drag has
            // exited the WebView, and so hit testing over a scrollbar hits the content document.
            // In addtion, it is possible for the mouse to stay in the document but there is no element.
            // At that time, the events of the mouse should be fired.
            let hitPoint = hitTestLocation.point()
            let moveRequestIsOverDocument = request.move() && hitTestArea.contains(hitPoint)
            if !request.isChildFrameHitTest() && (request.active() || request.release() || moveRequestIsOverDocument) && isRenderViewLayer()
            {
                layerRenderer.updateHitTestResult(
                    &result,
                    layerRenderer.asRenderView()!.physicalToBlockStartRelative(hitTestLocation.point())
                )
                insideLayer = RenderLayerHitLayer(self)
            }
        }

        // Now determine if the result is inside an anchor - if the urlElement isn't already set.
        if let node = result.innerNode(), result.URLElement() == nil {
            result.setURLElement(node.enclosingLinkEventParentOrSelf())
        }

        // Now return whether we were inside this layer (this will always be true for the root
        // layer).
        return insideLayer.layer != nil
    }

    @inline(never)
    func createLocalTransformState(
        _ rootLayer: WebCore.RenderLayer?,
        _ containerLayer: WebCore.RenderLayer?,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ containerTransformState: RenderLayerHitTestingTransformState?,
        _ translationOffset: WebCore.LayoutSize = WebCore.LayoutSize()
    ) -> RenderLayerHitTestingTransformState {
        let transformState: RenderLayerHitTestingTransformState
        var offset: WebCore.LayoutSize
        if let containerTransformState {
            // If we're already computing transform state, then it's relative to the container (which we know is non-null).
            transformState = RenderLayerHitTestingTransformState(copying: containerTransformState)
            offset = offsetFromAncestor(containerLayer, WebCore.RenderLayer.DontAdjustForColumns)
        } else {
            // If this is the first time we need to make transform state, then base it off of hitTestLocation,
            // which is relative to rootLayer.
            transformState = RenderLayerHitTestingTransformState(
                hitTestLocation.transformedPoint(),
                hitTestLocation.transformedRect(),
                WebCore.FloatQuad(floatRect(hitTestRect))
            )
            offset = offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns)
        }
        offset += translationOffset

        // A layer that is not hosted has no projection: test that before reading the space, which may be null then.
        if isHostedInSpatialPortalScene(),
            let projection = hostedPortalContentProjection(containerTransformState != nil ? containerLayer! : rootLayer!).value
        {
            transformState.applyTransform(projection)
        }

        let layerRenderer = renderer()
        if layerRenderer.shouldUseTransformFromContainer(containerLayer?.renderer()) {
            var containerTransform = WebCore.TransformationMatrix()
            layerRenderer.getTransformFromContainer(offset, &containerTransform)
            transformState.applyTransform(containerTransform)
        } else {
            transformState.translate(offset.width().toInt(), offset.height().toInt())
        }

        return transformState
    }

    // hitTestLocation and hitTestRect are relative to rootLayer.
    // A 'flattening' layer is one preserves3D() == false.
    // transformState.accumulatedTransform holds the transform from the containing flattening layer.
    // transformState.lastPlanarPoint is the hitTestLocation in the plane of the containing flattening layer.
    // transformState.lastPlanarQuad is the hitTestRect as a quad in the plane of the containing flattening layer.
    // Kept out of line: hitTestList calls it from two places, once per child.
    @inline(never)
    func hitTestLayer(
        _ rootLayer: WebCore.RenderLayer?,
        _ containerLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ appliedTransform: Bool,
        _ transformState: RenderLayerHitTestingTransformState? = nil
    ) -> RenderLayerHitLayer {
        updateLayerListsIfNeeded()

        if !isSelfPaintingLayer() && !hasSelfPaintingLayerDescendant() {
            return RenderLayerHitLayer()
        }

        let layerRenderer = renderer()
        // Renderers that are captured in a view transition are not hit tested.
        if layerRenderer.effectiveCapturedInViewTransition() {
            return RenderLayerHitLayer()
        }

        // If we're hit testing 'SVG clip content' (aka. RenderSVGResourceClipper) do not early exit.
        if isSVGLayer() && !request.svgClipContent() && shouldSkipHitTestForSVG() {
            return RenderLayerHitLayer()
        }

        let skipLayerForFixedContainerSampling: Bool = {
            if !request.isForFixedContainerSampling() {
                return false
            }

            if !m_hasViewportConstrainedDescendant && !isViewportConstrained() && !hasFixedAncestor() && !m_hasStickyAncestor {
                return true
            }

            if hasCompositedScrollableOverflow() && !layerRenderer.hasBackground() {
                return true
            }

            return false
        }()

        if skipLayerForFixedContainerSampling {
            return RenderLayerHitLayer()
        }

        // The natural thing would be to keep RenderLayerHitTestingTransformState on the stack, but it's big, so we heap-allocate.

        let hasTransform = transformValue().value != nil || isHostedInSpatialPortalScene()

        // Apply a transform if we have one.
        if hasTransform && !appliedTransform {
            if enclosingPaginationLayer(WebCore.RenderLayer.IncludeCompositedPaginatedLayers) != nil {
                return hitTestTransformedLayerInFragments(
                    rootLayer,
                    containerLayer,
                    request,
                    &result,
                    hitTestRect,
                    hitTestLocation,
                    transformState
                )
            }

            // Make sure the parent's clip rects have been calculated.
            if parent() != nil {
                let clipRectsContext = RenderLayerClipRectsContext(
                    rootLayer,
                    WebCore.RootRelativeClipRects,
                    WebCore.RenderLayer.ClipRectsOptions(.RespectOverflowClip)
                )
                let clipRect = backgroundClipRect(clipRectsContext)
                // Test the enclosing clip now.
                if !clipRect.intersects(hitTestLocation) {
                    return RenderLayerHitLayer()
                }
            }

            return hitTestLayerByApplyingTransform(
                rootLayer,
                containerLayer,
                request,
                &result,
                hitTestRect,
                hitTestLocation,
                transformState
            )
        }

        // Ensure our lists and 3d status are up-to-date.
        _ = update3DTransformedDescendantStatus()

        var localTransformState: RenderLayerHitTestingTransformState? = nil
        if appliedTransform {
            // We computed the correct state in the caller (above code), so just reference it.
            localTransformState = transformState
        } else if transformState != nil || has3DTransformedDescendant() || preserves3D() {
            // We need transform state for the first time, or to offset the container state, so create it here.
            localTransformState = createLocalTransformState(rootLayer, containerLayer, hitTestRect, hitTestLocation, transformState)
        }

        // Check for hit test on backface if backface-visibility is 'hidden'
        if let localTransformState, layerRenderer[.Style].backfaceVisibility() == .Hidden {
            // If the z-vector of the matrix is negative, the back is facing towards the viewer.
            if let invertedMatrix = localTransformState.accumulatedTransform.inverse().value, invertedMatrix.m33() < 0 {
                return RenderLayerHitLayer()
            }
        }

        let depthSortDescendants = preserves3D()

        let selfZOffset = localTransformState.map { computeZOffset($0) } ?? 0

        return withLayerListMutationForbidden { () -> RenderLayerHitLayer in
            // This variable tracks which layer the mouse ends up being inside.
            var candidateLayer = RenderLayerHitLayer(nil, -Double.infinity)

            let offsetFromRoot = offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns)
            // FIXME: We need to correctly hit test the clip-path when we have an inline box too.
            if let rendererBox = renderBox(),
                !rendererBox.hitTestClipPath(
                    hitTestLocation,
                    WebCore.toLayoutPoint(offsetFromRoot - WebCore.toLayoutSize(rendererLocation()))
                )
            {
                return RenderLayerHitLayer()
            }

            // Collect the fragments. This will compute the clip rectangles for each layer fragment.
            var layerFragments = WebCore.LayerFragments()
            collectFragments(
                into: &layerFragments,
                rootLayer,
                hitTestRect,
                WebCore.RenderLayer.IncludeCompositedPaginatedLayers,
                WebCore.RootRelativeClipRects,
                WebCore.RenderLayer.ClipRectsOptions(.RespectOverflowClip),
                offsetFromRoot
            )

            // The resize control is painted on top of all content, so hit-test it first.
            var localPoint = WebCore.LayoutPoint()
            if canResize(), let scrollableArea = scrollableArea(),
                scrollableArea.hitTestResizerInFragments(layerFragments, hitTestLocation, &localPoint)
            {
                layerRenderer.updateHitTestResult(&result, localPoint)
                return RenderLayerHitLayer(self, selfZOffset)
            }

            do {
                // foreignObject hosts HTML content, so use the standard z-order hit-test path.
                let hitLayer =
                    (isSVGLayer() && !layerRenderer.isRenderSVGForeignObject())
                    ? hitTestChildrenForSVG(rootLayer, request, &result, hitTestRect, hitTestLocation, localTransformState)
                    : hitTestPositiveAndNormalFlowLists(
                        rootLayer,
                        request,
                        &result,
                        hitTestRect,
                        hitTestLocation,
                        localTransformState,
                        depthSortDescendants,
                        &candidateLayer
                    )
                if hitLayer.layer != nil {
                    if !depthSortDescendants {
                        return hitLayer
                    }
                    if hitLayer.zOffset > candidateLayer.zOffset {
                        candidateLayer = hitLayer
                    }
                }
            }

            // Next we want to see if the mouse pos is inside the child RenderObjects of the layer. Check
            // every fragment in reverse order.
            if isSelfPaintingLayer() {
                // Hit test with a temporary HitTestResult, because we only want to commit to 'result' if we know we're frontmost.
                var tempResult = WebCore.HitTestResult(result.hitTestLocation())
                var insideFragmentForegroundRect = false
                if hitTestContentsForFragments(
                    layerFragments,
                    request,
                    &tempResult,
                    hitTestLocation,
                    .Descendants,
                    &insideFragmentForegroundRect
                ) && (!depthSortDescendants || selfZOffset > candidateLayer.zOffset) {
                    if request.resultIsElementList() {
                        result.append(tempResult, request)
                    } else {
                        result = tempResult
                    }

                    if !depthSortDescendants {
                        return RenderLayerHitLayer(self, selfZOffset)
                    }

                    // Foreground can depth-sort with descendant layers, so keep this as a candidate.
                    candidateLayer = RenderLayerHitLayer(self, selfZOffset)
                } else if insideFragmentForegroundRect && request.resultIsElementList() {
                    result.append(tempResult, request)
                }
            }

            // Now check our negative z-index children. Non-foreignObject SVG layers interleave
            // their negative-z children in DOM order; those were already tested via
            // hitTestChildrenForSVG() above, so skip the standard negative-z-order list here.
            if !isSVGLayer() || layerRenderer.isRenderSVGForeignObject() {
                let hitLayer = hitTestLayerListAndMergeWithCandidate(
                    .Negative,
                    rootLayer,
                    request,
                    &result,
                    hitTestRect,
                    hitTestLocation,
                    localTransformState,
                    depthSortDescendants,
                    &candidateLayer
                )
                if hitLayer.layer != nil {
                    if !depthSortDescendants {
                        return hitLayer
                    }
                    if hitLayer.zOffset > candidateLayer.zOffset {
                        candidateLayer = hitLayer
                    }
                }
            }

            // If we found a layer, return. Child layers, and foreground always render in front of background.
            if candidateLayer.layer != nil && !depthSortDescendants {
                return candidateLayer
            }

            if isSelfPaintingLayer() {
                var tempResult = WebCore.HitTestResult(result.hitTestLocation())
                var insideFragmentBackgroundRect = false
                if hitTestContentsForFragments(layerFragments, request, &tempResult, hitTestLocation, .Self, &insideFragmentBackgroundRect)
                    && (!depthSortDescendants || selfZOffset > candidateLayer.zOffset)
                {
                    if request.resultIsElementList() {
                        result.append(tempResult, request)
                    } else {
                        result = tempResult
                    }

                    if !depthSortDescendants {
                        return RenderLayerHitLayer(self, selfZOffset)
                    }

                    candidateLayer = RenderLayerHitLayer(self, selfZOffset)
                }

                if insideFragmentBackgroundRect && request.resultIsElementList() {
                    result.append(tempResult, request)
                }
            }

            return candidateLayer
        }
    }

    @inline(never)
    func hitTestContentsForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ hitTestFilter: WebCore.HitTestFilter,
        _ insideClipRect: inout Bool
    ) -> Bool {
        if layerFragments.isEmpty() {
            return false
        }

        var index = Int(layerFragments.size())
        while index > 0 {
            index -= 1
            let fragment = layerFragments[index]
            if (hitTestFilter == .Self && !fragment.dirtyBackgroundRect().intersects(hitTestLocation))
                || (hitTestFilter == .Descendants && !fragment.dirtyForegroundRect().intersects(hitTestLocation))
            {
                continue
            }
            insideClipRect = true
            if hitTestContents(request, &result, fragment.layerBounds(), hitTestLocation, hitTestFilter) {
                return true
            }
        }

        return false
    }

    @inline(never)
    func hitTestTransformedLayerInFragments(
        _ rootLayer: WebCore.RenderLayer?,
        _ containerLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?
    ) -> RenderLayerHitLayer {
        var enclosingPaginationFragments = WebCore.LayerFragments()
        var offsetOfPaginationLayerFromRoot = WebCore.LayoutSize()
        let paginatedLayer = enclosingPaginationLayer(WebCore.RenderLayer.IncludeCompositedPaginatedLayers)!
        let transformedExtent = transparencyClipBox(
            paginatedLayer,
            WebCore.HitTestingTransparencyClipBox,
            WebCore.RootOfTransparencyClipBox,
            WebCore.RenderLayer.PaintBehaviors(),
            WebCore.RenderLayer.OptionalLayoutRect()
        )
        paginatedLayer.collectFragments(
            into: &enclosingPaginationFragments,
            rootLayer,
            hitTestRect,
            WebCore.RenderLayer.IncludeCompositedPaginatedLayers,
            WebCore.RootRelativeClipRects,
            WebCore.RenderLayer.ClipRectsOptions(.RespectOverflowClip),
            offsetOfPaginationLayerFromRoot,
            WebCore.RenderLayer.OptionalLayoutRect(transformedExtent)
        )

        var index = Int(enclosingPaginationFragments.size())
        while index > 0 {
            index -= 1
            let fragment = enclosingPaginationFragments[index]

            // Apply the page/column clip for this fragment, as well as any clips established by layers in between us and
            // the enclosing pagination layer.
            var clipRect = fragment.dirtyBackgroundRect().rectValue()

            // Now compute the clips within a given fragment
            if !isSameRenderLayer(parent(), paginatedLayer) {
                offsetOfPaginationLayerFromRoot = WebCore.toLayoutSize(
                    paginatedLayer.convertToLayerCoords(
                        rootLayer,
                        WebCore.toLayoutPoint(offsetOfPaginationLayerFromRoot),
                        WebCore.RenderLayer.DontAdjustForColumns
                    )
                )

                let clipRectsContext = RenderLayerClipRectsContext(
                    paginatedLayer,
                    WebCore.RootRelativeClipRects,
                    WebCore.RenderLayer.ClipRectsOptions(.RespectOverflowClip)
                )
                var parentClipRect = backgroundClipRect(clipRectsContext).rectValue()
                parentClipRect.move(fragment.paginationOffset + offsetOfPaginationLayerFromRoot)
                clipRect.intersect(parentClipRect)
            }

            if !hitTestLocation.intersects(clipRect) {
                continue
            }

            let hitLayer = hitTestLayerByApplyingTransform(
                rootLayer,
                containerLayer,
                request,
                &result,
                hitTestRect,
                hitTestLocation,
                transformState,
                fragment.paginationOffset
            )
            if hitLayer.layer != nil {
                return hitLayer
            }
        }

        return RenderLayerHitLayer()
    }

    @inline(never)
    func hitTestLayerByApplyingTransform(
        _ rootLayer: WebCore.RenderLayer?,
        _ containerLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?,
        _ translationOffset: WebCore.LayoutSize = WebCore.LayoutSize()
    ) -> RenderLayerHitLayer {
        // Create a transform state to accumulate this transform.
        let newTransformState = createLocalTransformState(
            rootLayer,
            containerLayer,
            hitTestRect,
            hitTestLocation,
            transformState,
            translationOffset
        )

        // If the transform can't be inverted, then don't hit test this layer at all.
        if !newTransformState.accumulatedTransform.isInvertible() {
            return RenderLayerHitLayer()
        }

        // Compute the point and the hit test rect in the coords of this layer by using the values
        // from the transformState, which store the point and quad in the coords of the last flattened
        // layer, and the accumulated transform which lets up map through preserve-3d layers.
        //
        // We can't just map hitTestLocation and hitTestRect because they may have been flattened (losing z)
        // by our container.
        let localPoint = newTransformState.mappedPoint()
        let localHitTestRect = newTransformState.boundsOfMappedArea()
        let newHitTestLocation: WebCore.HitTestLocation
        if hitTestLocation.isRectBasedTest() {
            let localPointQuad = newTransformState.mappedQuad()
            newHitTestLocation = WebCore.HitTestLocation(localPoint, localPointQuad, .Yes)
        } else {
            let localPointQuad = newTransformState.boundsOfMappedQuad()
            newHitTestLocation = WebCore.HitTestLocation(localPoint, WebCore.FloatQuad(floatRect(localPointQuad)), .No)
        }

        // Now do a hit test with the root layer shifted to be us.
        return hitTestLayer(self, containerLayer, request, &result, localHitTestRect, newHitTestLocation, true, newTransformState)
    }

    func hitTestContents(
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ layerBounds: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ hitTestFilter: WebCore.HitTestFilter
    ) -> Bool {
        if !hitTestContentForRenderer(
            request,
            &result,
            hitTestLocation,
            WebCore.toLayoutPoint(WebCore.toLayoutSize(layerBounds.location()) - WebCore.toLayoutSize(rendererLocation())),
            hitTestFilter
        ) {
            return false
        }

        // For positioned generated content, we might still not have a
        // node by the time we get to the layer level, since none of
        // the content in the layer has an element. So just walk up
        // the tree.
        if result.innerNode() == nil || result.innerNonSharedNode() == nil {
            let e = enclosingElement()
            if result.innerNode() == nil {
                result.setInnerNode(e)
            }
            if result.innerNonSharedNode() == nil {
                result.setInnerNonSharedNode(e)
            }
        }

        return true
    }

    // The lists of most layers are empty, so test that before entering the walk.
    @inline(always)
    func hitTestList(
        _ list: WebCore.PaintOrderList,
        _ rootLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?,
        _ depthSortDescendants: Bool
    ) -> RenderLayerHitLayer {
        if paintOrderListSize(list) == 0 {
            return RenderLayerHitLayer()
        }

        return hitTestNonEmptyList(list, rootLayer, request, &result, hitTestRect, hitTestLocation, transformState, depthSortDescendants)
    }

    @inline(never)
    func hitTestNonEmptyList(
        _ list: WebCore.PaintOrderList,
        _ rootLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?,
        _ depthSortDescendants: Bool
    ) -> RenderLayerHitLayer {
        if !hasSelfPaintingLayerDescendant() {
            return RenderLayerHitLayer()
        }

        if let renderBox = renderBox(), renderBox.isSkippedContentRootForSwift() {
            return RenderLayerHitLayer()
        }

        var resultLayer = RenderLayerHitLayer(nil, -Double.infinity)

        var flattenedTransformState: RenderLayerHitTestingTransformState? = nil
        var unflattenedZOffset: Double = 0
        var index = paintOrderListSize(list)
        while index > 0 {
            index -= 1
            let childLayer = paintOrderListLayerAt(list, index)

            // If we're about to cross a flattening boundary, then pass the (lazily-initialized)
            // flattened transfomState to the child layer. Otherwise pass transformState itself,
            // borrowed rather than copied into a local.
            var childIsFlattened = false
            if let transformState, !childLayer.participatesInPreserve3D() {
                if flattenedTransformState == nil {
                    let flattened = RenderLayerHitTestingTransformState(copying: transformState)
                    flattened.flatten()
                    flattenedTransformState = flattened
                    unflattenedZOffset = computeZOffset(transformState)
                }
                childIsFlattened = true
            }

            var tempResult = WebCore.HitTestResult(result.hitTestLocation())
            var hitLayer: RenderLayerHitLayer
            if childIsFlattened {
                hitLayer = childLayer.hitTestLayer(
                    rootLayer,
                    self,
                    request,
                    &tempResult,
                    hitTestRect,
                    hitTestLocation,
                    false,
                    flattenedTransformState
                )
            } else {
                hitLayer = childLayer.hitTestLayer(
                    rootLayer,
                    self,
                    request,
                    &tempResult,
                    hitTestRect,
                    hitTestLocation,
                    false,
                    transformState
                )
            }

            if hitLayer.layer != nil && !depthSortDescendants && !request.resultIsElementList()
                && childLayer.isHostedInSpatialPortalScene()
            {
                let frontmost = hitTestFrontmostHostedChild(
                    rootLayer,
                    request,
                    &tempResult,
                    hitTestRect,
                    hitTestLocation,
                    childIsFlattened ? flattenedTransformState : transformState
                )
                if frontmost.layer != nil {
                    hitLayer = frontmost
                }
            }

            // If it is a list-based test, we can safely append the temporary result since it might had hit
            // nodes but not necessarily had hitLayer set.
            if request.resultIsElementList() {
                result.append(tempResult, request)
            }

            if hitLayer.layer != nil {
                // If the child was flattened, then override the returned depth with the depth of the
                // plane we flattened into (ourselves) instead. With no transformState, the child's
                // state and the flattened one are both null, so this holds too, with a zOffset of 0.
                if childIsFlattened || transformState == nil {
                    hitLayer.zOffset = unflattenedZOffset
                }

                if !depthSortDescendants || hitLayer.zOffset > resultLayer.zOffset {
                    resultLayer = hitLayer
                    if !request.resultIsElementList() {
                        result = tempResult
                    }
                    if !depthSortDescendants {
                        break
                    }
                }
            }
        }

        return resultLayer
    }

    func hitTestFrontmostHostedChild(
        _ rootLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?
    ) -> RenderLayerHitLayer {
        let coplanarTolerance = 0.01

        var frontmost = RenderLayerHitLayer(nil, -Double.infinity)
        for list in [WebCore.PaintOrderList.Negative, .NormalFlow, .Positive] {
            for index in 0..<paintOrderListSize(list) {
                let childLayer = paintOrderListLayerAt(list, index)
                if !childLayer.isHostedInSpatialPortalScene() {
                    continue
                }

                var childResult = WebCore.HitTestResult(result.hitTestLocation())
                let hitLayer = childLayer.hitTestLayer(
                    rootLayer,
                    self,
                    request,
                    &childResult,
                    hitTestRect,
                    hitTestLocation,
                    false,
                    transformState
                )
                if hitLayer.layer == nil {
                    continue
                }

                let depth = computeZOffset(
                    childLayer.createLocalTransformState(rootLayer, self, hitTestRect, hitTestLocation, transformState)
                )
                if frontmost.layer != nil && depth < frontmost.zOffset - coplanarTolerance {
                    continue
                }

                frontmost = RenderLayerHitLayer(hitLayer.layer, depth)
                result = childResult
            }
        }
        return frontmost
    }

    func hitTestPositiveAndNormalFlowLists(
        _ rootLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?,
        _ depthSortDescendants: Bool,
        _ candidateLayer: inout RenderLayerHitLayer
    ) -> RenderLayerHitLayer {
        // Begin by walking our list of positive layers from highest z-index down to the lowest z-index.
        let hitLayer = hitTestList(
            .Positive,
            rootLayer,
            request,
            &result,
            hitTestRect,
            hitTestLocation,
            transformState,
            depthSortDescendants
        )
        if hitLayer.layer != nil {
            if !depthSortDescendants {
                return hitLayer
            }
            if hitLayer.zOffset > candidateLayer.zOffset {
                candidateLayer = hitLayer
            }
        }

        // Now check our overflow objects.
        return hitTestLayerListAndMergeWithCandidate(
            .NormalFlow,
            rootLayer,
            request,
            &result,
            hitTestRect,
            hitTestLocation,
            transformState,
            depthSortDescendants,
            &candidateLayer
        )
    }

    // An empty list leaves result and candidateLayer as they are: appending an empty result changes nothing.
    @inline(always)
    func hitTestLayerListAndMergeWithCandidate(
        _ list: WebCore.PaintOrderList,
        _ rootLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?,
        _ depthSortDescendants: Bool,
        _ candidateLayer: inout RenderLayerHitLayer
    ) -> RenderLayerHitLayer {
        if paintOrderListSize(list) == 0 {
            return RenderLayerHitLayer()
        }

        return hitTestNonEmptyLayerListAndMergeWithCandidate(
            list,
            rootLayer,
            request,
            &result,
            hitTestRect,
            hitTestLocation,
            transformState,
            depthSortDescendants,
            &candidateLayer
        )
    }

    @inline(never)
    func hitTestNonEmptyLayerListAndMergeWithCandidate(
        _ list: WebCore.PaintOrderList,
        _ rootLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?,
        _ depthSortDescendants: Bool,
        _ candidateLayer: inout RenderLayerHitLayer
    ) -> RenderLayerHitLayer {
        var tempResult = WebCore.HitTestResult(result.hitTestLocation())
        let hitLayer = hitTestNonEmptyList(
            list,
            rootLayer,
            request,
            &tempResult,
            hitTestRect,
            hitTestLocation,
            transformState,
            depthSortDescendants
        )

        if request.resultIsElementList() {
            result.append(tempResult, request)
        }

        if hitLayer.layer != nil {
            if !depthSortDescendants || hitLayer.zOffset > candidateLayer.zOffset {
                if !request.resultIsElementList() {
                    result = tempResult
                }

                candidateLayer = hitLayer
            }

            if !depthSortDescendants {
                return hitLayer
            }
        }

        return RenderLayerHitLayer()
    }

    func hitTestNonLayerChildInDOMOrderForSVG(
        _ index: UInt32,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ userSpaceRect: WebCore.LayoutRect,
        _ userSpaceLocation: WebCore.HitTestLocation,
        _ svgOffset: WebCore.LayoutSize
    ) -> Bool {
        if !childPhasesToPaintInDOMOrderForSVG(index).contains(.Foreground) {
            return false
        }

        guard let childRenderer = childRendererInDOMOrderForSVG(index) else {
            return false
        }
        let accumulatedAncestorOffset = childAccumulatedAncestorOffsetInDOMOrderForSVG(index)

        if childRenderer.isTransformed() {
            return hitTestRendererByInversingTransformForSVG(
                childRenderer,
                accumulatedAncestorOffset,
                request,
                &result,
                userSpaceRect,
                userSpaceLocation
            )
        }

        var accumulatedOffset = WebCore.LayoutPoint(svgOffset)
        accumulatedOffset.move(accumulatedAncestorOffset)

        return childRenderer.nodeAtPoint(request, &result, userSpaceLocation, accumulatedOffset, .Foreground)
    }

    func hitTestRendererByInversingTransformForSVG(
        _ rendererToTest: WebCore.RenderElement,
        _ positionOffset: WebCore.LayoutSize,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation
    ) -> Bool {
        guard let transform = rendererTransformForSVG(rendererToTest, positionOffset) else {
            return false
        }

        guard let inverse = transform.inverse().value else {
            return false
        }

        let point = hitTestLocation.point()
        let localPoint = inverse.mapPoint(WebCore.FloatPoint(point.x().toFloat(), point.y().toFloat()))
        let localRect = WebCore.enclosingLayoutRect(inverse.mapRect(floatRect(hitTestRect)))

        let localLocation = WebCore.HitTestLocation(WebCore.LayoutPoint(localPoint))

        let rendererObject: WebCore.RenderObject = rendererToTest
        if rendererObject.isRenderSVGContainer() {
            var accumulatedOffset = WebCore.LayoutPoint()
            if !rendererObject.isRenderSVGViewportContainer() || !rendererObject.isAnonymous() {
                if let svgModel = rendererObject.asRenderSVGModelObject() {
                    accumulatedOffset = svgModel.nominalSVGLayoutLocation()
                }
            }
            return hitTestSubtreeWithinTransformScopeForSVG(rendererToTest, accumulatedOffset, request, &result, localRect, localLocation)
        }

        var accumulatedOffset = WebCore.LayoutPoint()
        if let parentRenderer = rendererObject.parent(),
            let parentSVGModel = (parentRenderer as WebCore.RenderObject).asRenderSVGModelObject()
        {
            accumulatedOffset = parentSVGModel.nominalSVGLayoutLocation()
        }
        return rendererToTest.nodeAtPoint(request, &result, localLocation, accumulatedOffset, .Foreground)
    }

    func hitTestSubtreeWithinTransformScopeForSVG(
        _ container: WebCore.RenderElement,
        _ accumulatedOffset: WebCore.LayoutPoint,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation
    ) -> Bool {
        var previous = container.lastChild()
        while let child = previous {
            previous = child.previousSibling()
            guard let childElement = child.asRenderElement() else {
                continue
            }

            if childElement.isRenderSVGHiddenContainer() || childElement[.Style].displayIsNone() {
                continue
            }

            if childElement.isTransformed() {
                if hitTestRendererByInversingTransformForSVG(
                    childElement,
                    WebCore.toLayoutSize(accumulatedOffset),
                    request,
                    &result,
                    hitTestRect,
                    hitTestLocation
                ) {
                    return true
                }
                continue
            }

            if childElement.hasSelfPaintingLayer() {
                if childElement.nodeAtPoint(request, &result, hitTestLocation, accumulatedOffset, .Foreground) {
                    return true
                }
                continue
            }

            var adjustedOffset = accumulatedOffset
            if let childSVGModel = childElement.asRenderSVGModelObject() {
                adjustedOffset.moveBy(childSVGModel.currentSVGLayoutLocation())
            }

            if childElement.isRenderSVGContainer() {
                if childElement.isRenderSVGViewportContainer() {
                    let point = hitTestLocation.point()
                    if WebCore.RenderLayer.isOverflowHiddenForSVG(childElement)
                        && !WebCore.RenderLayer.viewportForSVG(childElement)
                            .contains(WebCore.FloatPoint(point.x().toFloat(), point.y().toFloat()))
                    {
                        continue
                    }
                }
                if hitTestSubtreeWithinTransformScopeForSVG(childElement, adjustedOffset, request, &result, hitTestRect, hitTestLocation) {
                    return true
                }
            } else {
                if childElement.nodeAtPoint(request, &result, hitTestLocation, accumulatedOffset, .Foreground) {
                    return true
                }
            }
        }

        return false
    }

    @inline(never)
    func hitTestChildrenForSVG(
        _ rootLayer: WebCore.RenderLayer?,
        _ request: WebCore.HitTestRequest,
        _ result: inout WebCore.HitTestResult,
        _ hitTestRect: WebCore.LayoutRect,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ transformState: RenderLayerHitTestingTransformState?
    ) -> RenderLayerHitLayer {
        if svgViewportClipExcludesForSVG(hitTestLocation) {
            return RenderLayerHitLayer()
        }

        let count = childrenInDOMOrderCountForSVG()
        if count == 0 {
            return RenderLayerHitLayer()
        }

        var svgOffset = WebCore.LayoutSize()
        var userSpaceShift = WebCore.LayoutSize()
        if let svgModelObject = renderer().asRenderSVGModelObject() {
            svgOffset = WebCore.toLayoutSize(svgModelObject.nominalSVGLayoutLocation())
            userSpaceShift = svgOffset - offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns)
        }

        let userSpaceLocation = WebCore.HitTestLocation(hitTestLocation, userSpaceShift)
        var userSpaceRect = hitTestRect
        userSpaceRect.move(userSpaceShift)

        var index = count
        while index > 0 {
            index -= 1
            if let childLayer = childLayerInDOMOrderForSVG(index) {
                let hitLayer = childLayer.hitTestLayer(
                    rootLayer,
                    self,
                    request,
                    &result,
                    hitTestRect,
                    hitTestLocation,
                    false,
                    transformState
                )
                if hitLayer.layer != nil {
                    return hitLayer
                }
                continue
            }

            if hitTestNonLayerChildInDOMOrderForSVG(index, request, &result, userSpaceRect, userSpaceLocation, svgOffset) {
                return RenderLayerHitLayer(self)
            }
        }

        return RenderLayerHitLayer()
    }
}

// MARK: - Fragments and the transparency clip box

extension WebCore.RenderLayer {
    @cxx
    @implementation
    public func collectFragmentsForSwift(
        _ fragments: WebCore.LayerFragmentsView,
        _ rootLayer: WebCore.RenderLayer?,
        _ dirtyRect: WebCore.LayoutRect,
        _ inclusionMode: WebCore.RenderLayer.PaginationInclusionMode,
        _ clipRectsType: WebCore.ClipRectsType,
        _ clipRectOptions: WebCore.RenderLayer.ClipRectsOptions,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ layerBoundingBox: WebCore.RenderLayer.OptionalLayoutRect,
        _ applyRootOffsetToFragments: WebCore.ShouldApplyRootOffsetToFragments
    ) {
        collectFragments(
            into: &fragments.pointee,
            rootLayer,
            dirtyRect,
            inclusionMode,
            clipRectsType,
            clipRectOptions,
            offsetFromRoot,
            layerBoundingBox,
            applyRootOffsetToFragments
        )
    }

    func collectFragments(
        into fragments: inout WebCore.LayerFragments,
        _ rootLayer: WebCore.RenderLayer?,
        _ dirtyRect: WebCore.LayoutRect,
        _ inclusionMode: WebCore.RenderLayer.PaginationInclusionMode,
        _ clipRectsType: WebCore.ClipRectsType,
        _ clipRectOptions: WebCore.RenderLayer.ClipRectsOptions,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ layerBoundingBox: WebCore.RenderLayer.OptionalLayoutRect = WebCore.RenderLayer.OptionalLayoutRect(),
        _ applyRootOffsetToFragments: WebCore.ShouldApplyRootOffsetToFragments = WebCore.IgnoreRootOffsetForFragments
    ) {
        var clipRectOptions = clipRectOptions
        let paginationLayer = enclosingPaginationLayerInSubtree(rootLayer, inclusionMode)
        guard let paginationLayer, !isTransformed() else {
            // For unpaginated layers, there is only one fragment.
            let clipRectsContext = RenderLayerClipRectsContext(rootLayer, clipRectsType, clipRectOptions)
            fragments.append(consuming: WebCore.LayerFragment(consuming: calculateRects(clipRectsContext, offsetFromRoot, dirtyRect)))
            return
        }

        // Compute our offset within the enclosing pagination layer.
        let offsetWithinPaginatedLayer = offsetFromAncestor(paginationLayer, WebCore.RenderLayer.DontAdjustForColumns)

        // Calculate clip rects relative to the enclosingPaginationLayer. The purpose of this call is to determine our bounds clipped to
        // intermediate
        // layers between us and the pagination context. It's important to minimize the number of fragments we need to create and this helps
        // with that.
        clipRectOptions.add(WebCore.RenderLayer.ClipRectsOptions(.Temporary))
        let paginationClipRectsContext = RenderLayerClipRectsContext(paginationLayer, WebCore.PaintingClipRects, clipRectOptions)
        let rectsInFragmentedFlow = calculateRects(paginationClipRectsContext, offsetWithinPaginatedLayer)

        // Take our bounding box within the flow thread and clip it.
        var layerBoundingBoxInFragmentedFlow =
            layerBoundingBox.value
            ?? boundingBox(paginationLayer, offsetWithinPaginatedLayer, WebCore.RenderLayer.CalculateLayerBoundsFlags())
        layerBoundingBoxInFragmentedFlow.intersect(rectsInFragmentedFlow.dirtyBackgroundRect().rectValue())

        let enclosingFragmentedFlow = paginationLayer.renderer()
        let parentPaginationLayer = paginationLayer.parent()!.enclosingPaginationLayerInSubtree(rootLayer, inclusionMode)
        var ancestorFragments = WebCore.LayerFragments()
        if let parentPaginationLayer {
            // Compute a bounding box accounting for fragments.
            var layerFragmentBoundingBoxInParentPaginationLayer = enclosingFragmentedFlow.fragmentsBoundingBoxForSwift(
                layerBoundingBoxInFragmentedFlow
            )

            // Convert to be in the ancestor pagination context's coordinate space.
            let offsetWithinParentPaginatedLayer = paginationLayer.offsetFromAncestor(
                parentPaginationLayer,
                WebCore.RenderLayer.DontAdjustForColumns
            )
            layerFragmentBoundingBoxInParentPaginationLayer.move(offsetWithinParentPaginatedLayer)

            // Now collect ancestor fragments.
            parentPaginationLayer.collectFragments(
                into: &ancestorFragments,
                rootLayer,
                dirtyRect,
                inclusionMode,
                clipRectsType,
                clipRectOptions,
                offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns),
                WebCore.RenderLayer.OptionalLayoutRect(layerFragmentBoundingBoxInParentPaginationLayer),
                WebCore.ApplyRootOffsetToFragments
            )

            if ancestorFragments.isEmpty() {
                return
            }

            for ancestorFragment in ancestorFragments {
                // Shift the dirty rect into flow thread coordinates.
                var dirtyRectInFragmentedFlow = dirtyRect
                dirtyRectInFragmentedFlow.move(WebCore.LayoutSize() - offsetWithinParentPaginatedLayer - ancestorFragment.paginationOffset)

                let oldSize = fragments.size()

                // Tell the flow thread to collect the fragments. We pass enough information to create a minimal number of fragments based
                // off the pages/columns
                // that intersect the actual dirtyRect as well as the pages/columns that intersect our layer's bounding box.
                enclosingFragmentedFlow.collectLayerFragmentsForSwift(
                    &fragments,
                    layerBoundingBoxInFragmentedFlow,
                    dirtyRectInFragmentedFlow
                )

                let newSize = fragments.size()

                if oldSize == newSize {
                    continue
                }

                var i = Int(oldSize)
                while i < Int(newSize) {
                    // Set our four rects with all clipping applied that was internal to the flow thread.
                    fragments[i].rects = WebCore.LayerFragment.Rects(rectsInFragmentedFlow, layerBoundingBoxInFragmentedFlow)

                    // Shift to the root-relative physical position used when painting the flow thread in this fragment.
                    fragments[i]
                        .moveBy(
                            WebCore.toLayoutPoint(
                                ancestorFragment.paginationOffset + fragments[i].paginationOffset + offsetWithinParentPaginatedLayer
                            )
                        )

                    // Intersect the fragment with our ancestor's background clip so that e.g., columns in an overflow:hidden block are
                    // properly clipped by the overflow.
                    fragments[i].intersect(ancestorFragment.paginationClip)

                    // Now intersect with our pagination clip. This will typically mean we're just intersecting the dirty rect with the
                    // column
                    // clip, so the column clip ends up being all we apply.
                    fragments[i].intersect(fragments[i].paginationClip)

                    if applyRootOffsetToFragments == WebCore.ApplyRootOffsetToFragments {
                        fragments[i].paginationOffset =
                            ancestorFragment.paginationOffset + fragments[i].paginationOffset + offsetWithinParentPaginatedLayer
                        fragments[i].paginationClip.intersect(ancestorFragment.paginationClip)
                    }
                    i += 1
                }
            }

            return
        }

        // Shift the dirty rect into flow thread coordinates.
        let offsetOfPaginationLayerFromRoot = enclosingPaginationLayer(inclusionMode)!
            .offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns)
        var dirtyRectInFragmentedFlow = dirtyRect
        dirtyRectInFragmentedFlow.move(WebCore.LayoutSize() - offsetOfPaginationLayerFromRoot)

        // Tell the flow thread to collect the fragments. We pass enough information to create a minimal number of fragments based off the
        // pages/columns
        // that intersect the actual dirtyRect as well as the pages/columns that intersect our layer's bounding box.
        enclosingFragmentedFlow.collectLayerFragmentsForSwift(&fragments, layerBoundingBoxInFragmentedFlow, dirtyRectInFragmentedFlow)

        if fragments.isEmpty() {
            return
        }

        // Get the parent clip rects of the pagination layer, since we need to intersect with that when painting column contents.
        var ancestorClipRect = WebCore.ClipRect(dirtyRect)
        if paginationLayer.parent() != nil {
            let clipRectsContext = RenderLayerClipRectsContext(rootLayer, clipRectsType, clipRectOptions)
            ancestorClipRect = paginationLayer.backgroundClipRect(clipRectsContext)
            ancestorClipRect.intersect(dirtyRect)
        }

        var i = 0
        while i < Int(fragments.size()) {
            // Set our four rects with all clipping applied that was internal to the flow thread.
            fragments[i].rects = WebCore.LayerFragment.Rects(rectsInFragmentedFlow, layerBoundingBoxInFragmentedFlow)

            // Shift to the root-relative physical position used when painting the flow thread in this fragment.
            fragments[i].moveBy(WebCore.toLayoutPoint(fragments[i].paginationOffset + offsetOfPaginationLayerFromRoot))

            // Intersect the fragment with our ancestor's background clip so that e.g., columns in an overflow:hidden block are
            // properly clipped by the overflow.
            fragments[i].intersect(ancestorClipRect)

            // Now intersect with our pagination clip. This will typically mean we're just intersecting the dirty rect with the column
            // clip, so the column clip ends up being all we apply.
            fragments[i].intersect(fragments[i].paginationClip)

            if applyRootOffsetToFragments == WebCore.ApplyRootOffsetToFragments {
                fragments[i].paginationOffset = fragments[i].paginationOffset + offsetOfPaginationLayerFromRoot
            }
            i += 1
        }
    }

    private func expandClipRectForDescendantsAndReflection(
        _ clipRect: inout WebCore.LayoutRect,
        _ rootLayer: WebCore.RenderLayer?,
        _ transparencyBehavior: WebCore.TransparencyClipBoxBehavior,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ paintDirtyRect: WebCore.RenderLayer.OptionalLayoutRect
    ) {
        let layerRenderer = renderer()
        // If we have a mask, then the clip is limited to the border box area (and there is
        // no need to examine child layers).
        if !layerRenderer.hasMask() {
            // Note: we don't have to walk z-order lists since transparent elements always establish
            // a stacking container. This means we can just walk the layer tree directly.
            var current = firstChild()
            while let child = current {
                if !isReflectionLayer(child) {
                    clipRect.unite(
                        child.transparencyClipBox(
                            rootLayer,
                            transparencyBehavior,
                            WebCore.DescendantsOfTransparencyClipBox,
                            paintBehavior,
                            paintDirtyRect
                        )
                    )
                }
                current = child.nextSibling()
            }
        }

        // If we have a reflection, then we need to account for that when we push the clip.  Reflect our entire
        // current transparencyClipBox to catch all child layers.
        // FIXME: Accelerated compositing will eventually want to do something smart here to avoid incorporating this
        // size into the parent layer.
        if layerRenderer.isRenderBox() && layerRenderer.hasReflection() {
            let delta = offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns)
            clipRect.move(WebCore.LayoutSize() - delta)
            clipRect.unite(renderBox()!.reflectedRect(clipRect))
            clipRect.move(delta)
        }
    }

    @cxx
    @implementation
    public func transparencyClipBox(
        _ rootLayer: WebCore.RenderLayer?,
        _ transparencyBehavior: WebCore.TransparencyClipBoxBehavior,
        _ transparencyMode: WebCore.TransparencyClipBoxMode,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ paintDirtyRect: WebCore.RenderLayer.OptionalLayoutRect
    ) -> WebCore.LayoutRect {
        // FIXME: Although this function completely ignores CSS-imposed clipping, we did already intersect with the
        // paintDirtyRect, and that should cut down on the amount we have to paint.  Still it
        // would be better to respect clips.

        if !isSameRenderLayer(rootLayer, self)
            && ((transparencyBehavior == WebCore.PaintingTransparencyClipBox && paintsWithTransform(paintBehavior))
                || (transparencyBehavior == WebCore.HitTestingTransparencyClipBox && isTransformed()))
        {
            // The best we can do here is to use enclosed bounding boxes to establish a "fuzzy" enough clip to encompass
            // the transformed layer and all of its children.
            let mode =
                transparencyBehavior == WebCore.HitTestingTransparencyClipBox
                ? WebCore.RenderLayer.IncludeCompositedPaginatedLayers : WebCore.RenderLayer.ExcludeCompositedPaginatedLayers
            let paginationLayer = transparencyMode == WebCore.DescendantsOfTransparencyClipBox ? enclosingPaginationLayer(mode) : nil
            let rootLayerForTransform = paginationLayer ?? rootLayer
            let delta = offsetFromAncestor(rootLayerForTransform, WebCore.RenderLayer.DontAdjustForColumns)

            var transform = WebCore.TransformationMatrix()
            transform.translateBy(delta.width().toDouble(), delta.height().toDouble())
            transform.multiplyBy(transformValue().value!)

            // We don't use fragment boxes when collecting a transformed layer's bounding box, since it always
            // paints unfragmented.
            var clipRect = boundingBox(self, WebCore.LayoutSize(), WebCore.RenderLayer.CalculateLayerBoundsFlags())
            expandClipRectForDescendantsAndReflection(&clipRect, self, transparencyBehavior, paintBehavior, paintDirtyRect)
            clipRect.expand(WebCore.toLayoutBoxExtent(filterOutsets()))
            var result = transform.mapRect(clipRect)
            guard let paginationLayer else {
                if let paintDirtyRect = paintDirtyRect.value {
                    result = WebCore.intersection(result, paintDirtyRect)
                }
                return result
            }

            // We have to break up the transformed extent across our columns.
            // Split our box up into the actual fragment boxes that render in the columns/pages and unite those together to
            // get our true bounding box.
            result = paginationLayer.renderer().fragmentsBoundingBoxForSwift(result)
            result.move(paginationLayer.offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns))
            if let paintDirtyRect = paintDirtyRect.value {
                result = WebCore.intersection(result, paintDirtyRect)
            }
            return result
        }

        var flags = WebCore.RenderLayer.CalculateLayerBoundsFlags(
            transparencyBehavior == WebCore.HitTestingTransparencyClipBox
                ? WebCore.RenderLayer.UseFragmentBoxesIncludingCompositing : WebCore.RenderLayer.UseFragmentBoxesExcludingCompositing
        )
        flags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeRootBackgroundPaintingArea))
        var clipRect = boundingBox(rootLayer, offsetFromAncestor(rootLayer, WebCore.RenderLayer.DontAdjustForColumns), flags)
        expandClipRectForDescendantsAndReflection(&clipRect, rootLayer, transparencyBehavior, paintBehavior, paintDirtyRect)
        clipRect.expand(WebCore.toLayoutBoxExtent(filterOutsets()))

        if let paintDirtyRect = paintDirtyRect.value {
            clipRect = WebCore.intersection(clipRect, paintDirtyRect)
        }

        return clipRect
    }
}

// MARK: Painting

// GraphicsContextStateSaver(context, false): saves when asked to, and restores at the end of its scope if it saved.
// SVGPaintOrderLayerItem, while the list is collected.
private struct SVGPaintOrderEntry {
    enum Kind {
        case layered
        case atomic
        case outlineOnly
    }

    var kind: Kind
    var renderer: WebCore.RenderElement
    var layer: WebCore.RenderLayer?
    var zIndex: Int32
    var accumulatedAncestorOffset: WebCore.LayoutSize

    init(
        kind: Kind,
        renderer: WebCore.RenderElement,
        layer: WebCore.RenderLayer?,
        zIndex: Int32,
        accumulatedAncestorOffset: WebCore.LayoutSize
    ) {
        self.kind = kind
        self.renderer = renderer
        self.layer = layer
        self.zIndex = zIndex
        self.accumulatedAncestorOffset = accumulatedAncestorOffset
    }

    init(atomic renderer: WebCore.RenderElement, _ ancestorOffset: WebCore.LayoutSize) {
        self.init(kind: .atomic, renderer: renderer, layer: nil, zIndex: 0, accumulatedAncestorOffset: ancestorOffset)
    }
}

// TransformPaintScope: what its destructor restores.
struct RenderLayerTransformPaintScope {
    var savedTransform: Bool
}

// Concatenates the transform onto the context and maps the painting info's dirty rect back through it.
private func beginTransformPaintScope(
    _ context: WebCore.LentGraphicsContext,
    _ transformedPaintingInfo: inout WebCore.RenderLayer.LayerPaintingInfo,
    _ transform: WebCore.TransformationMatrix,
    _ deviceScaleFactor: Float,
    _ adjustedSubpixelOffset: WebCore.LayoutSize,
    _ newRootLayer: WebCore.RenderLayer?,
    _ stateSavedByCaller: WebCore.StateSavedByCaller
) -> RenderLayerTransformPaintScope {
    let affineTransform = transform.toAffineTransform()
    let savedTransform = stateSavedByCaller == .No
    if savedTransform {
        context.saveTransform()
    }
    let paintDirtyRect = transformedPaintingInfo.paintDirtyRect
    context.concatCTM(affineTransform)

    if let regionContext = transformedPaintingInfo.regionContext() {
        regionContext.pushTransform(affineTransform)
    }

    if let newRootLayer {
        transformedPaintingInfo.setRootLayer(newRootLayer)
    }

    if !transformedPaintingInfo.paintDirtyRect.isInfinite() {
        // Map the dirty rect back through the inverse transform. For a 2D affine transform (the
        // common SVG case, e.g. translate/rotate/scale) invert the 2x3 AffineTransform we
        // already computed rather than doing a full 4x4 TransformationMatrix inverse per paint.
        // TransformationMatrix maps a LayoutRect to the LayoutRect enclosing the result.
        let mappedDirtyRect =
            transform.isAffine()
            ? (affineTransform.inverse().value ?? WebCore.AffineTransform()).mapRect(floatRect(paintDirtyRect))
            : floatRect((transform.inverse().value ?? WebCore.TransformationMatrix()).mapRect(paintDirtyRect))
        transformedPaintingInfo.paintDirtyRect = WebCore.LayoutRect(WebCore.encloseRectToDevicePixels(mappedDirtyRect, deviceScaleFactor))
    }

    transformedPaintingInfo.subpixelOffset = adjustedSubpixelOffset
    return RenderLayerTransformPaintScope(savedTransform: savedTransform)
}

private func endTransformPaintScope(
    _ context: WebCore.LentGraphicsContext,
    _ transformedPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
    _ scope: RenderLayerTransformPaintScope
) {
    if let regionContext = transformedPaintingInfo.regionContext() {
        regionContext.popTransform()
    }

    if scope.savedTransform {
        // Fails if the painting inside the scope left a save(), a transparency layer or a saveTransform() open.
        let restored = context.restoreTransform()
        assert(restored)
    }
}

struct RenderLayerGraphicsContextStateSaver {
    var saved = false

    mutating func save(_ context: WebCore.LentGraphicsContext) {
        assert(!saved)
        context.save()
        saved = true
    }

    func end(_ context: WebCore.LentGraphicsContext) {
        if saved {
            context.restore()
        }
    }
}

// RegionContextStateSaver: pops the clip it pushed at the end of its scope.
struct RenderLayerRegionContextStateSaver {
    let regionContext: WebCore.RegionContext?
    var pushedClip = false

    init(_ regionContext: WebCore.RegionContext?) {
        self.regionContext = regionContext
    }

    mutating func pushClip(_ clipRect: WebCore.IntRect) {
        assert(!pushedClip)
        regionContext?.pushClip(clipRect)
        pushedClip = true
    }

    func end() {
        if pushedClip {
            regionContext?.popClip()
        }
    }
}

private func isEventRegionContext(_ regionContext: WebCore.RegionContext?) -> Bool {
    regionContext?.isEventRegionContext() ?? false
}

private func isAccessibilityRegionContext(_ regionContext: WebCore.RegionContext?) -> Bool {
    regionContext?.isAccessibilityRegionContext() ?? false
}

private let paintBehaviorFlagsToCopyForLayerContents: WebCore.RenderLayer.PaintBehaviors = {
    var flags = WebCore.RenderLayer.PaintBehaviors(.FlattenCompositingLayers)
    flags.add(WebCore.RenderLayer.PaintBehaviors(.Snapshotting))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.DontShowVisitedLinks))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.ExcludeSelection))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.ExcludeReplacedContentExceptForIFrames))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.ExcludeText))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.FixedAndStickyLayersOnly))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.DrawsHDRContent))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.IncludeDocumentMarkers))
    return flags
}()

private let paintBehaviorFlagsToCopyForForeground: WebCore.RenderLayer.PaintBehaviors = {
    var flags = WebCore.RenderLayer.PaintBehaviors(.ExcludeSelection)
    flags.add(WebCore.RenderLayer.PaintBehaviors(.Snapshotting))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.DefaultAsynchronousImageDecode))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.CompositedOverflowScrollContent))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.ForceSynchronousImageDecode))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.ExcludeReplacedContentExceptForIFrames))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.ExcludeText))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.FixedAndStickyLayersOnly))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.DontShowVisitedLinks))
    flags.add(WebCore.RenderLayer.PaintBehaviors(.DrawsHDRContent))
    return flags
}()

private func isSameLayoutRect(_ a: WebCore.LayoutRect, _ b: WebCore.LayoutRect) -> Bool {
    a.x().rawValue() == b.x().rawValue() && a.y().rawValue() == b.y().rawValue() && a.width().rawValue() == b.width().rawValue()
        && a.height().rawValue() == b.height().rawValue()
}

private func paintBehaviorIntersection(
    _ a: WebCore.RenderLayer.PaintBehaviors,
    _ b: WebCore.RenderLayer.PaintBehaviors
) -> WebCore.RenderLayer.PaintBehaviors {
    WebCore.RenderLayer.PaintBehaviors.fromRaw(a.toRaw() & b.toRaw())
}

private func clipRectForTransparencyLayer(
    _ rect: WebCore.LayoutRect,
    _ renderer: WebCore.RenderLayerModelObject,
    _ context: WebCore.LentGraphicsContext
) -> WebCore.FloatRect {
    if WebCore.rendererNeedsPixelSnapping(renderer) {
        return WebCore.snapRectToDevicePixels(rect, renderer.document().deviceScaleFactor())
    }

    if !renderer.hasMask() && !renderer.hasClipPath() {
        return floatRect(rect)
    }

    // RenderSVGResourceMasker sizes and draws its mask image over enclosingIntRect() of the mask
    // content bounds (enclosingIntRect(absoluteTransform.mapRect(decoratedBounds))) - we have to
    // perform the clip for the transparency layer in the same way to avoid losing edge pixels.
    let absoluteTransform = context.getCTMIncludingDeviceScale()
    if let inverseTransform = absoluteTransform.inverse().value {
        return inverseTransform.mapRect(WebCore.FloatRect(WebCore.enclosingIntRect(absoluteTransform.mapRect(floatRect(rect)))))
    }
    return floatRect(rect)
}

extension WebCore.RenderLayer {
    // MARK: Painting: clips

    @cxx
    @implementation
    public func clipToRectNeedsSave(_ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo, _ clipRect: WebCore.ClipRect) -> Bool {
        clipToRectNeedsSave(info: paintingInfo, clipRect)
    }

    func clipToRectNeedsSave(info paintingInfo: WebCore.RenderLayer.LayerPaintingInfo, _ clipRect: WebCore.ClipRect) -> Bool {
        let needsClipping = !clipRect.isInfinite() && !isSameLayoutRect(clipRect.rectValue(), paintingInfo.paintDirtyRect)
        return needsClipping || clipRect.affectedByRadius()
    }

    @cxx
    @implementation
    public func clipToRectAfterSave(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ clipRect: WebCore.ClipRect,
        _ rule: WebCore.BorderRadiusClippingRule
    ) -> WebCore.RenderLayer.OptionalIntRect {
        clipToRectAfterSave(context: context, paintingInfo, paintBehavior, clipRect, rule)
    }

    func clipToRectAfterSave(
        context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ clipRect: WebCore.ClipRect,
        _ rule: WebCore.BorderRadiusClippingRule
    ) -> WebCore.RenderLayer.OptionalIntRect {
        var regionClip = WebCore.RenderLayer.OptionalIntRect()
        let needsClipping = !clipRect.isInfinite() && !isSameLayoutRect(clipRect.rectValue(), paintingInfo.paintDirtyRect)
        if needsClipping {
            var adjustedClipRect = clipRect.rectValue()
            adjustedClipRect.move(paintingInfo.subpixelOffset)
            let snappedClipRect = WebCore.snapRectToDevicePixelsIfNeeded(adjustedClipRect, renderer())
            context.clip(snappedClipRect)
            regionClip = WebCore.RenderLayer.OptionalIntRect(WebCore.enclosingIntRect(snappedClipRect))
        }

        if clipRect.affectedByRadius() {
            applyAncestorClippingForBorderRadius(context: context, paintingInfo, paintBehavior, rule)
        }
        return regionClip
    }

    // The clip the state savers undo at the end of the caller's scope. The region clip is pushed after the
    // border radius clips, which touch only the graphics context.
    func clipToRect(
        _ context: WebCore.LentGraphicsContext,
        _ stateSaver: inout RenderLayerGraphicsContextStateSaver,
        _ regionContextStateSaver: inout RenderLayerRegionContextStateSaver,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ clipRect: WebCore.ClipRect,
        _ rule: WebCore.BorderRadiusClippingRule = WebCore.IncludeSelfForBorderRadius
    ) {
        if clipToRectNeedsSave(info: paintingInfo, clipRect) {
            stateSaver.save(context)
        }
        if let regionClip = clipToRectAfterSave(context: context, paintingInfo, paintBehavior, clipRect, rule).value {
            regionContextStateSaver.pushClip(regionClip)
        }
    }

    @cxx
    @implementation
    public func applyAncestorClippingForBorderRadius(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ rule: WebCore.BorderRadiusClippingRule
    ) {
        applyAncestorClippingForBorderRadius(context: context, paintingInfo, paintBehavior, rule)
    }

    func applyAncestorClippingForBorderRadius(
        context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ rule: WebCore.BorderRadiusClippingRule
    ) {
        let snappingScaleFactor = renderer().document().pixelSnappingScaleFactor()

        // If the clip rect has been tainted by a border radius, then we have to walk up our layer chain applying the clips from
        // any layers with overflow. The condition for being able to apply these clips is that the overflow object be in our
        // containing block chain so we check that also.
        var current: WebCore.RenderLayer? = rule == WebCore.IncludeSelfForBorderRadius ? self : parent()
        while let layer = current {
            if paintBehavior.contains(.CompositedOverflowScrollContent) && layer.usesCompositedScrolling() {
                break
            }

            let layerRenderer = layer.renderer()
            if layerRenderer.hasNonVisibleOverflow() && layerRenderer[.Style].hasBorderRadius()
                && ancestorLayerIsInContainingBlockChain(layer, nil)
            {
                var adjustedClipRect = WebCore.LayoutRect(
                    WebCore.toLayoutPoint(layer.offsetFromAncestor(paintingInfo.rootLayer(), WebCore.RenderLayer.AdjustForColumns)),
                    layer.rendererBorderBoxRect().size()
                )
                adjustedClipRect.move(paintingInfo.subpixelOffset)
                WebCore.RenderLayer.clipToInnerBorderShape(
                    context,
                    layer,
                    adjustedClipRect,
                    paintingInfo.paintDirtyRect,
                    snappingScaleFactor
                )
            }

            if isSameRenderLayer(layer, paintingInfo.rootLayer()) {
                break
            }
            current = layer.parent()
        }
    }

    // MARK: Painting: transparency

    func transparentPaintingAncestor(_ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo) -> WebCore.RenderLayer? {
        if isSameRenderLayer(self, paintingInfo.rootLayer()) || isComposited() || paintsIntoProvidedBacking() {
            return nil
        }
        var current = parent()
        while let ancestor = current {
            if ancestor.isStackingContext() {
                if ancestor.isComposited() || ancestor.paintsIntoProvidedBacking() {
                    return nil
                }
                if ancestor.isTransparent() {
                    return ancestor
                }
            }
            if isSameRenderLayer(ancestor, paintingInfo.rootLayer()) {
                return nil
            }
            current = ancestor.parent()
        }
        return nil
    }

    func beginTransparencyLayers(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ dirtyRect: WebCore.LayoutRect
    ) {
        if context.paintingDisabled() || (paintsWithTransparency(paintingInfo.paintBehavior) && m_usedTransparency) {
            return
        }

        if let ancestor = transparentPaintingAncestor(paintingInfo) {
            ancestor.beginTransparencyLayers(context, paintingInfo, dirtyRect)
        }

        if paintsWithTransparency(paintingInfo.paintBehavior) {
            assert(isStackingContext())
            m_usedTransparency = true
            let layerRenderer = renderer()
            if canPaintTransparencyWithSetOpacity() {
                m_savedAlphaForTransparency = WebCore.RenderLayer.OptionalFloat(context.alpha())
                context.setAlpha(context.alpha() * opacityForPainting(paintingInfo.paintBehavior))
                return
            }
            context.save()
            var adjustedClipRect = transparencyClipBox(
                paintingInfo.rootLayer(),
                WebCore.PaintingTransparencyClipBox,
                WebCore.RootOfTransparencyClipBox,
                paintingInfo.paintBehavior,
                WebCore.RenderLayer.OptionalLayoutRect(dirtyRect)
            )
            adjustedClipRect.move(paintingInfo.subpixelOffset)
            context.clip(clipRectForTransparencyLayer(adjustedClipRect, layerRenderer, context))

            let usesCompositeOperation = hasBlendMode() && !blendModeAppliesToSVGRootContentsOnly()
            if usesCompositeOperation {
                context.setCompositeOperation(context.compositeOperation(), blendMode())
            }

            context.beginTransparencyLayer(opacityForPainting(paintingInfo.paintBehavior))

            if usesCompositeOperation {
                context.setCompositeOperation(context.compositeOperation(), .Normal)
            }
        }
    }

    // Ends the transparency layer that beginTransparencyLayers began for this layer.
    func endTransparencyLayers(_ context: WebCore.LentGraphicsContext) {
        if let savedAlpha = m_savedAlphaForTransparency.value {
            context.setAlpha(savedAlpha)
            m_savedAlphaForTransparency = WebCore.RenderLayer.OptionalFloat()
        } else {
            context.endTransparencyLayer()
            context.restore()
        }
        m_usedTransparency = false
    }

    // MARK: Painting: layers

    @cxx
    @implementation
    public func paintLayer(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        paintLayer(context: context, paintingInfo, paintFlags)
    }

    func paintLayer(
        context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        var paintFlags = paintFlags

        func shouldContinuePaint() -> Bool {
            let layerBacking = backing()!
            if layerBacking.paintsIntoWindow() || layerBacking.paintsIntoCompositedAncestor() {
                return true
            }
            if paintFlags.contains(.PaintingReflection) && !has3DTransform() {
                return true
            }
            return renderer().isDocumentElementRenderer() && paintFlags.contains(.PaintingRootBackgroundOnly)
        }

        if paintsIntoProvidedBacking() || (isComposited() && !shouldContinuePaint()) {
            if !context.performingPaintInvalidation() && !paintingInfo.paintBehavior.contains(.FlattenCompositingLayers) {
                return
            }

            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.TemporaryClipRects))
        }

        if viewportConstrainedNotCompositedReason() == WebCore.RenderLayer.NotCompositedForBoundsOutOfView
            && !paintingInfo.paintBehavior.contains(.Snapshotting)
        {
            // Don't paint out-of-view viewport constrained layers (when doing prepainting) because they will never be visible
            // unless their position or viewport size is changed.
            assert(renderer().isFixedPositioned())
            return
        }

        if paintLayerIntoCanvasDrawableRecorder(context, paintingInfo, paintFlags) {
            return
        }

        paintLayerWithEffects(context: context, paintingInfo, paintFlags)
    }

    @cxx
    @implementation
    public func paintLayerWithEffects(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        paintLayerWithEffects(context: context, paintingInfo, paintFlags)
    }

    func paintLayerWithEffects(
        context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        var paintFlags = paintFlags

        // Non self-painting leaf layers don't need to be painted as their renderer() should properly paint itself.
        if !isSelfPaintingLayer() && !hasSelfPaintingLayerDescendant() {
            return
        }

        // Avoid painting all layers if the document is in a state where visual updates aren't allowed.
        // A full repaint will occur in Document::setVisualUpdatesAllowed(bool) if painting is suppressed here.
        if !renderer().document().visualUpdatesAllowed() {
            return
        }

        // If this layer is totally invisible then there is nothing to paint.
        // However, we do want to continue painting for accessibility paints, as we still need accurate
        // geometry for opacity:0 things. It's very common to make form controls "screenreader-only" via
        // CSS, often involving opacity:0, while positioning some other visual-only / mouse-only control in
        // its place. Having the correct geometry is vital for ensuring VoiceOver can still press these
        // controls. We need to paint if we are collecting event regions as well to ensure that elements
        // with opacity:0 are included.
        if opacityForPainting(paintingInfo.paintBehavior) == 0 && !isAccessibilityRegionContext(paintingInfo.regionContext())
            && !paintFlags.contains(.CollectingEventRegion)
        {
            return
        }

        if paintsWithTransparency(paintingInfo.paintBehavior) {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.HaveTransparency))
        }

        // PaintLayerFlag::AppliedTransform is used in RenderReplica, to avoid applying the transform twice.
        if paintsWithTransform(paintingInfo.paintBehavior) && !paintFlags.contains(.AppliedTransform) {
            let layerTransform = renderableTransform(paintingInfo.paintBehavior)
            // If the transform can't be inverted, then don't paint anything.
            if !layerTransform.isInvertible() {
                return
            }

            // If we have a transparency layer enclosing us and we are the root of a transform, then we need to establish the transparency
            // layer from the parent now, assuming there is a parent
            if paintFlags.contains(.HaveTransparency) {
                if !isSameRenderLayer(self, paintingInfo.rootLayer()), let parent = parent() {
                    parent.beginTransparencyLayers(context, paintingInfo, paintingInfo.paintDirtyRect)
                } else {
                    beginTransparencyLayers(context, paintingInfo, paintingInfo.paintDirtyRect)
                }
            }

            if enclosingPaginationLayer(WebCore.RenderLayer.ExcludeCompositedPaginatedLayers) != nil {
                paintTransformedLayerIntoFragments(context, paintingInfo, paintFlags)
                return
            }

            // Make sure the parent's clip rects have been calculated.
            var clipRect = WebCore.ClipRect(paintingInfo.paintDirtyRect)
            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(paintingInfo.regionContext())
            if let parent = parent() {
                var options =
                    paintFlags.contains(.PaintingOverflowContents)
                    ? WebCore.RenderLayer.ClipRectsOptions() : WebCore.RenderLayer.clipRectDefaultOptionsForSwift()
                if shouldHaveFiltersForPainting(context: context, paintFlags, paintingInfo.paintBehavior) {
                    options.add(WebCore.RenderLayer.ClipRectsOptions(.OutsideFilter))
                }
                if paintFlags.contains(.TemporaryClipRects) {
                    options.add(WebCore.RenderLayer.ClipRectsOptions(.Temporary))
                }
                clipRect = backgroundClipRect(RenderLayerClipRectsContext(paintingInfo.rootLayer(), WebCore.PaintingClipRects, options))
                clipRect.intersect(paintingInfo.paintDirtyRect)

                var paintBehavior = WebCore.RenderLayer.PaintBehaviors(.Normal)
                if paintFlags.contains(.PaintingOverflowContents) {
                    paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.CompositedOverflowScrollContent))
                }

                // Push the parent coordinate space's clip.
                parent.clipToRect(context, &stateSaver, &regionContextStateSaver, paintingInfo, paintBehavior, clipRect)
            }

            paintLayerByApplyingTransform(context, paintingInfo, paintFlags, WebCore.LayoutSize())
            regionContextStateSaver.end()
            stateSaver.end(context)
            return
        }

        paintLayerContentsAndReflection(context: context, paintingInfo, paintFlags)
    }

    @cxx
    @implementation
    public func paintLayerContentsAndReflection(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        paintLayerContentsAndReflection(context: context, paintingInfo, paintFlags)
    }

    func paintLayerContentsAndReflection(
        context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        assert(isSelfPaintingLayer() || hasSelfPaintingLayerDescendant())

        var localPaintFlags = paintFlags
        localPaintFlags.remove(WebCore.RenderLayer.PaintLayerFlags(.AppliedTransform))
        localPaintFlags.remove(WebCore.RenderLayer.PaintLayerFlags(.PaintingOverflowContentsRoot))

        // Paint the reflection first if we have one.
        if let reflectionLayer = reflectionLayer(), !m_paintingInsideReflection {
            // Mark that we are now inside replica painting.
            m_paintingInsideReflection = true
            var reflectionFlags = localPaintFlags
            reflectionFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingReflection))
            reflectionLayer.paintLayer(context: context, paintingInfo, reflectionFlags)
            m_paintingInsideReflection = false
        }

        localPaintFlags.add(WebCore.RenderLayer.paintLayerPaintingCompositingAllPhasesFlags())
        paintLayerContents(context: context, paintingInfo, localPaintFlags, WebCore.RenderLayer.OptionalPaintOrderItemRange())
    }

    func paintLayerByApplyingTransform(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ translationOffset: WebCore.LayoutSize
    ) {
        // This involves subtracting out the position of the layer in our current coordinate space, but preserving
        // the accumulated error for sub-pixel layout.
        // Note: The pixel-snapping logic is disabled for the whole SVG render tree, except the outermost <svg>.
        let layerRenderer = renderer()
        let snappingScaleFactor = layerRenderer.document().pixelSnappingScaleFactor()
        let offsetFromParent = offsetFromAncestor(paintingInfo.rootLayer(), WebCore.RenderLayer.DontAdjustForColumns) + translationOffset
        var transform = renderableTransform(paintingInfo.paintBehavior)
        // Add the subpixel accumulation to the current layer's offset so that we can always snap the translateRight value to where the
        // renderer() is supposed to be painting.
        let offsetForThisLayer = offsetFromParent + paintingInfo.subpixelOffset
        let needsPixelSnapping = WebCore.rendererNeedsPixelSnapping(layerRenderer)
        let alignedOffsetForThisLayer =
            needsPixelSnapping
            ? WebCore.toFloatSize(WebCore.roundPointToDevicePixels(WebCore.toLayoutPoint(offsetForThisLayer), snappingScaleFactor))
            : WebCore.FloatSize(offsetForThisLayer.width().toFloat(), offsetForThisLayer.height().toFloat())
        // We handle accumulated subpixels through nested layers here. Since the context gets translated to device pixels,
        // all we need to do is add the delta to the accumulated pixels coming from ancestor layers.
        // Translate the graphics context to the snapping position to avoid off-device-pixel positing.
        transform.translateRightBy(Double(alignedOffsetForThisLayer.width()), Double(alignedOffsetForThisLayer.height()))
        // Only propagate the subpixel offsets to the descendant layers, if we're not the root
        // of a SVG subtree, where no pixel snapping is applied -- only the outermost <svg> layer
        // is pixel-snapped "as whole", if it's part of a compound document, e.g. inline SVG in HTML.
        var adjustedSubpixelOffset = WebCore.LayoutSize()
        if needsPixelSnapping && !layerRenderer.isRenderSVGRoot() {
            adjustedSubpixelOffset = offsetForThisLayer - WebCore.LayoutSize(alignedOffsetForThisLayer)
        }

        var localPaintFlags = paintFlags
        localPaintFlags.remove(WebCore.RenderLayer.PaintLayerFlags(.PaintingOverflowContents))
        var transformedPaintingInfo = paintingInfo
        let scope = beginTransformPaintScope(
            context,
            &transformedPaintingInfo,
            transform,
            snappingScaleFactor,
            adjustedSubpixelOffset,
            self,
            .No
        )
        paintLayerContentsAndReflection(context: context, transformedPaintingInfo, localPaintFlags)
        endTransformPaintScope(context, transformedPaintingInfo, scope)
    }

    func paintTransformedLayerIntoFragments(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        var enclosingPaginationFragments = WebCore.LayerFragments()
        var offsetOfPaginationLayerFromRoot = WebCore.LayoutSize()
        let paginatedLayer = enclosingPaginationLayer(WebCore.RenderLayer.ExcludeCompositedPaginatedLayers)!
        let transformedExtent = transparencyClipBox(
            paginatedLayer,
            WebCore.PaintingTransparencyClipBox,
            WebCore.RootOfTransparencyClipBox,
            paintingInfo.paintBehavior,
            WebCore.RenderLayer.OptionalLayoutRect()
        )

        var clipRectOptions =
            paintFlags.contains(.PaintingOverflowContents)
            ? WebCore.RenderLayer.ClipRectsOptions() : WebCore.RenderLayer.clipRectDefaultOptionsForSwift()
        if shouldHaveFiltersForPainting(context: context, paintFlags, paintingInfo.paintBehavior) {
            clipRectOptions.add(WebCore.RenderLayer.ClipRectsOptions(.OutsideFilter))
        }
        if paintFlags.contains(.TemporaryClipRects) {
            clipRectOptions.add(WebCore.RenderLayer.ClipRectsOptions(.Temporary))
        }
        paginatedLayer.collectFragments(
            into: &enclosingPaginationFragments,
            paintingInfo.rootLayer(),
            paintingInfo.paintDirtyRect,
            WebCore.RenderLayer.ExcludeCompositedPaginatedLayers,
            WebCore.PaintingClipRects,
            clipRectOptions,
            offsetOfPaginationLayerFromRoot,
            WebCore.RenderLayer.OptionalLayoutRect(transformedExtent)
        )

        var index = 0
        while index < Int(enclosingPaginationFragments.size()) {
            let fragment = enclosingPaginationFragments[index]
            index += 1
            // Apply the page/column clip for this fragment, as well as any clips established by layers in between us and
            // the enclosing pagination layer.
            var clipRect = fragment.dirtyBackgroundRect().rectValue()

            // Now compute the clips within a given fragment
            if !isSameRenderLayer(parent(), paginatedLayer) {
                offsetOfPaginationLayerFromRoot = WebCore.toLayoutSize(
                    paginatedLayer.convertToLayerCoords(
                        paintingInfo.rootLayer(),
                        WebCore.toLayoutPoint(offsetOfPaginationLayerFromRoot),
                        WebCore.RenderLayer.DontAdjustForColumns
                    )
                )

                var parentClipRect = backgroundClipRect(
                    RenderLayerClipRectsContext(paginatedLayer, WebCore.PaintingClipRects, clipRectOptions)
                )
                .rectValue()
                parentClipRect.move(fragment.paginationOffset + offsetOfPaginationLayerFromRoot)
                clipRect.intersect(parentClipRect)
            }

            var paintBehavior = WebCore.RenderLayer.PaintBehaviors(.Normal)
            if paintFlags.contains(.PaintingOverflowContents) {
                paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.CompositedOverflowScrollContent))
            }

            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(paintingInfo.regionContext())

            parent()!.clipToRect(context, &stateSaver, &regionContextStateSaver, paintingInfo, paintBehavior, WebCore.ClipRect(clipRect))
            paintLayerByApplyingTransform(context, paintingInfo, paintFlags, fragment.paginationOffset)
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    @cxx
    @implementation
    public func paintList(
        _ list: WebCore.PaintOrderList,
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        paintList(list, context: context, paintingInfo, paintFlags)
    }

    func paintList(
        _ list: WebCore.PaintOrderList,
        context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        if paintOrderListSize(list) == 0 {
            return
        }

        if !hasSelfPaintingLayerDescendant() {
            return
        }

        withLayerListMutationForbidden {
            var index = 0
            while index < paintOrderListSize(list) {
                let childLayer = paintOrderListLayerAt(list, index)
                index += 1
                if paintFlags.contains(.PaintingSkipDescendantViewTransition) {
                    let childRenderer = childLayer.renderer()
                    if childRenderer.effectiveCapturedInViewTransition() {
                        continue
                    }
                    if childRenderer.isViewTransitionPseudo() {
                        continue
                    }
                }
                childLayer.paintLayer(context: context, paintingInfo, paintFlags)
            }
        }
    }

    // MARK: Painting: contents

    @cxx
    @implementation
    public func paintLayerContents(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ svgPaintOrderItemRange: WebCore.RenderLayer.OptionalPaintOrderItemRange
    ) {
        paintLayerContents(context: context, paintingInfo, paintFlags, svgPaintOrderItemRange)
    }

    func paintLayerContents(
        context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ svgPaintOrderItemRange: WebCore.RenderLayer.OptionalPaintOrderItemRange
    ) {
        assert(isSelfPaintingLayer() || hasSelfPaintingLayerDescendant())

        if context.detectingContentfulPaint() && context.contentfulPaintDetected() {
            return
        }

        var localPaintFlags = paintFlags
        localPaintFlags.remove(WebCore.RenderLayer.PaintLayerFlags(.AppliedTransform))

        let layerRenderer = renderer()
        let haveTransparency = localPaintFlags.contains(.HaveTransparency)
        let isPaintingOverlayScrollbars = localPaintFlags.contains(.PaintingOverlayScrollbars)
        let isCollectingEventRegion = localPaintFlags.contains(.CollectingEventRegion)
        let isCollectingAccessibilityRegion = isAccessibilityRegionContext(paintingInfo.regionContext())

        let isSelfPaintingLayer = isSelfPaintingLayer()
        let isInsideSkippedSubtree = layerRenderer.isSkippedContent()

        func shouldSkipNonFixedTopDocumentContent() -> Bool {
            if !paintingInfo.paintBehavior.contains(.FixedAndStickyLayersOnly) {
                return false
            }

            if hasFixedAncestor() || m_hasStickyAncestor {
                return false
            }

            if isViewportConstrained() {
                return false
            }

            if !layerRenderer.frameIsMainFrameForSwift() {
                return false
            }

            return true
        }

        var shouldPaintContent =
            !isInsideSkippedSubtree
            && hasVisibleContentForPainting()
            && isSelfPaintingLayer
            && !isPaintingOverlayScrollbars
            && !isCollectingEventRegion
            && !isCollectingAccessibilityRegion
            && !shouldSkipNonFixedTopDocumentContent()

        func shouldExcludeBasedOnContainingBlock() -> Bool {
            if let rootAsBlock = paintingInfo.subtreePaintRoot()?.asRenderBlock() {
                return !rootAsBlock.isContainingBlockAncestorFor(layerRenderer)
            }
            return false
        }

        if paintingInfo.paintBehavior.contains(.DraggableSnapshot), let subtreePaintRoot = paintingInfo.subtreePaintRoot() {
            if subtreePaintRoot.hasLayer() {
                let subtreeRootLayer = subtreePaintRoot.enclosingLayer()!
                let isLayerInSubtree = isSameRenderLayer(self, subtreeRootLayer) || isDescendantOf(subtreeRootLayer)

                if !isLayerInSubtree
                    || (!WebCore.RenderObject.isSameRenderer(subtreePaintRoot, layerRenderer) && shouldExcludeBasedOnContainingBlock())
                {
                    shouldPaintContent = false
                }
            } else if layerRenderer.isAbsolutelyPositioned() && !WebCore.RenderObject.isSameRenderer(subtreePaintRoot, layerRenderer)
                && shouldExcludeBasedOnContainingBlock()
            {
                shouldPaintContent = false
            }
        }

        if localPaintFlags.contains(.PaintingRootBackgroundOnly) && !layerRenderer.isRenderView()
            && !layerRenderer.isDocumentElementRenderer()
        {
            // If beginTransparencyLayers was called prior to this, ensure the transparency state is cleaned up before returning.
            if haveTransparency && m_usedTransparency && !m_paintingInsideReflection {
                endTransparencyLayers(context)
            }

            return
        }

        updateLayerListsIfNeeded()

        let offsetFromRoot = offsetFromAncestor(paintingInfo.rootLayer(), WebCore.RenderLayer.DontAdjustForColumns)

        // FIXME: We shouldn't have to disable subpixel quantization for overflow clips or subframes once we scroll those
        // things on the scrolling thread.
        var didQuantizeFonts = true
        let needToAdjustSubpixelQuantization = setupFontSubpixelQuantization(context, &didQuantizeFonts)

        // Apply clip-path to context.
        var columnAwareOffsetFromRoot = offsetFromRoot
        if layerRenderer.hasEnclosingFragmentedFlowForSwift()
            && (layerRenderer.hasClipPath() || shouldHaveFiltersForPainting(context: context, paintFlags, paintingInfo.paintBehavior))
        {
            columnAwareOffsetFromRoot = WebCore.toLayoutSize(
                convertToLayerCoords(paintingInfo.rootLayer(), WebCore.LayoutPoint(), WebCore.RenderLayer.AdjustForColumns)
            )
        }

        paintLayerContentsWithClipPath(
            context,
            paintingInfo,
            paintFlags,
            localPaintFlags,
            svgPaintOrderItemRange,
            offsetFromRoot,
            columnAwareOffsetFromRoot,
            shouldPaintContent,
            needToAdjustSubpixelQuantization,
            didQuantizeFonts
        )
    }

    @cxx
    @implementation
    public func paintLayerContentsWithinClipPath(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ localPaintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ svgPaintOrderItemRange: WebCore.RenderLayer.OptionalPaintOrderItemRange,
        _ layerFragments: WebCore.LayerFragmentsView,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ columnAwareOffsetFromRoot: WebCore.LayoutSize,
        _ needsMaskClipping: Bool,
        _ shouldPaintContent: Bool,
        _ needToAdjustSubpixelQuantization: Bool,
        _ didQuantizeFonts: Bool
    ) {
        var localPaintFlags = localPaintFlags
        var shouldPaintContent = shouldPaintContent
        let layerRenderer = renderer()
        let haveTransparency = localPaintFlags.contains(.HaveTransparency)
        let isPaintingCompositedForeground = localPaintFlags.contains(.PaintingCompositingForegroundPhase)
        let isPaintingCompositedBackground = localPaintFlags.contains(.PaintingCompositingBackgroundPhase)
        let isPaintingOverflowContents = localPaintFlags.contains(.PaintingOverflowContents)
        let isCollectingEventRegion = localPaintFlags.contains(.CollectingEventRegion)

        // The clip-path set up a path clip (held until paintLayerContentsWithClipPath returns) or asked for a mask. The mask
        // request comes from the clip-path scope (clip can't be a path) or from setupClipPathIfNeededForSVG (clip-path on
        // a <clipPath> element), which sets the flag.
        let applySVGClippingMask = localPaintFlags.contains(.PaintingSVGClippingMask) || needsMaskClipping
        localPaintFlags.remove(WebCore.RenderLayer.PaintLayerFlags(.PaintingSVGClippingMask))

        let selectionAndBackgroundsOnly = paintingInfo.paintBehavior.contains(.SelectionAndBackgroundsOnly)
        let selectionOnly = paintingInfo.paintBehavior.contains(.SelectionOnly)

        trackPaintFrequency()

        var paintBehavior = paintBehaviorIntersection(paintingInfo.paintBehavior, paintBehaviorFlagsToCopyForLayerContents)
        if localPaintFlags.contains(.PaintingSkipRootBackground) {
            paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.SkipRootBackground))
        } else if localPaintFlags.contains(.PaintingRootBackgroundOnly) {
            paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.RootBackgroundOnly))
        }

        // FIXME: This seems wrong. We should retain the DefaultAsynchronousImageDecode flag for all RenderLayers painted into the root tile
        // cache.
        if paintingInfo.paintBehavior.contains(.DefaultAsynchronousImageDecode) && isRenderViewLayer() {
            paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.DefaultAsynchronousImageDecode))
        }

        if isPaintingOverflowContents {
            paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.CompositedOverflowScrollContent))
        }

        if isCollectingEventRegion {
            paintBehavior = paintBehaviorIntersection(paintBehavior, WebCore.RenderLayer.PaintBehaviors(.CompositedOverflowScrollContent))
            if isPaintingCompositedForeground {
                paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.EventRegionIncludeForeground))
            }
            if isPaintingCompositedBackground {
                paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.EventRegionIncludeBackground))
            }
        }

        // If this layer's renderer is a child of the subtreePaintRoot, we render unconditionally, which
        // is done by passing a nil subtreePaintRoot down to our renderer (as if no subtreePaintRoot was ever set).
        // Otherwise, our renderer tree may or may not contain the subtreePaintRoot root, so we pass that root along
        // so it will be tested against as we descend through the renderers.
        let rendererObject: WebCore.RenderObject = layerRenderer
        var subtreePaintRootForRenderer: WebCore.RenderObject? = nil
        if let subtreePaintRoot = paintingInfo.subtreePaintRoot(), !rendererObject.isDescendantOf(subtreePaintRoot) {
            subtreePaintRootForRenderer = subtreePaintRoot
        }

        do { // Scope for filter-related state changes.
            var backgroundRect = WebCore.ClipRect()

            if shouldHaveFiltersForPainting(context: context, paintFlags, paintBehavior) {
                // When we called collectFragments() last time, paintDirtyRect was reset to represent the filter bounds.
                // Now we need to compute the backgroundRect uncontaminated by filters, in order to clip the filtered result.
                // Note that we also use paintingInfo here, not localPaintingInfo which filters also contaminated.
                var filterLayerFragments = WebCore.LayerFragments()
                var clipRectOptions =
                    isPaintingOverflowContents
                    ? WebCore.RenderLayer.ClipRectsOptions() : WebCore.RenderLayer.clipRectDefaultOptionsForSwift()
                clipRectOptions.add(WebCore.RenderLayer.ClipRectsOptions(.OutsideFilter))
                if localPaintFlags.contains(.TemporaryClipRects) {
                    clipRectOptions.add(WebCore.RenderLayer.ClipRectsOptions(.Temporary))
                }
                collectFragments(
                    into: &filterLayerFragments,
                    paintingInfo.rootLayer(),
                    paintingInfo.paintDirtyRect,
                    WebCore.RenderLayer.ExcludeCompositedPaginatedLayers,
                    WebCore.PaintingClipRects,
                    clipRectOptions,
                    offsetFromRoot
                )
                updatePaintingInfoForFragments(&filterLayerFragments, paintingInfo, localPaintFlags, shouldPaintContent, offsetFromRoot)

                // FIXME: Handle more than one fragment.
                backgroundRect = filterLayerFragments.isEmpty() ? WebCore.ClipRect() : filterLayerFragments[0].backgroundRect()

                if haveTransparency {
                    // If we have a filter and transparency, we have to eagerly start a transparency layer here, rather than risk a child
                    // layer lazily starts one with the wrong context.
                    beginTransparencyLayers(context, paintingInfo, paintingInfo.paintDirtyRect)
                }
            }

            // The outermost <svg> is a replaced element in the CSS box tree, so its filter is set up in
            // CSS box coordinates (see RenderLayerFilters::beginFilterEffect) and none of the SVG user
            // space corrections in this scope apply to it.
            let filtersInSVGUserSpace = layerRenderer.isSVGLayerAwareRenderer() && !layerRenderer.isRenderSVGRoot()

            // Position the filter buffer and composite its result at the element's
            // nominalSVGLayoutLocation, independent of intermediate force-layers that perturb offsetFromRoot.
            var svgFilterOffset = columnAwareOffsetFromRoot
            if layerRenderer.isSVGLayerAwareRenderer() && shouldHaveFiltersForPainting(context: context, paintFlags, paintBehavior) {
                let svgRendererObject: WebCore.RenderObject = layerRenderer
                if svgRendererObject.asRenderSVGModelObject() != nil || svgRendererObject.isRenderSVGBlock() {
                    svgFilterOffset = WebCore.toLayoutSize(layerRenderer.nominalSVGLayoutLocation())
                }
            }

            // The filter buffer sits at the nominal SVG position (svgFilterOffset), but its result
            // must composite where the unfiltered content lands, at the offset from rootLayer, so
            // translate by the delta. This is nonzero only when the position is baked into the CTM (the
            // element is its own rootLayer, or a force-created ancestor layer baked it in). In the plain
            // non-layer case offsetFromRoot equals the nominal position and isZero() skips.
            let svgFilterCompensation = filtersInSVGUserSpace ? columnAwareOffsetFromRoot - svgFilterOffset : WebCore.LayoutSize()
            shouldPaintContent = paintLayerContentsWithFilters(
                context,
                paintingInfo,
                localPaintFlags,
                svgPaintOrderItemRange,
                layerFragments,
                &paintBehavior,
                offsetFromRoot,
                columnAwareOffsetFromRoot,
                svgFilterOffset,
                svgFilterCompensation,
                backgroundRect,
                shouldPaintContent,
                subtreePaintRootForRenderer
            )
        }

        func paintMasks(_ layerFragments: WebCore.LayerFragments) {
            if shouldPaintMask(paintingInfo.paintBehavior, localPaintFlags) {
                // Paint the mask for the fragments.
                paintMaskForFragments(layerFragments, context, paintingInfo, paintBehavior, subtreePaintRootForRenderer)
            }

            if applySVGClippingMask
                || (!paintFlags.contains(.PaintingCompositingMaskPhase) && paintFlags.contains(.PaintingCompositingClipPathPhase))
            {
                // Re-use paintChildClippingMaskForFragments to paint black for the compositing clipping mask.
                paintChildClippingMaskForFragments(layerFragments, context, paintingInfo, paintBehavior, subtreePaintRootForRenderer)
            }

            if localPaintFlags.contains(.PaintingChildClippingMaskPhase) {
                // Paint the border radius mask for the fragments.
                paintChildClippingMaskForFragments(layerFragments, context, paintingInfo, paintBehavior, subtreePaintRootForRenderer)
            }
        }

        if shouldPaintContent && !(selectionOnly || selectionAndBackgroundsOnly) {
            paintMasks(layerFragments.pointee)
        }

        // End our transparency layer
        if haveTransparency && m_usedTransparency && !m_paintingInsideReflection {
            endTransparencyLayers(context)
        }

        // Re-set this to whatever it was before we painted the layer.
        if needToAdjustSubpixelQuantization {
            context.setShouldSubpixelQuantizeFonts(didQuantizeFonts)
        }
    }

    @cxx
    @implementation
    public func paintLayerContentsWithinFilters(
        _ context: WebCore.LentGraphicsContext,
        _ currentContext: WebCore.LentGraphicsContext,
        _ hasFilterContext: Bool,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ localPaintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ svgPaintOrderItemRange: WebCore.RenderLayer.OptionalPaintOrderItemRange,
        _ layerFragments: WebCore.LayerFragmentsView,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ columnAwareOffsetFromRoot: WebCore.LayoutSize,
        _ svgFilterOffset: WebCore.LayoutSize,
        _ shouldPaintContent: Bool,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) -> Bool {
        paintLayerContentsWithinFilters(
            context: context,
            currentContext,
            hasFilterContext,
            paintingInfo,
            localPaintingInfo,
            localPaintFlags,
            svgPaintOrderItemRange,
            &layerFragments.pointee,
            paintBehavior,
            offsetFromRoot,
            columnAwareOffsetFromRoot,
            svgFilterOffset,
            shouldPaintContent,
            subtreePaintRootForRenderer
        )
    }

    func paintLayerContentsWithinFilters(
        context: WebCore.LentGraphicsContext,
        _ currentContext: WebCore.LentGraphicsContext,
        _ hasFilterContext: Bool,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ localPaintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ svgPaintOrderItemRange: WebCore.RenderLayer.OptionalPaintOrderItemRange,
        _ layerFragments: inout WebCore.LayerFragments,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ offsetFromRoot: WebCore.LayoutSize,
        _ columnAwareOffsetFromRoot: WebCore.LayoutSize,
        _ svgFilterOffset: WebCore.LayoutSize,
        _ shouldPaintContent: Bool,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) -> Bool {
        var localPaintingInfo = localPaintingInfo
        var shouldPaintContent = shouldPaintContent
        let layerRenderer = renderer()
        let haveTransparency = localPaintFlags.contains(.HaveTransparency)
        let isPaintingOverlayScrollbars = localPaintFlags.contains(.PaintingOverlayScrollbars)
        var isPaintingCompositedForeground = localPaintFlags.contains(.PaintingCompositingForegroundPhase)
        let isPaintingCompositedBackground = localPaintFlags.contains(.PaintingCompositingBackgroundPhase)
        // This SVG container layer is painting an overlay paint-order segment, so it paints only its
        // flat-list slice. The container's own foreground and outline belong to the primary segment (the primary layer).
        let isPaintingOverlaySVGSegment =
            isSameRenderLayer(paintingInfo.rootLayer(), self) && WebCore.RenderLayer.paintOrderItemRangeBegin(svgPaintOrderItemRange) != 0
        let isPaintingOverflowContents = localPaintFlags.contains(.PaintingOverflowContents)
        let isCollectingEventRegion = localPaintFlags.contains(.CollectingEventRegion)
        let isCollectingAccessibilityRegion = isAccessibilityRegionContext(paintingInfo.regionContext())
        let isCollectingAXCustomColorBackdrops = isCollectingAXCustomColorBackdrops(paintingInfo)
        let isSelfPaintingLayer = isSelfPaintingLayer()
        let isInsideSkippedSubtree = layerRenderer.isSkippedContent()
        let selectionOnly = paintingInfo.paintBehavior.contains(.SelectionOnly)
        let shouldPaintNegativeZIndexChildren: Bool
        if localPaintFlags.contains(.PaintingOverflowContainer) {
            shouldPaintNegativeZIndexChildren = false
        } else if localPaintFlags.contains(.PaintingOverflowContents) {
            // Overflow contents has the "PaintingCompositingForegroundPhase" phase,
            // but we need to paint negative z-index layers here so they scroll with the content.
            shouldPaintNegativeZIndexChildren = true
        } else {
            shouldPaintNegativeZIndexChildren = isPaintingCompositedBackground
        }

        let filtersInSVGUserSpace = layerRenderer.isSVGLayerAwareRenderer() && !layerRenderer.isRenderSVGRoot()

        var svgFilterContentOffset = svgFilterOffset
        if hasFilterContext && filtersInSVGUserSpace {
            svgFilterContentOffset =
                svgFilterContentOffset + (layerRenderer.objectBoundingBoxLocation() - layerRenderer.nominalSVGLayoutLocation())
        }

        // A failed filter does not paint its descendants, so a rootLayer with hasFilter() set up a buffer.
        var rootLayerShiftedFilterBuffer = false
        if let currentRootLayer = localPaintingInfo.rootLayer(), !isSameRenderLayer(currentRootLayer, self) {
            let currentRootRenderer = currentRootLayer.renderer()
            rootLayerShiftedFilterBuffer =
                currentRootLayer.hasFilter() && currentRootRenderer.isSVGLayerAwareRenderer() && !currentRootRenderer.isRenderSVGRoot()
        }

        // This applies to this layer's immediate child layers only, and a nested filter re-derives its own.
        var svgFilterChildLayerCorrection = WebCore.LayoutSize()
        if hasFilterContext && filtersInSVGUserSpace {
            svgFilterChildLayerCorrection = rootLayerShiftedFilterBuffer ? svgFilterOffset : svgFilterOffset - columnAwareOffsetFromRoot
        }

        // Per the SVG spec a referenced but unappliable filter (missing reference, empty filter)
        // produces transparent black, so the element is not rendered. CSS Filter Effects instead
        // treats a failed filter as no effect (painted normally), so SVG renderers follow the SVG
        // rule here.
        let shouldFailedFilterProduceTransparentBlackForSVG = isSVGLayer()
        var hasFailedFilterForSVG =
            shouldFailedFilterProduceTransparentBlackForSVG && !hasFilterContext
            && shouldHaveFiltersForPainting(context: context, localPaintFlags, localPaintingInfo.paintBehavior)
        if hasFailedFilterForSVG {
            hasFailedFilterForSVG = self.hasFailedFilterForSVG()
        }

        if hasFilterContext {
            localPaintingInfo.paintBehavior.add(WebCore.RenderLayer.PaintBehaviors(.DontShowVisitedLinks))
        } else if hasFailedFilterForSVG {
            shouldPaintContent = false
            isPaintingCompositedForeground = false
        }

        let shouldPaintOutline: Bool
        if !isSelfPaintingLayer {
            shouldPaintOutline = false
        } else if !shouldPaintContent {
            shouldPaintOutline = false
        } else if isPaintingOverlayScrollbars || isCollectingEventRegion || isCollectingAccessibilityRegion {
            shouldPaintOutline = false
        } else if localPaintFlags.contains(.PaintingOverflowContentsRoot) {
            // For the current layer, the outline has been painted by the primary GraphicsLayer.
            shouldPaintOutline = false
        } else if isPaintingOverlaySVGSegment {
            // An overlay SVG paint-order segment paints only its child slice. The container's own
            // outline is painted once by the primary graphics layer (the primary segment).
            shouldPaintOutline = false
        } else if localPaintFlags.contains(.PaintingOverflowContainer) {
            // Paint outlines in the background phase for a scroll container so that they don't scroll with the content.
            // FIXME: inset outlines will have the wrong z-ordering with scrolled content. See also webkit.org/b/249457.
            shouldPaintOutline = isPaintingCompositedBackground
        } else {
            shouldPaintOutline = isPaintingCompositedForeground
        }

        if isSelfPaintingLayer {
            performOverlapTests(localPaintingInfo)
        }

        let paintDirtyRect = localPaintingInfo.paintDirtyRect
        let needsFragments =
            shouldPaintContent || shouldPaintOutline || isPaintingOverlayScrollbars || isCollectingEventRegion
            || isCollectingAccessibilityRegion || isCollectingAXCustomColorBackdrops
        if needsFragments {
            // Collect the fragments. This will compute the clip rectangles and paint offsets for each layer fragment, as well as whether or
            // not the content of each
            // fragment should paint.
            var clipRectOptions =
                isPaintingOverflowContents ? WebCore.RenderLayer.ClipRectsOptions() : WebCore.RenderLayer.clipRectDefaultOptionsForSwift()
            if localPaintFlags.contains(.TemporaryClipRects) {
                clipRectOptions.add(WebCore.RenderLayer.ClipRectsOptions(.Temporary))
            }
            // Inside a filter buffer, collect fragments at svgFilterContentOffset (computed above) so
            // in-buffer content matches the buffer's transform-aware coordinate system.
            let fragmentOffset = hasFilterContext ? svgFilterContentOffset : offsetFromRoot
            collectFragments(
                into: &layerFragments,
                localPaintingInfo.rootLayer(),
                paintDirtyRect,
                WebCore.RenderLayer.ExcludeCompositedPaginatedLayers,
                WebCore.PaintingClipRects,
                clipRectOptions,
                fragmentOffset
            )
            updatePaintingInfoForFragments(&layerFragments, localPaintingInfo, localPaintFlags, shouldPaintContent, fragmentOffset)
        }

        if isPaintingCompositedBackground {
            // Paint only the backgrounds for all of the fragments of the layer.
            if shouldPaintContent && !selectionOnly {
                paintBackgroundForFragments(
                    layerFragments,
                    currentContext,
                    context,
                    paintingInfo.paintDirtyRect,
                    haveTransparency,
                    localPaintingInfo,
                    paintBehavior,
                    subtreePaintRootForRenderer
                )
            }
        }

        if shouldPaintNegativeZIndexChildren {
            if isSVGLayer() {
                paintNegativeZOrderChildrenForSVG(currentContext, localPaintingInfo, localPaintFlags)
            } else {
                // Now walk the sorted list of children with negative z-indices.
                paintList(.Negative, context: currentContext, localPaintingInfo, localPaintFlags)
            }
        }

        if isPaintingCompositedForeground && shouldPaintContent && !isPaintingOverlaySVGSegment {
            paintForegroundForFragments(
                layerFragments,
                currentContext,
                context,
                paintingInfo.paintDirtyRect,
                haveTransparency,
                localPaintingInfo,
                paintBehavior,
                subtreePaintRootForRenderer
            )
        }

        if isCollectingEventRegion && !isInsideSkippedSubtree {
            collectEventRegionForFragments(layerFragments, currentContext, localPaintingInfo, paintBehavior)
        }

        if isCollectingAccessibilityRegion {
            collectAccessibilityRegionsForFragments(layerFragments, currentContext, localPaintingInfo, paintBehavior)
        }

        if isCollectingAXCustomColorBackdrops && !isInsideSkippedSubtree {
            collectAXCustomColorBackdropsForFragments(layerFragments, currentContext, localPaintingInfo, paintBehavior)
        }

        if shouldPaintOutline {
            paintOutlineForFragments(layerFragments, currentContext, localPaintingInfo, paintBehavior, subtreePaintRootForRenderer)
        }

        if isPaintingCompositedForeground {
            if isSVGLayer() {
                paintForegroundChildrenForSVG(
                    currentContext,
                    paintingInfo,
                    localPaintingInfo,
                    localPaintFlags,
                    layerFragments,
                    paintBehavior,
                    subtreePaintRootForRenderer,
                    svgPaintOrderItemRange,
                    svgFilterChildLayerCorrection
                )
            } else {
                // Paint any child layers that have overflow.
                paintList(.NormalFlow, context: currentContext, paintingInfo, localPaintFlags)

                // Now walk the sorted list of children with positive z-indices.
                paintList(.Positive, context: currentContext, localPaintingInfo, localPaintFlags)
            }
        }

        if let scrollableArea = scrollableArea() {
            if isPaintingOverlayScrollbars && scrollableArea.hasScrollbars() {
                paintOverflowControlsForFragments(layerFragments, currentContext, localPaintingInfo)
            }
        }

        return shouldPaintContent
    }
    func updatePaintingInfoForFragments(
        _ fragments: inout WebCore.LayerFragments,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ localPaintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ shouldPaintContent: Bool,
        _ offsetFromRoot: WebCore.LayoutSize
    ) {
        let checksDamageRect =
            !isSameRenderLayer(self, localPaintingInfo.rootLayer()) || !localPaintFlags.contains(.PaintingOverflowContents)
        var index = 0
        while index < Int(fragments.size()) {
            fragments[index].shouldPaintContent = shouldPaintContent
            if checksDamageRect {
                let fragment = fragments[index]
                let newOffsetFromRoot = offsetFromRoot + fragment.paginationOffset
                fragments[index].shouldPaintContent =
                    fragment.shouldPaintContent
                    && intersectsDamageRect(
                        fragment.layerBounds(),
                        fragment.dirtyBackgroundRect().rectValue(),
                        localPaintingInfo.rootLayer(),
                        newOffsetFromRoot,
                        fragment.boundingBox()
                    )
            }
            index += 1
        }
    }

    // MARK: Painting: fragments

    func paintBackgroundForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ contextForTransparencyLayer: WebCore.LentGraphicsContext,
        _ transparencyPaintDirtyRect: WebCore.LayoutRect,
        _ haveTransparency: Bool,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) {
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            if !fragment.shouldPaintContent {
                continue
            }

            // Begin transparency layers lazily now that we know we have to paint something.
            if haveTransparency {
                beginTransparencyLayers(contextForTransparencyLayer, localPaintingInfo, transparencyPaintDirtyRect)
            }

            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(localPaintingInfo.regionContext())

            // Paint our background first, before painting any child layers.
            // Establish the clip used to paint our background.
            clipToRect(
                context,
                &stateSaver,
                &regionContextStateSaver,
                localPaintingInfo,
                paintBehavior,
                fragment.dirtyBackgroundRect(),
                WebCore.DoNotIncludeSelfForBorderRadius
            ) // Background painting will handle clipping to self.

            // Paint the background.
            // FIXME: Eventually we will collect the region from the fragment itself instead of just from the paint info.
            paintFragment(
                context,
                localPaintingInfo,
                fragment.dirtyBackgroundRect().rectValue(),
                .BlockBackground,
                paintBehavior,
                subtreePaintRootForRenderer,
                paintOffsetForRenderer(fragment, localPaintingInfo),
                false
            )
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    func paintForegroundForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ contextForTransparencyLayer: WebCore.LentGraphicsContext,
        _ transparencyPaintDirtyRect: WebCore.LayoutRect,
        _ haveTransparency: Bool,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) {
        // Begin transparency if we have something to paint.
        if haveTransparency {
            var index = 0
            while index < Int(layerFragments.size()) {
                let fragment = layerFragments[index]
                index += 1
                if fragment.shouldPaintContent && !fragment.dirtyForegroundRect().isEmpty() {
                    beginTransparencyLayers(contextForTransparencyLayer, localPaintingInfo, transparencyPaintDirtyRect)
                    break
                }
            }
        }

        var localPaintBehavior: WebCore.RenderLayer.PaintBehaviors
        if localPaintingInfo.paintBehavior.contains(.ForceBlackText) {
            localPaintBehavior = WebCore.RenderLayer.PaintBehaviors(.ForceBlackText)
        } else if localPaintingInfo.paintBehavior.contains(.ForceWhiteText) {
            localPaintBehavior = WebCore.RenderLayer.PaintBehaviors(.ForceWhiteText)
        } else {
            localPaintBehavior = paintBehavior
        }

        // FIXME: It's unclear if this flag copying is necessary.
        localPaintBehavior.add(paintBehaviorIntersection(localPaintingInfo.paintBehavior, paintBehaviorFlagsToCopyForForeground))

        var stateSaver = RenderLayerGraphicsContextStateSaver()
        var regionContextStateSaver = RenderLayerRegionContextStateSaver(localPaintingInfo.regionContext())

        // Optimize clipping for the single fragment case.
        let shouldClip =
            layerFragments.size() == 1 && layerFragments[0].shouldPaintContent && !layerFragments[0].dirtyForegroundRect().isEmpty()
        if shouldClip {
            clipToRect(
                context,
                &stateSaver,
                &regionContextStateSaver,
                localPaintingInfo,
                localPaintBehavior,
                layerFragments[0].dirtyForegroundRect()
            )
        }

        // We have to loop through every fragment multiple times, since we have to repaint in each specific phase in order for
        // interleaving of the fragments to work properly.
        let selectionOnly = localPaintingInfo.paintBehavior.contains(.SelectionOnly)
        let selectionAndBackgroundsOnly = localPaintingInfo.paintBehavior.contains(.SelectionAndBackgroundsOnly)

        if isSVGLayer()
            && paintForegroundForFragmentsForSVG(
                layerFragments,
                context,
                localPaintingInfo,
                localPaintBehavior,
                subtreePaintRootForRenderer
            )
        {
            regionContextStateSaver.end()
            stateSaver.end(context)
            return
        }

        if !selectionOnly {
            paintForegroundForFragmentsWithPhase(
                .ChildBlockBackgrounds,
                layerFragments,
                context,
                localPaintingInfo,
                localPaintBehavior,
                subtreePaintRootForRenderer
            )
        }

        if selectionOnly || selectionAndBackgroundsOnly {
            paintForegroundForFragmentsWithPhase(
                .Selection,
                layerFragments,
                context,
                localPaintingInfo,
                localPaintBehavior,
                subtreePaintRootForRenderer
            )
        } else {
            paintForegroundForFragmentsWithPhase(
                .Float,
                layerFragments,
                context,
                localPaintingInfo,
                localPaintBehavior,
                subtreePaintRootForRenderer
            )
            paintForegroundForFragmentsWithPhase(
                .Foreground,
                layerFragments,
                context,
                localPaintingInfo,
                localPaintBehavior,
                subtreePaintRootForRenderer
            )
            paintForegroundForFragmentsWithPhase(
                .ChildOutlines,
                layerFragments,
                context,
                localPaintingInfo,
                localPaintBehavior,
                subtreePaintRootForRenderer
            )
        }
        regionContextStateSaver.end()
        stateSaver.end(context)
    }

    func paintForegroundForFragmentsForSVG(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ localPaintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) -> Bool {
        assert(isSVGLayer())

        let rendererObject: WebCore.RenderObject = renderer()
        if rendererObject.asRenderSVGModelObject() == nil || rendererObject.isRenderSVGContainer() {
            return false
        }

        // SVG containers need to propagate paint phases. This could be saved if we remember somewhere if a SVG subtree
        // contains e.g. LegacyRenderSVGForeignObject objects that do need the individual paint phases. For SVG shapes & SVG images
        // we can avoid the multiple paintForegroundForFragmentsWithPhase() calls.
        if localPaintingInfo.paintBehavior.contains(.SelectionOnly)
            || localPaintingInfo.paintBehavior.contains(.SelectionAndBackgroundsOnly)
        {
            return true
        }

        paintForegroundForFragmentsWithPhase(
            .Foreground,
            layerFragments,
            context,
            localPaintingInfo,
            localPaintBehavior,
            subtreePaintRootForRenderer
        )
        return true
    }

    func paintNegativeZOrderChildrenForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags
    ) {
        assert(isSVGLayer())

        // foreignObject uses HTML-style z-order painting.
        if renderer().isRenderSVGForeignObject() {
            paintList(.Negative, context: context, paintingInfo, paintFlags)
            return
        }

        // SVG: no-op. Negative z-order children are handled in DOM-order painting
        // (paintChildrenInDOMOrderForSVG handles all children including negative z-index).
    }

    func paintForegroundForFragmentsWithPhase(
        _ phase: WebCore.PaintPhase,
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) {
        let shouldClip = layerFragments.size() > 1

        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            if !fragment.shouldPaintContent || fragment.dirtyForegroundRect().isEmpty() {
                continue
            }

            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(localPaintingInfo.regionContext())

            if shouldClip {
                clipToRect(context, &stateSaver, &regionContextStateSaver, localPaintingInfo, paintBehavior, fragment.dirtyForegroundRect())
            }

            paintFragment(
                context,
                localPaintingInfo,
                fragment.dirtyForegroundRect().rectValue(),
                phase,
                paintBehavior,
                subtreePaintRootForRenderer,
                paintOffsetForRenderer(fragment, localPaintingInfo),
                true
            )
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    func paintOutlineForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) {
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            if fragment.dirtyBackgroundRect().isEmpty() {
                continue
            }

            // Paint our own outline
            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(localPaintingInfo.regionContext())

            clipToRect(
                context,
                &stateSaver,
                &regionContextStateSaver,
                localPaintingInfo,
                paintBehavior,
                fragment.dirtyBackgroundRect(),
                WebCore.DoNotIncludeSelfForBorderRadius
            )
            paintFragment(
                context,
                localPaintingInfo,
                fragment.dirtyBackgroundRect().rectValue(),
                .SelfOutline,
                paintBehavior,
                subtreePaintRootForRenderer,
                paintOffsetForRenderer(fragment, localPaintingInfo),
                false
            )
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    func paintMaskForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) {
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            if !fragment.shouldPaintContent {
                continue
            }

            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(localPaintingInfo.regionContext())

            clipToRect(
                context,
                &stateSaver,
                &regionContextStateSaver,
                localPaintingInfo,
                paintBehavior,
                fragment.dirtyBackgroundRect(),
                WebCore.DoNotIncludeSelfForBorderRadius
            ) // Mask painting will handle clipping to self.

            // Paint the mask.
            // FIXME: Eventually we will collect the region from the fragment itself instead of just from the paint info.
            paintFragment(
                context,
                localPaintingInfo,
                fragment.dirtyBackgroundRect().rectValue(),
                .Mask,
                paintBehavior,
                subtreePaintRootForRenderer,
                paintOffsetForRenderer(fragment, localPaintingInfo),
                false
            )
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    func paintChildClippingMaskForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?
    ) {
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            if !fragment.shouldPaintContent {
                continue
            }

            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(localPaintingInfo.regionContext())

            clipToRect(
                context,
                &stateSaver,
                &regionContextStateSaver,
                localPaintingInfo,
                paintBehavior,
                fragment.dirtyForegroundRect(),
                WebCore.IncludeSelfForBorderRadius
            ) // Child clipping mask painting will handle clipping to self.

            // Paint the clipped mask.
            paintFragment(
                context,
                localPaintingInfo,
                fragment.dirtyBackgroundRect().rectValue(),
                .ClippingMask,
                paintBehavior,
                subtreePaintRootForRenderer,
                paintOffsetForRenderer(fragment, localPaintingInfo),
                false
            )
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    func collectEventRegionForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors
    ) {
        let regionContext = localPaintingInfo.regionContext()
        assert(isEventRegionContext(regionContext))
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            regionContext!.pushClip(WebCore.enclosingIntRect(fragment.dirtyBackgroundRect().rectValue()))
            paintFragmentForRegion(
                context,
                fragment.dirtyForegroundRect().rectValue(),
                .EventRegion,
                paintBehavior,
                regionContext,
                paintOffsetForRenderer(fragment, localPaintingInfo)
            )
            regionContext!.popClip()
        }
    }

    func collectAccessibilityRegionsForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors
    ) {
        let regionContext = localPaintingInfo.regionContext()
        assert(isAccessibilityRegionContext(regionContext))
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            paintFragmentForRegion(
                context,
                fragment.dirtyForegroundRect().rectValue(),
                .Accessibility,
                paintBehavior,
                regionContext,
                paintOffsetForRenderer(fragment, localPaintingInfo)
            )
        }
    }

    func paintFragment(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintRect: WebCore.LayoutRect,
        _ phase: WebCore.PaintPhase,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?,
        _ paintOffset: WebCore.LayoutPoint,
        _ isForegroundPhase: Bool
    ) {
        var paintInfo = WebCore.PaintInfo(
            context,
            paintRect,
            phase,
            paintBehavior,
            subtreePaintRoot,
            paintingInfo.rootLayer()!.renderer(),
            self,
            isForegroundPhase && paintingInfo.requireSecurityOriginAccessForWidgets
        )
        if phase == .Foreground {
            paintingInfo.applyOverlapTestRequests(&paintInfo)
        }
        paintContentForRenderer(&paintInfo, paintOffset)
    }

    func paintFragmentForRegion(
        _ context: WebCore.LentGraphicsContext,
        _ paintRect: WebCore.LayoutRect,
        _ phase: WebCore.PaintPhase,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ regionContext: WebCore.RegionContext?,
        _ paintOffset: WebCore.LayoutPoint
    ) {
        var paintInfo = WebCore.PaintInfo(context, paintRect, phase, paintBehavior, nil, nil, nil, false)
        paintInfo.setRegionContext(regionContext)
        paintContentForRenderer(&paintInfo, paintOffset)
    }

    func paintOverflowControlsForFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo
    ) {
        let scrollableArea = scrollableArea()!
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            if fragment.dirtyBackgroundRect().isEmpty() {
                continue
            }

            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(localPaintingInfo.regionContext())

            clipToRect(
                context,
                &stateSaver,
                &regionContextStateSaver,
                localPaintingInfo,
                WebCore.RenderLayer.PaintBehaviors(),
                fragment.dirtyBackgroundRect()
            )
            scrollableArea.paintOverflowControls(
                context,
                localPaintingInfo.paintBehavior,
                WebCore.roundedIntPoint(paintOffsetForRenderer(fragment, localPaintingInfo)),
                WebCore.snappedIntRect(fragment.dirtyBackgroundRect().rectValue()),
                true
            )
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    @cxx
    @implementation
    public func shouldHaveFiltersForPainting(
        _ context: WebCore.LentGraphicsContext,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors
    ) -> Bool {
        shouldHaveFiltersForPainting(context: context, paintFlags, paintBehavior)
    }

    func shouldHaveFiltersForPainting(
        context: WebCore.LentGraphicsContext,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors
    ) -> Bool {
        if context.paintingDisabled() {
            return false
        }

        if paintFlags.contains(.PaintingOverlayScrollbars) {
            return false
        }

        if !shouldPaintWithFilters(paintBehavior) {
            return false
        }

        return true
    }

    func trackPaintFrequency() {
        m_paintFrequencyTracker.track(page().lastRenderingUpdateTimestamp())
    }

    // MARK: SVG layer state

    @cxx
    @implementation
    public func hasVisibleContentForPaintingForSVG() -> Bool {
        assert(isSVGLayer())

        // paintResourceLayerForSVG() sets isPaintingResourceLayer on the paint root, a resource
        // container for mask/clipPath/marker/pattern or the referenced content itself for feImage. Any
        // layer up the chain carrying the flag means we paint this resource subtree now, so it must
        // paint despite living in a hidden (<defs>) or resource container, regardless of visibility.
        var ancestor: WebCore.RenderLayer? = self
        while let layer = ancestor {
            if layer.isPaintingSVGResourceLayer() {
                return true
            }
            ancestor = layer.parent()
        }

        // Outside an active resource paint, resource-container and hidden SVG container (<defs>,
        // <symbol> ...) content are never painted directly.
        if renderer().isRenderSVGResourceContainer() || enclosingHiddenOrResourceContainerRendererForSVG() != nil {
            return false
        }

        return hasVisibleContent()
    }

    @cxx
    @implementation
    public func shouldSkipRepaintAfterLayoutForSVG() -> Bool {
        assert(isSVGLayer())

        // SVG containers leave repaints to their contents, unless they changed themselves.
        let layerRenderer: WebCore.RenderObject = renderer()
        if !layerRenderer.isRenderSVGContainer() || shouldPaintWithFilters() {
            return false
        }
        return m_repaintStatus != .NeedsFullRepaint || layerRenderer.isRenderSVGHiddenContainer()
    }

    @cxx
    @implementation
    public func isCompositedSVGPaintOrderChild() -> Bool {
        // A child that paints outside the container's DOM-order walk: it owns a backing store, or hosts a
        // composited descendant parented under its layer. Either way, trailing non-composited siblings must
        // paint above it through an overlay segment layer.
        WebCore.compositedWithOwnBackingStore(self) || hasCompositingDescendant()
    }

    @cxx
    @implementation
    public func paintsInlineInSVGContainer() -> Bool {
        // A layer without its own backing store is painted inline by the container's DOM-order walk.
        !WebCore.compositedWithOwnBackingStore(self)
    }

    @cxx
    @implementation
    public func isFlattenedByEnclosingSVGReferenceFilter() -> Bool {
        // A non-compositable (reference) SVG filter renders its whole subtree into a single software buffer,
        // so a descendant must not composite independently, which would let it escape the filter. Walk the
        // SVG layer ancestry (below the SVG root, whose reference filter is handled separately) for such a
        // filter.
        var ancestor = parent()
        while let layer = ancestor {
            let ancestorRenderer = layer.renderer()
            if !ancestorRenderer.isSVGLayerAwareRenderer() || ancestorRenderer.isRenderSVGRoot() {
                return false
            }
            if ancestorRenderer[.Style].filterHasReferenceFilter() {
                return true
            }
            ancestor = layer.parent()
        }
        return false
    }

    func shouldSkipHitTestForSVG() -> Bool {
        assert(isSVGLayer())

        // SVG resource layers and their children are never hit tested.
        if let container = enclosingHiddenOrResourceContainerRendererForSVG(), container.isRenderSVGResourceContainer() {
            return true
        }

        // Hidden SVG containers (<defs> / <symbol> ...) are never hit tested directly.
        let layerRenderer: WebCore.RenderObject = renderer()
        return layerRenderer.isRenderSVGHiddenContainer()
    }

    // MARK: SVG children in DOM order

    @cxx
    @implementation
    public func collectChildrenInDOMOrderForSVG() {
        assert(isSVGLayer())
        var allChildren: [SVGPaintOrderEntry] = []
        var anyNonZeroZIndex = false
        _ = appendChildrenInDOMOrderForSVG(renderer(), WebCore.LayoutSize(), &anyNonZeroZIndex, &allChildren)

        // Sort by z-index; for equal z-index, the sort keeps DOM order.
        // Skip entirely when no child uses z-index — collection order already matches DOM order.
        if anyNonZeroZIndex {
            allChildren = allChildren.enumerated().sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
                .map { $0.element }
        }

        clearChildrenInDOMOrderForSVG()
        for entry in allChildren {
            switch entry.kind {
            case .layered:
                appendLayeredChildInDOMOrderForSVG(entry.renderer, entry.layer!, entry.zIndex)
            case .atomic:
                appendAtomicChildInDOMOrderForSVG(entry.renderer, entry.accumulatedAncestorOffset)
            case .outlineOnly:
                appendOutlineOnlyChildInDOMOrderForSVG(entry.renderer, entry.accumulatedAncestorOffset)
            }
        }
    }

    // Recursively collect children, splitting non-layered containers that have
    // layered descendants to ensure proper DOM-order interleaving. Returns true
    // if any layered child was found in this subtree.
    private func appendChildrenInDOMOrderForSVG(
        _ parent: WebCore.RenderElement,
        _ ancestorOffset: WebCore.LayoutSize,
        _ anyNonZeroZIndex: inout Bool,
        _ allChildren: inout [SVGPaintOrderEntry]
    ) -> Bool {
        var hasIndependentlyPaintedDescendant = false
        var next = parent.firstChild()
        while let object = next {
            next = object.nextSibling()
            guard let child = object.asRenderElement() else {
                continue
            }

            // Never directly paint children of <defs>, <linearGradient>, etc.
            if child.isRenderSVGHiddenContainer() {
                continue
            }

            if child.hasSelfPaintingLayer() {
                let childLayer = child.asRenderLayerModelObject()!.layer()!
                let zIndex = childLayer.zIndex()
                if zIndex != 0 {
                    anyNonZeroZIndex = true
                }
                allChildren.append(
                    SVGPaintOrderEntry(
                        kind: .layered,
                        renderer: child,
                        layer: childLayer,
                        zIndex: zIndex,
                        accumulatedAncestorOffset: WebCore.LayoutSize()
                    )
                )
                hasIndependentlyPaintedDescendant = true
                continue
            }

            // Transformed non-layer children are painted atomically by the consumer:
            // its transform is applied and children are painted recursively.
            if child.isTransformed() {
                allChildren.append(SVGPaintOrderEntry(atomic: child, ancestorOffset))
                hasIndependentlyPaintedDescendant = true
                continue
            }

            // Paint a non-layer child that clips its subtree together with that subtree as one unit, so the
            // clip covers all of it. Splitting it apart would move its descendants into the parent's
            // z-order list and paint them outside the clip.
            if WebCore.RenderLayer.clipsSubtreeForSVG(child) {
                allChildren.append(SVGPaintOrderEntry(atomic: child, ancestorOffset))
                hasIndependentlyPaintedDescendant = true
                continue
            }

            // Leaf nodes (no children) are always painted atomically.
            if child.firstChild() == nil {
                allChildren.append(SVGPaintOrderEntry(atomic: child, ancestorOffset))
                continue
            }

            // Compute the offset that this child contributes to its descendants.
            var childOffset = ancestorOffset
            if let svgModel = (child as WebCore.RenderObject).asRenderSVGModelObject() {
                childOffset = childOffset + WebCore.toLayoutSize(svgModel.currentSVGLayoutLocation())
            }

            // We don't yet know whether this non-layered container has any independently painted
            // descendants (layered or transformed non-layer children), so recurse speculatively and
            // decide what to keep based on the result.
            //
            // No independently painted descendants: the subtree paints atomically as part of the
            // container's own normal paint walk, so the speculative entries are discarded and the
            // container gets a single entry. Otherwise their entries are kept (so they sort into the
            // overall z-order) and the container gets an outline-only entry: the consumer paints only
            // its own outline and skips child recursion, since each independently painted descendant
            // is painted from the sorted list.
            let startIndex = allChildren.count
            let subtreeHasIndependentlyPaintedDescendant = appendChildrenInDOMOrderForSVG(
                child,
                childOffset,
                &anyNonZeroZIndex,
                &allChildren
            )
            if subtreeHasIndependentlyPaintedDescendant {
                assert(!WebCore.RenderLayer.clipsSubtreeForSVG(child))
                allChildren.append(
                    SVGPaintOrderEntry(
                        kind: .outlineOnly,
                        renderer: child,
                        layer: nil,
                        zIndex: 0,
                        accumulatedAncestorOffset: ancestorOffset
                    )
                )
                hasIndependentlyPaintedDescendant = true
            } else {
                allChildren.removeSubrange(startIndex...)
                allChildren.append(SVGPaintOrderEntry(atomic: child, ancestorOffset))
            }
        }
        return hasIndependentlyPaintedDescendant
    }

    // MARK: SVG painting in DOM order

    func paintForegroundChildrenForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ localPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ layerFragments: WebCore.LayerFragments,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?,
        _ svgPaintOrderItemRange: WebCore.RenderLayer.OptionalPaintOrderItemRange,
        _ svgFilterChildLayerCorrection: WebCore.LayoutSize
    ) {
        assert(isSVGLayer())

        // An empty viewBox disables rendering of the content. Non-layer descendants are flattened into
        // this layer's DOM-order list (see collectChildrenInDOMOrderForSVG), so the whole list has to be
        // gated here -- RenderSVGViewportContainer::paint() alone would not catch the flattened ones.
        if viewBoxDisablesPaintingForSVG() {
            return
        }

        // foreignObject uses HTML-style z-order painting.
        if renderer().isRenderSVGForeignObject() {
            // HTML layers and foreignObject use normal z-order list painting. No filter buffer correction
            // applies: these child layers paint via paintList and never reach paintChildrenInDOMOrderForSVG.
            paintList(.NormalFlow, context: context, paintingInfo, paintFlags)
            paintList(.Positive, context: context, localPaintingInfo, paintFlags)
            return
        }

        // FIXME: A composited document element RenderSVGRoot still blends the root background.
        let blendContents = blendModeAppliesToSVGRootContentsOnly() && paintsWithTransparency(localPaintingInfo.paintBehavior)
        if blendContents {
            context.save()
            context.setCompositeOperation(context.compositeOperation(), blendMode())
            context.beginTransparencyLayer(1)
            context.setCompositeOperation(context.compositeOperation(), .Normal)
        }

        paintChildrenInDOMOrderForSVG(
            context,
            localPaintingInfo,
            paintFlags,
            layerFragments,
            paintBehavior,
            subtreePaintRoot,
            svgPaintOrderItemRange,
            svgFilterChildLayerCorrection
        )

        if blendContents {
            context.endTransparencyLayer()
            context.restore()
        }
    }

    @cxx
    @implementation
    public func paintResourceCorrectedChildLayerForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ childLayer: WebCore.RenderLayer,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ correction: WebCore.LayoutSize
    ) {
        paintResourceCorrectedChildLayerForSVG(context: context, childLayer, paintingInfo, paintFlags, correction)
    }

    func paintResourceCorrectedChildLayerForSVG(
        context: WebCore.LentGraphicsContext,
        _ childLayer: WebCore.RenderLayer,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ correction: WebCore.LayoutSize
    ) {
        // A child layer painted inside an SVG resource/filter buffer (mask, clipPath, filter) computes its
        // position relative to the buffer root and so misses the buffer's nominalSVGLayoutLocation offset.
        // Translate by 'correction' to compensate. Deeper layers do not re-apply it: the resource path
        // recomputes it per level and the filter path re-derives it per layer in paintLayerContents.
        var stateSaver = RenderLayerGraphicsContextStateSaver()
        if !correction.isZero() {
            stateSaver.save(context)
            context.translate(WebCore.FloatSize(correction.width().toFloat(), correction.height().toFloat()))
        }
        childLayer.paintLayer(context: context, paintingInfo, paintFlags)
        stateSaver.end(context)
    }

    // The transform that maps a transformed SVG renderer's content into the coordinates of this layer's renderer, or
    // nil when it is not invertible.
    func rendererTransformForSVG(
        _ rendererRef: WebCore.RenderElement,
        _ positionOffset: WebCore.LayoutSize
    ) -> WebCore.TransformationMatrix? {
        let layerModelObject = rendererRef.asRenderLayerModelObject()!
        var transform = WebCore.TransformationMatrix()
        let rendererObject: WebCore.RenderObject = rendererRef

        // Fast path: a non-layer SVG renderer caches its nominal transform; move it to the user space origin.
        let isNonLayerSVG = !rendererRef.hasSelfPaintingLayer() && rendererObject.isSVGLayerAwareRenderer()
        let useTransformRenderer =
            (isNonLayerSVG && !rendererObject.isRenderSVGViewportContainer()) ? rendererObject.asRenderSVGModelObject() : nil

        if let useTransformRenderer {
            let nominal = useTransformRenderer.nominalSVGLayoutLocation()
            transform.translateBy(Double(nominal.x().toFloat()), Double(nominal.y().toFloat()))
            transform.multiplyBy(WebCore.TransformationMatrix(useTransformRenderer.nominalTransform()))
            transform.translateBy(Double(-nominal.x().toFloat()), Double(-nominal.y().toFloat()))
        } else {
            var referenceBoxRect = layerModelObject.transformReferenceBoxRect(layerModelObject[.Style])

            // For non-layer renderers, undo the alignReferenceBox shift applied in transformReferenceBoxRect().
            if isNonLayerSVG {
                let nominal = layerModelObject.nominalSVGLayoutLocation()
                referenceBoxRect.moveBy(WebCore.FloatPoint(nominal.x().toFloat(), nominal.y().toFloat()))
            }

            layerModelObject.applyTransform(
                &transform,
                layerModelObject[.Style],
                referenceBoxRect,
                WebCore.RenderLayer.allTransformOperations()
            )
        }

        // For the outermost viewport container (anonymous child of RenderSVGRoot), apply the
        // content-box origin offset (border+padding).
        let isOutermostViewportContainer = rendererObject.isRenderSVGViewportContainer() && rendererObject.isAnonymous()
        if isOutermostViewportContainer, let parentRenderer = rendererObject.parent(),
            (parentRenderer as WebCore.RenderObject).isRenderSVGRoot()
        {
            let contentBoxLocation = (parentRenderer as WebCore.RenderObject).asRenderBox()!.contentBoxLocation()
            if !contentBoxLocation.isZero() {
                transform.translateRightBy(contentBoxLocation.x().toDouble(), contentBoxLocation.y().toDouble())
            }
        }

        if !transform.isInvertible() {
            return nil
        }

        var containerOffset = WebCore.LayoutSize()
        if rendererRef.hasSelfPaintingLayer() && !isOutermostViewportContainer {
            containerOffset = positionOffset
            if let box = rendererObject.asRenderBox() {
                containerOffset = containerOffset + WebCore.toLayoutSize(box.location())
            } else if let svgModel = rendererObject.asRenderSVGModelObject() {
                containerOffset = containerOffset + WebCore.toLayoutSize(svgModel.currentSVGLayoutLocation())
            }
        }

        transform.translateRightBy(Double(containerOffset.width().toFloat()), Double(containerOffset.height().toFloat()))
        return transform
    }

    func paintRendererByApplyingTransformForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ rendererToPaint: WebCore.RenderElement,
        _ positionOffset: WebCore.LayoutSize,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?,
        _ nominalPreTranslation: WebCore.LayoutSize = WebCore.LayoutSize()
    ) {
        assert(rendererToPaint.isTransformed())
        guard var scopeTransform = rendererTransformForSVG(rendererToPaint, positionOffset) else {
            return
        }

        let deviceScaleFactor = rendererToPaint.document().deviceScaleFactor()

        assert(paintingInfo.subpixelOffset.isZero())
        let adjustedSubpixelOffset = WebCore.LayoutSize()

        // Fold the container's nominal pre-translation into the scope transform rather than a separate
        // context.translate, so TransformPaintScope concatenates it onto the CTM and inverse-maps
        // paintDirtyRect through it together, keeping content and the leaf visual-overflow cull in one
        // coordinate space. translateRight post-multiplies, placing the offset in this container's own
        // space, where nominal lives.
        if !nominalPreTranslation.isZero() {
            scopeTransform.translateRightBy(
                Double(-nominalPreTranslation.width().toFloat()),
                Double(-nominalPreTranslation.height().toFloat())
            )
        }

        let paintsShapeWithSharedState =
            rendererToPaint.isRenderSVGShape() && !rendererToPaint.hasSelfPaintingLayer() && !rendererToPaint.hasOutline()
            && !rendererToPaint.hasMask()
        let stateSavedByCaller: WebCore.StateSavedByCaller = paintsShapeWithSharedState ? .Yes : .No
        var sharedStateSaver = RenderLayerGraphicsContextStateSaver()
        if paintsShapeWithSharedState {
            sharedStateSaver.save(context)
        }
        var scopedPaintingInfo = paintingInfo
        let scope = beginTransformPaintScope(
            context,
            &scopedPaintingInfo,
            scopeTransform,
            deviceScaleFactor,
            adjustedSubpixelOffset,
            nil,
            stateSavedByCaller
        )
        let transformedPaintingInfo = scopedPaintingInfo

        var adjustedPaintFlags = paintFlags
        adjustedPaintFlags.remove(WebCore.RenderLayer.PaintLayerFlags(.PaintingOverflowContents))

        if rendererToPaint.hasSelfPaintingLayer() {
            let childLayer = rendererToPaint.asRenderLayerModelObject()!.layer()!

            let childPaintingInfo = transformedPaintingInfo.forRootLayer(
                childLayer,
                transformedPaintingInfo.paintDirtyRect,
                paintBehavior,
                WebCore.LayoutSize()
            )
            var childPaintFlags = adjustedPaintFlags
            childPaintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.AppliedTransform))
            childLayer.paintLayer(context: context, childPaintingInfo, childPaintFlags)
        } else {
            // A renderer's own paint() positions content at paintOffset + currentSVGLayoutLocation() - at a
            // transform-scope root we want it at the visual top-left, so pass (nominal - current). This is
            // uniform for shapes, images, text and a container's own outline.
            var selfPaintOffset = WebCore.LayoutPoint()
            if rendererToPaint.isSVGLayerAwareRenderer() {
                let layerModelObject = rendererToPaint.asRenderLayerModelObject()!
                selfPaintOffset = layerModelObject.nominalSVGLayoutLocation()
                selfPaintOffset.move(negated(WebCore.toLayoutSize(layerModelObject.currentSVGLayoutLocation())))
            }

            if rendererToPaint.hasClipPath() || rendererToPaint.hasMask() {
                paintNonLayerRendererWithClippingAndMaskingForSVG(
                    context,
                    rendererToPaint,
                    selfPaintOffset,
                    transformedPaintingInfo,
                    adjustedPaintFlags,
                    paintBehavior,
                    subtreePaintRoot,
                    stateSavedByCaller
                )
            } else {
                paintNonLayerRendererInTransformScopeForSVG(
                    context: context,
                    rendererToPaint,
                    selfPaintOffset,
                    transformedPaintingInfo,
                    adjustedPaintFlags,
                    paintBehavior,
                    subtreePaintRoot,
                    stateSavedByCaller,
                    false
                )
            }
        }

        endTransformPaintScope(context, transformedPaintingInfo, scope)
        sharedStateSaver.end(context)
    }

    @cxx
    @implementation
    public func paintNonLayerRendererInTransformScopeForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ rendererToPaint: WebCore.RenderElement,
        _ selfPaintOffset: WebCore.LayoutPoint,
        _ transformedPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ adjustedPaintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?,
        _ stateSavedByCaller: WebCore.StateSavedByCaller,
        _ paintsIntoMaskLayer: Bool
    ) {
        paintNonLayerRendererInTransformScopeForSVG(
            context: context,
            rendererToPaint,
            selfPaintOffset,
            transformedPaintingInfo,
            adjustedPaintFlags,
            paintBehavior,
            subtreePaintRoot,
            stateSavedByCaller,
            paintsIntoMaskLayer
        )
    }

    // Non-layer renderer painted directly within the transform scope.
    func paintNonLayerRendererInTransformScopeForSVG(
        context: WebCore.LentGraphicsContext,
        _ rendererToPaint: WebCore.RenderElement,
        _ selfPaintOffset: WebCore.LayoutPoint,
        _ transformedPaintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ adjustedPaintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?,
        _ stateSavedByCaller: WebCore.StateSavedByCaller,
        _ paintsIntoMaskLayer: Bool
    ) {
        let paintsShapeWithSharedState = stateSavedByCaller == .Yes
        func paintInScope(
            _ phase: WebCore.PaintPhase,
            _ offset: WebCore.LayoutPoint,
            _ rendererStateSavedByCaller: WebCore.StateSavedByCaller = .No
        ) {
            var paintInfo = WebCore.PaintInfo(
                context,
                transformedPaintingInfo.paintDirtyRect,
                phase,
                paintBehavior,
                subtreePaintRoot,
                transformedPaintingInfo.rootLayer()!.renderer(),
                self,
                transformedPaintingInfo.requireSecurityOriginAccessForWidgets
            )
            paintInfo.stateSavedByCaller = rendererStateSavedByCaller
            rendererToPaint.paintForSwift(&paintInfo, offset)
        }

        if rendererToPaint.isRenderSVGContainer() {
            // Children recurse from the container's nominal origin (selfPaintOffset plus current) and
            // add their own currentSVGLayoutLocation. The anonymous outermost viewport starts at (0, 0).
            var recursionBase = WebCore.LayoutPoint()
            let rendererObject: WebCore.RenderObject = rendererToPaint
            if rendererObject.isRenderSVGViewportContainer() && rendererObject.isAnonymous() {
                // Outermost viewport container: coordinate system starts at (0, 0).
            } else if let svgModel = rendererToPaint.asRenderSVGModelObject() {
                recursionBase = svgModel.nominalSVGLayoutLocation()
            }
            paintSubtreeWithinTransformScopeForSVG(
                context,
                rendererToPaint,
                recursionBase,
                transformedPaintingInfo,
                adjustedPaintFlags,
                paintBehavior,
                subtreePaintRoot
            )
            if rendererToPaint.hasOutline() {
                paintInScope(.SelfOutline, selfPaintOffset)
            }
        } else {
            let foregroundIsLastPaint = !paintsIntoMaskLayer
            paintInScope(.Foreground, selfPaintOffset, paintsShapeWithSharedState && foregroundIsLastPaint ? .Yes : .No)
            if rendererToPaint.hasOutline() {
                paintInScope(.Outline, selfPaintOffset)
            }
        }
    }

    private struct SVGTransformScopeChild {
        var renderer: WebCore.RenderElement
        var zIndex: Int32
        var index: Int
    }

    func paintSubtreeWithinTransformScopeForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ container: WebCore.RenderElement,
        _ paintOffset: WebCore.LayoutPoint,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?
    ) {
        // Apply viewport clipping for nested <svg> elements without layers.
        var clipSaver = RenderLayerGraphicsContextStateSaver()
        if container.isRenderSVGViewportContainer(), let viewportContainer = container.asRenderSVGModelObject() {
            if !viewportContainer.hasSelfPaintingLayer() && WebCore.RenderLayer.isOverflowHiddenForSVG(container) {
                clipSaver.save(context)
                let clipOffset = viewportContainer.isTransformed() ? WebCore.LayoutPoint() : paintOffset
                context.clip(floatRect(viewportContainer.overflowClipRect(clipOffset, .IgnoreOverlayScrollbarSize, .BlockBackground)))
            }
        }

        var sortedChildren: [SVGTransformScopeChild] = []
        var next = container.firstChild()
        while let object = next {
            next = object.nextSibling()
            guard let child = object.asRenderElement() else {
                continue
            }
            if child.isRenderSVGHiddenContainer() {
                continue
            }
            if child[.Style].displayIsNone() {
                continue
            }

            var zIndex: Int32 = 0
            if child.hasSelfPaintingLayer(), let childLayer = child.asRenderLayerModelObject()!.layer() {
                zIndex = childLayer.zIndex()
            }
            sortedChildren.append(SVGTransformScopeChild(renderer: child, zIndex: zIndex, index: sortedChildren.count))
        }

        // A stable sort by z-index: equal z-indices keep their order.
        sortedChildren.sort { $0.zIndex != $1.zIndex ? $0.zIndex < $1.zIndex : $0.index < $1.index }

        for entry in sortedChildren {
            let child = entry.renderer

            if child.isTransformed() {
                paintRendererByApplyingTransformForSVG(
                    context,
                    child,
                    WebCore.toLayoutSize(paintOffset),
                    paintingInfo,
                    paintFlags,
                    paintBehavior,
                    subtreePaintRoot
                )
                continue
            }

            if child.hasSelfPaintingLayer() {
                let childLayer = child.asRenderLayerModelObject()!.layer()!

                var adjustedFlags = paintFlags
                adjustedFlags.remove(WebCore.RenderLayer.PaintLayerFlags(.PaintingOverflowContents))

                // Inside a resource buffer the transform-scope paint offset is this child's resource-layer
                // correction (see paintResourceCorrectedChildLayerForSVG).
                let correction = isPaintingSVGResourceLayer() ? WebCore.toLayoutSize(paintOffset) : WebCore.LayoutSize()
                paintResourceCorrectedChildLayerForSVG(context: context, childLayer, paintingInfo, adjustedFlags, correction)
                continue
            }

            // Non-layer, non-transformed child.
            var adjustedPaintOffset = paintOffset
            if let childSVGModel = child.asRenderSVGModelObject() {
                adjustedPaintOffset.moveBy(childSVGModel.currentSVGLayoutLocation())
            }

            if child.hasClipPath() || child.hasMask() {
                paintNonLayerChildWithClippingAndMaskingForSVG(
                    context,
                    child,
                    paintOffset,
                    adjustedPaintOffset,
                    paintingInfo,
                    paintFlags,
                    paintBehavior,
                    subtreePaintRoot
                )
            } else {
                paintNonLayerChildInTransformScopeForSVG(
                    context: context,
                    child,
                    paintOffset,
                    adjustedPaintOffset,
                    paintingInfo,
                    paintFlags,
                    paintBehavior,
                    subtreePaintRoot
                )
            }
        }

        clipSaver.end(context)
    }

    @cxx
    @implementation
    public func paintNonLayerChildInTransformScopeForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ child: WebCore.RenderElement,
        _ paintOffset: WebCore.LayoutPoint,
        _ adjustedPaintOffset: WebCore.LayoutPoint,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?
    ) {
        paintNonLayerChildInTransformScopeForSVG(
            context: context,
            child,
            paintOffset,
            adjustedPaintOffset,
            paintingInfo,
            paintFlags,
            paintBehavior,
            subtreePaintRoot
        )
    }

    func paintNonLayerChildInTransformScopeForSVG(
        context: WebCore.LentGraphicsContext,
        _ child: WebCore.RenderElement,
        _ paintOffset: WebCore.LayoutPoint,
        _ adjustedPaintOffset: WebCore.LayoutPoint,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRoot: WebCore.RenderObject?
    ) {
        if child.isRenderSVGContainer() {
            paintSubtreeWithinTransformScopeForSVG(
                context,
                child,
                adjustedPaintOffset,
                paintingInfo,
                paintFlags,
                paintBehavior,
                subtreePaintRoot
            )

            var outlinePaintInfo = WebCore.PaintInfo(
                context,
                paintingInfo.paintDirtyRect,
                .SelfOutline,
                paintBehavior,
                subtreePaintRoot,
                paintingInfo.rootLayer()!.renderer(),
                self,
                paintingInfo.requireSecurityOriginAccessForWidgets
            )
            child.paintForSwift(&outlinePaintInfo, paintOffset)
        } else {
            var paintInfo = WebCore.PaintInfo(
                context,
                paintingInfo.paintDirtyRect,
                .Foreground,
                paintBehavior,
                subtreePaintRoot,
                paintingInfo.rootLayer()!.renderer(),
                self,
                paintingInfo.requireSecurityOriginAccessForWidgets
            )
            child.paintForSwift(&paintInfo, paintOffset)

            var outlinePaintInfo = paintInfo
            outlinePaintInfo.phase = .Outline
            child.paintForSwift(&outlinePaintInfo, paintOffset)
        }
    }

    private func svgRootScrollAdjustmentForSVG() -> WebCore.LayoutPoint {
        let scrollPosition = renderer().asRenderBox()!.scrollPosition()
        // Wraps at INT_MIN, as int negation does in practice.
        return WebCore.LayoutPoint(WebCore.IntPoint(0 &- scrollPosition.x(), 0 &- scrollPosition.y()))
    }

    func paintNonLayerChildForFragmentsForSVG(
        _ childRenderer: WebCore.RenderElement,
        _ accumulatedAncestorOffset: WebCore.LayoutSize,
        _ phase: WebCore.PaintPhase,
        _ layerFragments: WebCore.LayerFragments,
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?,
        _ containerBaseOffset: WebCore.LayoutPoint,
        _ isSVGRoot: Bool,
        _ sharedClipApplied: Bool
    ) {
        var svgRootScrollAdjustment = WebCore.LayoutPoint()
        if isSVGRoot {
            svgRootScrollAdjustment = svgRootScrollAdjustmentForSVG()
        }

        // Like collectEventRegionForFragments(), event-region collection runs even for fragments
        // with no visible content (shouldPaintContent false, empty foreground rect).
        let collectingEventRegion = phase == .EventRegion
        var index = 0
        while index < Int(layerFragments.size()) {
            let fragment = layerFragments[index]
            index += 1
            if !collectingEventRegion && (!fragment.shouldPaintContent || fragment.dirtyForegroundRect().isEmpty()) {
                continue
            }

            // Re-clip per shape only when the caller has not already applied a shared clip around the
            // whole child loop (see paintChildrenInDOMOrderForSVG).
            var stateSaver = RenderLayerGraphicsContextStateSaver()
            var regionContextStateSaver = RenderLayerRegionContextStateSaver(paintingInfo.regionContext())
            if !sharedClipApplied {
                clipToRect(context, &stateSaver, &regionContextStateSaver, paintingInfo, paintBehavior, fragment.dirtyForegroundRect())
            }

            var paintInfo = WebCore.PaintInfo(
                context,
                fragment.dirtyForegroundRect().rectValue(),
                phase,
                paintBehavior,
                subtreePaintRootForRenderer,
                paintingInfo.rootLayer()!.renderer(),
                self,
                paintingInfo.requireSecurityOriginAccessForWidgets
            )
            if collectingEventRegion {
                paintInfo.setRegionContext(paintingInfo.regionContext())
            }
            if phase == .Foreground {
                paintingInfo.applyOverlapTestRequests(&paintInfo)
            }
            paintInfo.updateSubtreePaintRootForChildren(renderer())

            var childPaintOffset = paintOffsetForRenderer(fragment, paintingInfo)
            if !containerBaseOffset.isZero() {
                childPaintOffset.moveBy(containerBaseOffset)
            }
            if isSVGRoot {
                childPaintOffset.moveBy(svgRootScrollAdjustment)
            }

            childPaintOffset.move(accumulatedAncestorOffset)
            childRenderer.paintForSwift(&paintInfo, childPaintOffset)
            regionContextStateSaver.end()
            stateSaver.end(context)
        }
    }

    func paintChildrenInDOMOrderForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ layerFragments: WebCore.LayerFragments,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?,
        _ svgPaintOrderItemRange: WebCore.RenderLayer.OptionalPaintOrderItemRange,
        _ svgFilterChildLayerCorrection: WebCore.LayoutSize
    ) {
        assert(isSVGLayer())
        let count = Int(childrenInDOMOrderCountForSVG())
        if count == 0 {
            return
        }

        let layerRenderer: WebCore.RenderObject = renderer()
        let isSVGRoot = layerRenderer.isRenderSVGRoot()
        var containerBaseOffset = WebCore.LayoutPoint()
        var layerResourceOffset = WebCore.LayoutPoint()

        if let svgModelObject = layerRenderer.asRenderSVGModelObject() {
            containerBaseOffset = svgModelObject.currentSVGLayoutLocation()
            if isPaintingSVGResourceLayer() {
                layerResourceOffset = svgModelObject.nominalSVGLayoutLocation()
            }
        } else if isSVGRoot {
            containerBaseOffset = layerRenderer.asRenderBox()!.location()
        }

        // When this layer paints as a single paint-order segment (paintIntoLayer passes the range of the
        // GraphicsLayer being painted), walk only that segment's half-open range of the flat list. The
        // rootLayer == this check keeps the range tied to this layer: a child layer paints through its own
        // paintLayer call, which carries no range, so it cannot leak into the child's flat list.
        var beginIndex = 0
        var endIndex = count
        if svgPaintOrderItemRange.value != nil && isSameRenderLayer(paintingInfo.rootLayer(), self) {
            let rangeEnd = Int(WebCore.RenderLayer.paintOrderItemRangeEnd(svgPaintOrderItemRange))
            assert(rangeEnd <= count)
            beginIndex = Int(WebCore.RenderLayer.paintOrderItemRangeBegin(svgPaintOrderItemRange))
            endIndex = min(rangeEnd, count)
        }

        // Every non-layer child clips the context to the same fragment dirty-foreground rect, one
        // CGContextSaveGState + CGContextClipToRect per shape. With a single paintable fragment and no
        // child owning a layer, apply that clip once and share it across all children. Skip resource
        // layers (marker/mask/pattern), whose content paints in its own coordinate system where this
        // fragment rect is the wrong clip.
        var hasChildLayers = false
        var layerIndex = beginIndex
        while layerIndex < endIndex {
            if childLayerInDOMOrderForSVG(UInt32(layerIndex)) != nil {
                hasChildLayers = true
                break
            }
            layerIndex += 1
        }

        var sharedClipApplied = false
        var sharedClipSaver = RenderLayerGraphicsContextStateSaver()
        var sharedRegionSaver = RenderLayerRegionContextStateSaver(paintingInfo.regionContext())
        if !hasChildLayers && layerFragments.size() == 1 && layerFragments[0].shouldPaintContent && !isPaintingSVGResourceLayer() {
            let dirtyForegroundRect = layerFragments[0].dirtyForegroundRect()
            if !dirtyForegroundRect.isEmpty() {
                sharedClipApplied = true
                clipToRect(context, &sharedClipSaver, &sharedRegionSaver, paintingInfo, paintBehavior, dirtyForegroundRect)
            }
        }

        var index = beginIndex
        while index < endIndex {
            let itemIndex = UInt32(index)
            index += 1
            if let childLayer = childLayerInDOMOrderForSVG(itemIndex) {
                // Children that own a backing store paint through the compositor and an overlay segment layer
                // paints above them. A composited child that paints into a composited ancestor has no own
                // GraphicsLayer, so it must still paint inline here (see paintsInlineInSVGContainer()).
                if !childLayer.paintsInlineInSVGContainer() && !paintBehavior.contains(.FlattenCompositingLayers) {
                    continue
                }

                // mask/clipPath buffers supply the correction locally as layerResourceOffset, filters
                // carry it via the svgFilterChildLayerCorrection argument (computed at filter-buffer setup
                // in paintLayerContents). These are mutually exclusive per child, with the resource path
                // taking precedence.
                let correction =
                    (isPaintingSVGResourceLayer() && !layerResourceOffset.isZero())
                    ? WebCore.toLayoutSize(layerResourceOffset) : svgFilterChildLayerCorrection

                paintResourceCorrectedChildLayerForSVG(context: context, childLayer, paintingInfo, paintFlags, correction)
                continue
            }

            guard let childRenderer = childRendererInDOMOrderForSVG(itemIndex) else {
                continue
            }
            let accumulatedAncestorOffset = childAccumulatedAncestorOffsetInDOMOrderForSVG(itemIndex)

            // Transformed non-layer children: apply the transform and recursively paint the subtree.
            if childRenderer.isTransformed() {
                // When this container is itself a transformed SVG layer (e.g. a layered <use>), its CTM is
                // positioned at its own nominalSVGLayoutLocation (objectBoundingBox top-left). The transform
                // recursion paints the child additively in that CTM, so the child would inherit a spurious
                // shift. Cancel it by folding -nominalCorrection into the child's transform scope (see
                // paintRendererByApplyingTransformForSVG). No-op for SVG root / viewport (nominal == 0) and
                // when not painting as a layer-scope root. Since every transformed container is layered, the
                // only transformed renderers reaching this recursion are leaves and the anonymous outermost
                // viewport container, so no layer descendant ever needs the inverse correction.
                var nominalCorrection = WebCore.LayoutSize()
                if isSameRenderLayer(paintingInfo.rootLayer(), self) && !isPaintingSVGResourceLayer()
                    && layerRenderer.isSVGLayerAwareRenderer() && !layerRenderer.isRenderSVGRoot()
                {
                    nominalCorrection = WebCore.toLayoutSize(renderer().nominalSVGLayoutLocation())
                }

                var fragmentIndex = 0
                while fragmentIndex < Int(layerFragments.size()) {
                    let fragment = layerFragments[fragmentIndex]
                    fragmentIndex += 1
                    if !fragment.shouldPaintContent || fragment.dirtyForegroundRect().isEmpty() {
                        continue
                    }

                    // Re-clip per shape only when no shared clip was applied before the loop (multiple fragments, or child layers present).
                    var stateSaver = RenderLayerGraphicsContextStateSaver()
                    var regionContextStateSaver = RenderLayerRegionContextStateSaver(paintingInfo.regionContext())
                    if !sharedClipApplied {
                        clipToRect(
                            context,
                            &stateSaver,
                            &regionContextStateSaver,
                            paintingInfo,
                            paintBehavior,
                            fragment.dirtyForegroundRect()
                        )
                    }

                    // nominalCorrection is applied inside the scope, so TransformPaintScope concatenates it
                    // onto the CTM and inverse-maps paintDirtyRect through it together. The leaf
                    // visual-overflow cull (RenderSVGShape::paint) then compares the shifted subtree against
                    // a matching damage rect, so overhanging leaves survive incremental repaints
                    // (svg/W3C-SVG-1.1/animate-elem-80-t.svg).
                    paintRendererByApplyingTransformForSVG(
                        context,
                        childRenderer,
                        accumulatedAncestorOffset,
                        paintingInfo,
                        paintFlags,
                        paintBehavior,
                        subtreePaintRootForRenderer,
                        nominalCorrection
                    )
                    regionContextStateSaver.end()
                    stateSaver.end(context)
                }
                continue
            }

            // The child's clip-path and mask apply while it paints.
            if childRenderer.hasClipPath() || childRenderer.hasMask() {
                var offsetFromRoot = WebCore.RenderLayer.OptionalLayoutSize()
                var fragmentIndex = 0
                while fragmentIndex < Int(layerFragments.size()) {
                    let fragment = layerFragments[fragmentIndex]
                    fragmentIndex += 1
                    if !fragment.shouldPaintContent || fragment.dirtyForegroundRect().isEmpty() {
                        continue
                    }
                    var childPaintOffset = paintOffsetForRenderer(fragment, paintingInfo)
                    childPaintOffset.moveBy(containerBaseOffset)
                    if isSVGRoot {
                        childPaintOffset.moveBy(svgRootScrollAdjustmentForSVG())
                    }
                    childPaintOffset.move(accumulatedAncestorOffset)
                    offsetFromRoot = WebCore.RenderLayer.OptionalLayoutSize(WebCore.toLayoutSize(childPaintOffset))
                    break
                }
                paintNonLayerChildInDOMOrderWithClippingAndMaskingForSVG(
                    context,
                    childRenderer,
                    itemIndex,
                    offsetFromRoot,
                    accumulatedAncestorOffset,
                    layerFragments,
                    paintingInfo,
                    paintFlags,
                    paintBehavior,
                    subtreePaintRootForRenderer,
                    containerBaseOffset,
                    isSVGRoot,
                    sharedClipApplied
                )
            } else {
                paintNonLayerChildInDOMOrderForSVG(
                    context: context,
                    childRenderer,
                    itemIndex,
                    accumulatedAncestorOffset,
                    layerFragments,
                    paintingInfo,
                    paintFlags,
                    paintBehavior,
                    subtreePaintRootForRenderer,
                    containerBaseOffset,
                    isSVGRoot,
                    sharedClipApplied
                )
            }
        }

        sharedRegionSaver.end()
        sharedClipSaver.end(context)
    }

    @cxx
    @implementation
    public func paintNonLayerChildInDOMOrderForSVG(
        _ context: WebCore.LentGraphicsContext,
        _ childRenderer: WebCore.RenderElement,
        _ itemIndex: UInt32,
        _ accumulatedAncestorOffset: WebCore.LayoutSize,
        _ layerFragments: WebCore.LayerFragments,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?,
        _ containerBaseOffset: WebCore.LayoutPoint,
        _ isSVGRoot: Bool,
        _ sharedClipApplied: Bool
    ) {
        paintNonLayerChildInDOMOrderForSVG(
            context: context,
            childRenderer,
            itemIndex,
            accumulatedAncestorOffset,
            layerFragments,
            paintingInfo,
            paintFlags,
            paintBehavior,
            subtreePaintRootForRenderer,
            containerBaseOffset,
            isSVGRoot,
            sharedClipApplied
        )
    }

    func paintNonLayerChildInDOMOrderForSVG(
        context: WebCore.LentGraphicsContext,
        _ childRenderer: WebCore.RenderElement,
        _ itemIndex: UInt32,
        _ accumulatedAncestorOffset: WebCore.LayoutSize,
        _ layerFragments: WebCore.LayerFragments,
        _ paintingInfo: WebCore.RenderLayer.LayerPaintingInfo,
        _ paintFlags: WebCore.RenderLayer.PaintLayerFlags,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ subtreePaintRootForRenderer: WebCore.RenderObject?,
        _ containerBaseOffset: WebCore.LayoutPoint,
        _ isSVGRoot: Bool,
        _ sharedClipApplied: Bool
    ) {
        // phasesToPaint only covers normal painting (Foreground/Outline), so drive the
        // EventRegion phase separately for non-layer children when collecting the event region.
        if paintFlags.contains(.CollectingEventRegion) {
            paintNonLayerChildForFragmentsForSVG(
                childRenderer,
                accumulatedAncestorOffset,
                .EventRegion,
                layerFragments,
                context,
                paintingInfo,
                paintBehavior,
                subtreePaintRootForRenderer,
                containerBaseOffset,
                isSVGRoot,
                sharedClipApplied
            )
            return
        }

        // The list holds Foreground and Outline, or SelfOutline; an OptionSet iterates them in this order.
        let phasesToPaint = childPhasesToPaintInDOMOrderForSVG(itemIndex)
        for phase in [WebCore.PaintPhase.Foreground, .Outline, .SelfOutline] where phasesToPaint.contains(phase) {
            if (phase == .Outline || phase == .SelfOutline) && !childRenderer.hasOutline() {
                continue
            }
            paintNonLayerChildForFragmentsForSVG(
                childRenderer,
                accumulatedAncestorOffset,
                phase,
                layerFragments,
                context,
                paintingInfo,
                paintBehavior,
                subtreePaintRootForRenderer,
                containerBaseOffset,
                isSVGRoot,
                sharedClipApplied
            )
        }
    }

    @cxx
    @implementation
    public func invalidateEnclosingSVGContainerSegmentation() {
        if !isSVGLayer() {
            return
        }
        // This layer's composited-child status in its enclosing SVG container may have changed, so that
        // container has to recompute its paint-order segments.
        var current = paintOrderParentLayer()
        while let layer = current {
            if let target = layer.repaintTarget() {
                target.setNeedsCompositingConfigurationUpdate()
                return
            }
            current = layer.paintOrderParentLayer()
        }
    }
}

private func overflowControlsCornerRect(
    _ positioningRect: WebCore.IntRect,
    _ cornerSize: WebCore.IntSize,
    _ placeVerticalScrollbarOnTheLeft: Bool
) -> WebCore.IntRect {
    if placeVerticalScrollbarOnTheLeft {
        let bottomLeftCorner = positioningRect.minXMaxYCorner()
        // Wraps on overflow, as int arithmetic does in practice.
        return WebCore.IntRect(WebCore.IntPoint(bottomLeftCorner.x(), bottomLeftCorner.y() &- cornerSize.height()), cornerSize)
    }
    return WebCore.IntRect(positioningRect.maxXMaxYCorner() - cornerSize, cornerSize)
}

extension WebCore.RenderLayerScrollableArea {
    // MARK: Overflow controls geometry

    @cxx
    @implementation
    public func overflowControlsRects() -> WebCore.RenderLayer.OverflowControlRects {
        let renderBox = m_layer.renderer().asRenderBox()!
        // Scrollbars sit inside the border box.
        let overflowControlsPositioningRect = WebCore.snappedIntRect(renderBox.paddingBoxRectIncludingScrollbar())

        let hBar = m_hBar.get()
        let vBar = m_vBar.get()
        let horizontalScrollbarHeight: Int32 = hBar?.height() ?? 0
        let verticalScrollbarWidth: Int32 = vBar?.width() ?? 0

        let haveNonOverlayHorizontalScrollbar = hBar.map { !$0.isOverlayScrollbar() } ?? false
        let haveNonOverlayVerticalScrollbar = vBar.map { !$0.isOverlayScrollbar() } ?? false
        let placeVerticalScrollbarOnTheLeft = shouldPlaceVerticalScrollbarOnLeft()
        let haveResizer = renderBox[.Style].hasResize() && renderBox[.Style].pseudoElementType().value == nil
        let scrollbarsAvoidCorner =
            ((haveNonOverlayHorizontalScrollbar && haveNonOverlayVerticalScrollbar)
                || (haveResizer && (haveNonOverlayHorizontalScrollbar || haveNonOverlayVerticalScrollbar)))
            && !renderBox[.Style].scrollbarWidthIsNone()

        var cornerSize = WebCore.IntSize()
        if scrollbarsAvoidCorner {
            // If only one scrollbar is present, the corner is square.
            cornerSize = WebCore.IntSize(
                verticalScrollbarWidth != 0 ? verticalScrollbarWidth : horizontalScrollbarHeight,
                horizontalScrollbarHeight != 0 ? horizontalScrollbarHeight : verticalScrollbarWidth
            )
        }

        var result = WebCore.RenderLayer.OverflowControlRects()

        // The edges wrap on overflow, as int arithmetic does in practice.
        if hBar != nil {
            var barRect = overflowControlsPositioningRect
            barRect.shiftYEdgeTo(barRect.maxY() &- horizontalScrollbarHeight)
            if scrollbarsAvoidCorner {
                if placeVerticalScrollbarOnTheLeft {
                    barRect.shiftXEdgeTo(barRect.x() &+ cornerSize.width())
                } else {
                    barRect.contract(cornerSize.width(), 0)
                }
            }

            result.horizontalScrollbar = barRect
        }

        if vBar != nil {
            var barRect = overflowControlsPositioningRect
            if placeVerticalScrollbarOnTheLeft {
                barRect.setWidth(verticalScrollbarWidth)
            } else {
                barRect.shiftXEdgeTo(barRect.maxX() &- verticalScrollbarWidth)
            }

            if scrollbarsAvoidCorner {
                barRect.contract(0, cornerSize.height())
            }

            result.verticalScrollbar = barRect
        }

        if scrollbarsAvoidCorner {
            result.scrollCorner = overflowControlsCornerRect(overflowControlsPositioningRect, cornerSize, placeVerticalScrollbarOnTheLeft)
        }

        if haveResizer {
            if scrollbarsAvoidCorner {
                result.resizer = result.scrollCorner
            } else {
                let scrollbarThickness = WebCore.RenderLayerScrollableArea.themeScrollbarThickness(.Auto)
                result.resizer = overflowControlsCornerRect(
                    overflowControlsPositioningRect,
                    WebCore.IntSize(scrollbarThickness, scrollbarThickness),
                    placeVerticalScrollbarOnTheLeft
                )
            }
        }

        return result
    }

    @cxx
    @implementation
    public func overflowControlsIntersectRect(_ localRect: WebCore.IntRect) -> Bool {
        let rects = overflowControlsRects()

        if rects.horizontalScrollbar.intersects(localRect) {
            return true
        }

        if rects.verticalScrollbar.intersects(localRect) {
            return true
        }

        if rects.scrollCorner.intersects(localRect) {
            return true
        }

        if rects.resizer.intersects(localRect) {
            return true
        }

        return false
    }

    @cxx
    @implementation
    public func scrollCornerRect() -> WebCore.IntRect {
        overflowControlsRects().scrollCorner
    }

    @cxx
    @implementation
    public func isScrollCornerVisible() -> Bool {
        assert(m_layer.renderer().isRenderBox())
        return !overflowControlsRects().scrollCorner.isEmpty()
    }

    @cxx
    @implementation
    public func verticalScrollbarWidth(_ relevancy: WebCore.OverlayScrollbarSizeRelevancy, _ isHorizontalWritingMode: Bool) -> Int32 {
        let vBar = m_vBar.get()
        if let vBar, vBar.isOverlayScrollbar() && (relevancy == .IgnoreOverlayScrollbarSize || !vBar.shouldParticipateInHitTesting()) {
            return 0
        }

        if vBar == nil && isHorizontalWritingMode
            && !(scrollbarGutterStyle().isAuto() || WebCore.RenderLayerScrollableArea.themeUsesOverlayScrollbars())
        {
            return WebCore.RenderLayerScrollableArea.themeScrollbarThickness(scrollbarWidthStyle())
        }

        guard let vBar, showsOverflowControls() else {
            return 0
        }

        return vBar.width()
    }

    @cxx
    @implementation
    public func horizontalScrollbarHeight(_ relevancy: WebCore.OverlayScrollbarSizeRelevancy, _ isHorizontalWritingMode: Bool) -> Int32 {
        let hBar = m_hBar.get()
        if let hBar, hBar.isOverlayScrollbar() && (relevancy == .IgnoreOverlayScrollbarSize || !hBar.shouldParticipateInHitTesting()) {
            return 0
        }

        if hBar == nil && !isHorizontalWritingMode
            && !(scrollbarGutterStyle().isAuto() || WebCore.RenderLayerScrollableArea.themeUsesOverlayScrollbars())
        {
            return WebCore.RenderLayerScrollableArea.themeScrollbarThickness(scrollbarWidthStyle())
        }

        guard let hBar, showsOverflowControls() else {
            return 0
        }

        return hBar.height()
    }

    // MARK: Scroll extent

    @cxx
    @implementation
    public func visibleSize() -> WebCore.IntSize {
        m_layer.visibleSize()
    }

    @cxx
    @implementation
    public func contentsSize() -> WebCore.IntSize {
        WebCore.IntSize(scrollWidth(), scrollHeight())
    }

    @cxx
    @implementation
    public func reachableTotalContentsSize() -> WebCore.IntSize {
        reachableContentsSize()
    }

    // reachableTotalContentsSize(), which Swift resolves to ScrollableArea's.
    private func reachableContentsSize() -> WebCore.IntSize {
        var contentsSize = self.contentsSize()

        if !hasScrollableHorizontalOverflow() {
            contentsSize.setWidth(min(contentsSize.width(), m_layer.visibleSize().width()))
        }

        if !hasScrollableVerticalOverflow() {
            contentsSize.setHeight(min(contentsSize.height(), m_layer.visibleSize().height()))
        }

        return contentsSize
    }

    // MARK: Scrollability

    @cxx
    @implementation
    public func forceUpdateScrollbarsOnMainThreadForPerformanceTesting() -> Bool {
        m_layer.renderer().settings().scrollingPerformanceTestingEnabled()
    }

    // FIXME: this is only valid after we've made layers.
    @cxx
    @implementation
    public func usesAsyncScrolling() -> Bool {
        m_layer.compositor().useCoordinatedScrollingForLayer(m_layer)
    }

    @cxx
    @implementation
    public func computeScrollDimensions() {
        m_scrollDimensionsDirty = false

        let box = m_layer.renderBox()!

        let overflowRect = box.layoutOverflowRect()

        m_scrollWidth = WebCore.roundToInt(overflowRect.width())
        m_scrollHeight = WebCore.roundToInt(overflowRect.height())

        computeScrollOrigin()
        computeHasCompositedScrollableOverflow(.Yes)
    }

    @cxx
    @implementation
    public func computeHasCompositedScrollableOverflow(_ layoutUpToDate: WebCore.LayoutUpToDate) {
        var hasCompositedScrollableOverflow = m_hasCompositedScrollableOverflow

        switch layoutUpToDate {
        case .No:
            // If layout is not up to date, the only thing we can reliably know is that style prevents overflow scrolling.
            if !canUseCompositedScrolling() {
                hasCompositedScrollableOverflow = false
            }
        case .Yes:
            hasCompositedScrollableOverflow =
                canUseCompositedScrolling() && (hasScrollableHorizontalOverflow() || hasScrollableVerticalOverflow())
        @unknown default:
            break
        }

        if hasCompositedScrollableOverflow == m_hasCompositedScrollableOverflow {
            return
        }

        m_layer.setSelfAndDescendantsNeedPositionUpdate()

        // Whether this layer does composited scrolling affects the configuration of descendant sticky layers. We have to
        // dirty from the enclosing stacking context because overflow scroll doesn't create stacking context so those
        // containing block descendants may not be paint-order descendants, and the compositing dirty bits on RenderLayer act in paint
        // order.
        if let paintParent = m_layer.stackingContext() {
            paintParent.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
        }

        m_hasCompositedScrollableOverflow = hasCompositedScrollableOverflow
        if m_hasCompositedScrollableOverflow {
            m_layer.compositor().layerGainedCompositedScrollableOverflow(m_layer)
        }
    }

    @cxx
    @implementation
    public func updateCompositingLayersAfterScroll() {
        if m_layer.compositor().hasContentCompositingLayers() {
            // Our stacking container is guaranteed to contain all of our descendants that may need
            // repositioning, so update compositing layers from there.
            if let compositingAncestor = m_layer.stackingContext()!.enclosingCompositingLayer() {
                // usesCompositedScrolling(), which Swift resolves to ScrollableArea's.
                if hasCompositedScrollableOverflow() && m_layer.isComposited() {
                    _ = m_layer.compositor().updateCompositingLayers(.OnCompositedScroll, compositingAncestor)
                } else {
                    // FIXME: would be nice to only dirty layers whose positions were affected by scrolling.
                    compositingAncestor.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
                    _ = m_layer.compositor().updateCompositingLayers(.OnScroll, compositingAncestor)
                }
            }
        }
    }

    @cxx
    @implementation
    public func updateScrollbarSteps() {
        if m_hBar.get() == nil && m_vBar.get() == nil {
            return
        }

        let box = m_layer.renderBox()!

        var paddedLayerBounds = WebCore.LayoutRect(
            WebCore.LayoutUnit(),
            WebCore.LayoutUnit(),
            box.paddingBoxWidth(),
            box.paddingBoxHeight()
        )
        paddedLayerBounds.contract(box.scrollPaddingForViewportRect(paddedLayerBounds))

        // Set up the  page step/line step.
        if let hBar = m_hBar.get() {
            let width = WebCore.roundToInt(paddedLayerBounds.width())
            hBar.setSteps(WebCore.Scrollbar.pixelsPerLineStep(width), WebCore.Scrollbar.pageStep(width))
        }
        if let vBar = m_vBar.get() {
            let height = WebCore.roundToInt(paddedLayerBounds.height())
            vBar.setSteps(WebCore.Scrollbar.pixelsPerLineStep(height), WebCore.Scrollbar.pageStep(height))
        }
    }

    @cxx
    @implementation
    public func scrollWidth() -> Int32 {
        assert(m_layer.renderBox() != nil)
        if m_scrollDimensionsDirty {
            computeScrollDimensions()
        }
        // FIXME: This should use snappedIntSize() instead with absolute coordinates.
        return m_scrollWidth
    }

    @cxx
    @implementation
    public func scrollHeight() -> Int32 {
        assert(m_layer.renderBox() != nil)
        if m_scrollDimensionsDirty {
            computeScrollDimensions()
        }
        // FIXME: This should use snappedIntSize() instead with absolute coordinates.
        return m_scrollHeight
    }

    @cxx
    @implementation
    public func hasScrollableHorizontalOverflow() -> Bool {
        hasHorizontalOverflow() && m_layer.renderBox()!.scrollsOverflowX()
    }

    @cxx
    @implementation
    public func hasScrollableVerticalOverflow() -> Bool {
        hasVerticalOverflow() && m_layer.renderBox()!.scrollsOverflowY()
    }

    @cxx
    @implementation
    public func hasHorizontalOverflow() -> Bool {
        assert(!m_scrollDimensionsDirty)

        return scrollWidth() > WebCore.roundToInt(m_layer.renderBox()!.paddingBoxWidth())
    }

    @cxx
    @implementation
    public func hasVerticalOverflow() -> Bool {
        assert(!m_scrollDimensionsDirty)

        return scrollHeight() > WebCore.roundToInt(m_layer.renderBox()!.paddingBoxHeight())
    }

    @cxx
    @implementation
    public func showsOverflowControls() -> Bool {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
        // On iOS, the scrollbars are made in the UI process.
        return !canUseCompositedScrolling()
        #else
        return true
        #endif
    }

    @cxx
    @implementation
    public func canUseCompositedScrolling() -> Bool {
        let renderer = m_layer.renderer()
        let isVisible = renderer.usedVisibility() == .Visible
        if renderer.settings().asyncOverflowScrollingEnabled() {
            return isVisible && scrollsOverflow() && !m_layer.insideSVGForeignObject()
        }

        return false
    }

    @cxx
    @implementation
    public func usesCompositedScrolling() -> Bool {
        hasCompositedScrollableOverflow() && m_layer.isComposited()
    }

    @cxx
    @implementation
    public func useDarkAppearance() -> Bool {
        m_layer.renderer().useDarkAppearance()
    }

    @cxx
    @implementation
    public func scrollsOverflow() -> Bool {
        m_layer.renderer().asRenderBox()?.scrollsOverflow() ?? false
    }

    @cxx
    @implementation
    public func isScrollableOrRubberbandable() -> Bool {
        m_layer.renderer().isScrollableOrRubberbandableBox()
    }

    @cxx
    @implementation
    public func hasScrollableOrRubberbandableAncestor() -> Bool {
        var nextLayer = m_layer.enclosingContainingBlockLayer(WebCore.CrossFrameBoundaries(rawValue: true))
        while let layer = nextLayer {
            if layer.renderer().isScrollableOrRubberbandableBox() {
                return true
            }
            nextLayer = layer.enclosingContainingBlockLayer(WebCore.CrossFrameBoundaries(rawValue: true))
        }

        return false
    }

    @cxx
    @implementation
    public func scrollbarThumbColorStyle() -> WebCore.Color {
        if let renderer = m_layer.renderBox() {
            return renderer[.Style].usedScrollbarThumbColor()
        }
        return WebCore.Color()
    }

    @cxx
    @implementation
    public func scrollbarTrackColorStyle() -> WebCore.Color {
        if let renderer = m_layer.renderBox() {
            return renderer[.Style].usedScrollbarTrackColor()
        }
        return WebCore.Color()
    }

    @cxx
    @implementation
    public func hitTestOverflowControls(_ result: WebCore.HitTestResultView, _ localPoint: WebCore.IntPoint) -> Bool {
        hitTestOverflowControls(result: &result.pointee, localPoint)
    }

    func hitTestOverflowControls(result: inout WebCore.HitTestResult, _ localPoint: WebCore.IntPoint) -> Bool {
        if m_hBar.get() == nil && m_vBar.get() == nil && !m_layer.canResize() {
            return false
        }

        let rects = overflowControlsRects()

        if m_layer.renderer()[.Style].hasResize() {
            if rects.resizer.contains(localPoint) {
                return true
            }
        }

        // FIXME: We should hit test the m_scrollCorner and pass it back through the result.
        if let vBar = m_vBar.get(), vBar.shouldParticipateInHitTesting() {
            if rects.verticalScrollbar.contains(localPoint) {
                result.setScrollbarForSwift(vBar)
                return true
            }
        }

        if let hBar = m_hBar.get(), hBar.shouldParticipateInHitTesting() {
            if rects.horizontalScrollbar.contains(localPoint) {
                result.setScrollbarForSwift(hBar)
                return true
            }
        }

        return false
    }

    @inline(never)
    func hitTestResizerInFragments(
        _ layerFragments: WebCore.LayerFragments,
        _ hitTestLocation: WebCore.HitTestLocation,
        _ pointInFragment: inout WebCore.LayoutPoint
    ) -> Bool {
        if layerFragments.isEmpty() {
            return false
        }

        let renderer = m_layer.renderer()
        if !renderer.visibleToHitTesting(.init()) {
            return false
        }

        let borderBoxRect = WebCore.snappedIntRect(renderer.asRenderBox()!.borderBoxRect())
        let rects = overflowControlsRects()
        let placesVerticalScrollbarOnLeft = shouldPlaceVerticalScrollbarOnLeft()

        func cornerRectInFragment(_ fragmentBounds: WebCore.IntRect, _ resizerRect: WebCore.IntRect) -> WebCore.IntRect {
            if placesVerticalScrollbarOnLeft {
                let offsetFromBottomLeft = borderBoxRect.minXMaxYCorner() - resizerRect.minXMaxYCorner()
                return WebCore.IntRect(
                    fragmentBounds.minXMaxYCorner() - offsetFromBottomLeft - WebCore.IntSize(0, resizerRect.height()),
                    resizerRect.size()
                )
            }
            let offsetFromBottomRight = borderBoxRect.maxXMaxYCorner() - resizerRect.maxXMaxYCorner()
            return WebCore.IntRect(fragmentBounds.maxXMaxYCorner() - offsetFromBottomRight - resizerRect.size(), resizerRect.size())
        }

        var index = Int(layerFragments.size())
        while index > 0 {
            index -= 1
            let fragment = layerFragments[index]
            let resizerRectInFragment = cornerRectInFragment(WebCore.snappedIntRect(fragment.layerBounds()), rects.resizer)
            if fragment.dirtyBackgroundRect().intersects(hitTestLocation) && resizerRectInFragment.contains(hitTestLocation.roundedPoint())
            {
                pointInFragment = WebCore.toLayoutPoint(hitTestLocation.point() - fragment.layerBounds().location())
                return true
            }
        }

        return false
    }

    // MARK: Scrollbar presence

    @cxx
    @implementation
    public func updateScrollbarPresenceAndState(
        _ hasHorizontalOverflow: WebCore.RenderLayerScrollableArea.OptionalBool,
        _ hasVerticalOverflow: WebCore.RenderLayerScrollableArea.OptionalBool
    ) {
        let box = m_layer.renderBox()!

        enum ScrollbarState {
            case noScrollbar
            case enabled
            case disabled
        }

        func stateForScrollbar(
            _ orientation: WebCore.ScrollbarOrientation,
            _ hasOverflow: Bool?,
            _ nonScrollableState: ScrollbarState
        ) -> ScrollbarState {
            if let hasOverflow {
                return hasOverflow ? .enabled : nonScrollableState
            }

            // If we don't have information about overflow (because we haven't done layout yet), just return the current state of the
            // scrollbar.
            let existingScrollbar = orientation == .Horizontal ? m_hBar.get() : m_vBar.get()
            return (existingScrollbar?.enabled() ?? false) ? .enabled : nonScrollableState
        }

        func stateForScrollbarOnAxis(_ orientation: WebCore.ScrollbarOrientation, _ hasOverflow: Bool?) -> ScrollbarState {
            if box.hasAlwaysPresentScrollbar(orientation) {
                return stateForScrollbar(orientation, hasOverflow, .disabled)
            }

            if box.hasAutoScrollbar(orientation) {
                return stateForScrollbar(orientation, hasOverflow, .noScrollbar)
            }

            return .noScrollbar
        }

        let horizontalBarState = stateForScrollbarOnAxis(.Horizontal, hasHorizontalOverflow.value)
        setHasHorizontalScrollbar(horizontalBarState != .noScrollbar)
        if horizontalBarState != .noScrollbar {
            m_hBar.get()!.setEnabled(horizontalBarState == .enabled)
        }

        let verticalBarState = stateForScrollbarOnAxis(.Vertical, hasVerticalOverflow.value)
        setHasVerticalScrollbar(verticalBarState != .noScrollbar)
        if verticalBarState != .noScrollbar {
            m_vBar.get()!.setEnabled(verticalBarState == .enabled)
        }
    }

    @cxx
    @implementation
    public func horizontalNativeScrollbarVisibility() -> WebCore.NativeScrollbarVisibility {
        WebCore.Scrollbar.nativeScrollbarVisibility(m_hBar.get())
    }

    @cxx
    @implementation
    public func verticalNativeScrollbarVisibility() -> WebCore.NativeScrollbarVisibility {
        WebCore.Scrollbar.nativeScrollbarVisibility(m_vBar.get())
    }

    @cxx
    @implementation
    public func scrollingMayRevealBackground() -> Bool {
        // usesCompositedScrolling(), which Swift resolves to ScrollableArea's.
        scrollsOverflow() || (hasCompositedScrollableOverflow() && m_layer.isComposited())
    }

    // MARK: Settings and descriptions

    @cxx
    @implementation
    public func mockScrollbarsControllerEnabled() -> Bool {
        m_layer.renderer().settings().mockScrollbarsControllerEnabled()
    }

    @cxx
    @implementation
    public func deviceScaleFactor() -> Float {
        m_layer.renderer().document().deviceScaleFactor()
    }

    @cxx
    @implementation
    public func debugDescription() -> WTF.String {
        // Also called while the layer is destroyed (ScrollAnchoringController's logging): reading m_layer would retain it.
        layerDebugDescriptionForSwift()
    }

    // MARK: Overflow controls positioning and scrollbars

    @cxx
    @implementation
    public func hasOverflowControls() -> Bool {
        m_hBar.get() != nil || m_vBar.get() != nil || scrollCornerForSwift() != nil || m_layer.renderer()[.Style].hasResize()
    }

    @cxx
    @implementation
    public func positionOverflowControls(_ offsetFromRoot: WebCore.IntSize) -> Bool {
        if m_hBar.get() == nil && m_vBar.get() == nil && !m_layer.canResize() {
            return false
        }

        if m_layer.renderBox() == nil {
            return false
        }

        var rects = overflowControlsRects()
        var changed = false

        if let vBar = m_vBar.get() {
            rects.verticalScrollbar.move(offsetFromRoot)
            if !isSameIntRect(vBar.frameRect(), rects.verticalScrollbar) {
                vBar.setFrameRect(rects.verticalScrollbar)
                changed = true
            }
        }

        if let hBar = m_hBar.get() {
            rects.horizontalScrollbar.move(offsetFromRoot)
            if !isSameIntRect(hBar.frameRect(), rects.horizontalScrollbar) {
                hBar.setFrameRect(rects.horizontalScrollbar)
                changed = true
            }
        }

        if let scrollCorner = scrollCornerForSwift(),
            !isSameLayoutRect(scrollCorner.borderBoxRectInContainer(), WebCore.LayoutRect(rects.scrollCorner))
        {
            scrollCorner.setBorderBoxInContainer(WebCore.LayoutRect(rects.scrollCorner))
            changed = true
        }

        if let resizer = resizerForSwift(), !isSameLayoutRect(resizer.borderBoxRectInContainer(), WebCore.LayoutRect(rects.resizer)) {
            resizer.setBorderBoxInContainer(WebCore.LayoutRect(rects.resizer))
            changed = true
        }
        return changed
    }

    @cxx
    @implementation
    public func computeScrollOrigin() {
        let box = m_layer.renderBox()!

        var overflowRect = box.layoutOverflowRect()
        box.blockStartRelativeToPhysical(&overflowRect)

        // Wraps on overflow, as int arithmetic does in practice.
        var scrollableLeftOverflow = WebCore.roundToInt(overflowRect.x() - box.borderLeft())
        if shouldPlaceVerticalScrollbarOnLeft() {
            scrollableLeftOverflow =
                scrollableLeftOverflow &- verticalScrollbarWidth(.IgnoreOverlayScrollbarSize, box.writingMode().isHorizontal())
        }

        let scrollableTopOverflow = WebCore.roundToInt(overflowRect.y() - box.borderTop())
        setScrollOriginForSwift(WebCore.IntPoint(0 &- scrollableLeftOverflow, 0 &- scrollableTopOverflow))

        // Horizontal scrollbar offsets depend on the scroll origin when vertical
        // scrollbars are on the left.
        if let hBar = m_hBar.get() {
            hBar.offsetDidChange()
        }
    }

    #if os(macOS) // HAVE(RUBBER_BANDING)
    // HAVE(RUBBER_BANDING)
    private func scrollElasticityForNewScrollbar() -> WebCore.ScrollElasticity {
        scrollsOverflow() && m_layer.renderer().settings().rubberBandingForSubScrollableRegionsEnabled() ? .Automatic : .None
    }
    #endif

    @cxx
    @implementation
    public func setHasHorizontalScrollbar(_ hasScrollbar: Bool) {
        if hasScrollbar == (m_hBar.get() != nil) {
            return
        }

        if hasScrollbar {
            m_hBar = .init(createScrollbar(.Horizontal).get())
            #if os(macOS) // HAVE(RUBBER_BANDING)
            setHorizontalScrollElasticityForSwift(scrollElasticityForNewScrollbar())
            #endif
        } else {
            destroyScrollbar(.Horizontal)
            #if os(macOS) // HAVE(RUBBER_BANDING)
            setHorizontalScrollElasticityForSwift(.None)
            #endif
        }

        // Destroying or creating one bar can cause our scrollbar corner to come and go. We need to update the opposite scrollbar's style.
        if let hBar = m_hBar.get() {
            hBar.styleChanged()
        }
        if let vBar = m_vBar.get() {
            vBar.styleChanged()
        }
    }

    @cxx
    @implementation
    public func setHasVerticalScrollbar(_ hasScrollbar: Bool) {
        if hasScrollbar == (m_vBar.get() != nil) {
            return
        }

        if hasScrollbar {
            m_vBar = .init(createScrollbar(.Vertical).get())
            #if os(macOS) // HAVE(RUBBER_BANDING)
            setVerticalScrollElasticityForSwift(scrollElasticityForNewScrollbar())
            #endif
        } else {
            destroyScrollbar(.Vertical)
            #if os(macOS) // HAVE(RUBBER_BANDING)
            setVerticalScrollElasticityForSwift(.None)
            #endif
        }

        // Destroying or creating one bar can cause our scrollbar corner to come and go. We need to update the opposite scrollbar's style.
        if let hBar = m_hBar.get() {
            hBar.styleChanged()
        }
        if let vBar = m_vBar.get() {
            vBar.styleChanged()
        }
    }

    @cxx
    @implementation
    public func destroyScrollbar(_ orientation: WebCore.ScrollbarOrientation) {
        guard let scrollbar = orientation == .Horizontal ? m_hBar.get() : m_vBar.get() else {
            return
        }

        if !scrollbar.isCustomScrollbar() {
            willRemoveScrollbarForSwift(scrollbar, orientation)
        }

        scrollbar.removeFromParent()
        if orientation == .Horizontal {
            m_hBar = .init()
        } else {
            m_vBar = .init()
        }
    }

    @cxx
    @implementation
    public func overhangAmount() -> WebCore.IntSize {
        #if os(macOS) // HAVE(RUBBER_BANDING)
        // HAVE(RUBBER_BANDING)
        let renderer = m_layer.renderer()
        if !renderer.settings().rubberBandingForSubScrollableRegionsEnabled() {
            return WebCore.IntSize()
        }

        var stretch = WebCore.IntSize()

        // FIXME: use maximumScrollOffset(), or just move this to ScrollableArea.
        let scrollOffset = scrollOffsetFromPositionForSwift(scrollPosition())
        let reachableSize = reachableContentsSize()
        let visibleSize = m_layer.visibleSize()
        // Wraps on overflow, as int arithmetic does in practice.
        if scrollOffset.y() < 0 {
            stretch.setHeight(scrollOffset.y())
        } else if reachableSize.height() != 0 && scrollOffset.y() > reachableSize.height() &- visibleSize.height() {
            stretch.setHeight(scrollOffset.y() &- (reachableSize.height() &- visibleSize.height()))
        }

        if scrollOffset.x() < 0 {
            stretch.setWidth(scrollOffset.x())
        } else if reachableSize.width() != 0 && scrollOffset.x() > reachableSize.width() &- visibleSize.width() {
            stretch.setWidth(scrollOffset.x() &- (reachableSize.width() &- visibleSize.width()))
        }

        return stretch
        #else
        return WebCore.IntSize()
        #endif
    }

    // MARK: Overflow controls painting

    @cxx
    @implementation
    public func paintOverflowControls(
        _ context: WebCore.LentGraphicsContext,
        _ paintBehavior: WebCore.RenderLayer.PaintBehaviors,
        _ paintOffset: WebCore.IntPoint,
        _ damageRect: WebCore.IntRect,
        _ paintingOverlayControls: Bool
    ) {
        // Don't do anything if we have no overflow.
        let renderer = m_layer.renderer()
        if !renderer.hasNonVisibleOverflow() {
            return
        }

        if !showsOverflowControls() {
            return
        }

        // Overlay scrollbars paint in a second pass through the layer tree so that they will paint
        // on top of everything else. If this is the normal painting pass, paintingOverlayControls
        // will be false, and we should just tell the root layer that there are overlay scrollbars
        // that need to be painted. That will cause the second pass through the layer tree to run,
        // and we'll paint the scrollbars then. In the meantime, cache tx and ty so that the
        // second pass doesn't need to re-enter the RenderTree to get it right.
        if hasOverlayScrollbars() && !paintingOverlayControls {
            m_cachedOverlayScrollbarOffset = paintOffset

            // It's not necessary to do the second pass if the scrollbars paint into layers.
            if (m_hBar.get() != nil && layerForHorizontalScrollbar() != nil) || (m_vBar.get() != nil && layerForVerticalScrollbar() != nil)
            {
                return
            }
            var localDamageRect = damageRect
            // Wraps at INT_MIN, as int negation does in practice.
            localDamageRect.moveBy(WebCore.IntPoint(0 &- paintOffset.x(), 0 &- paintOffset.y()))
            if !overflowControlsIntersectRect(localDamageRect) {
                return
            }

            let paintingRoot = m_layer.enclosingCompositingLayer() ?? renderer.view().layer()!

            if let scrollableArea = paintingRoot.scrollableArea() {
                scrollableArea.setContainsDirtyOverlayScrollbars(true)
            }
            return
        }

        // This check is required to avoid painting custom CSS scrollbars twice.
        if paintingOverlayControls && !hasOverlayScrollbars() {
            return
        }

        var adjustedPaintOffset = paintOffset
        if paintingOverlayControls {
            adjustedPaintOffset = m_cachedOverlayScrollbarOffset
        }

        var controlRects: WebCore.RenderLayer.OverflowControlRects? = nil

        func paintScrollBarIfNecessary(_ scrollbar: WebCore.Scrollbar?, _ damageRect: WebCore.IntRect) {
            guard let scrollbar else {
                return
            }

            let layerForScrollbar = scrollbar.orientation() == .Horizontal ? layerForHorizontalScrollbar() : layerForVerticalScrollbar()
            if layerForScrollbar != nil && !paintBehavior.contains(.FlattenCompositingLayers) {
                return
            }

            if controlRects == nil {
                controlRects = overflowControlsRects()
            }

            let contentPaintOffset = adjustedPaintOffset + controlRects!.scrollbarRect(scrollbar.orientation()).location()
            let widgetLocation = scrollbar.location()
            let widgetPaintOffset = contentPaintOffset - widgetLocation

            var damageRect = damageRect
            var saved = false
            defer {
                if saved {
                    context.restore()
                }
            }

            if !widgetPaintOffset.isZero() {
                context.save()
                saved = true
                context.translate(WebCore.FloatSize(widgetPaintOffset))
                // Wraps at INT_MIN, as int negation does in practice.
                damageRect.move(0 &- widgetPaintOffset.width(), 0 &- widgetPaintOffset.height())
            }

            var scrollbarPaintBehavior = WebCore.RenderLayerScrollableArea.ScrollbarPaintBehaviors()
            if paintBehavior.contains(.Snapshotting) {
                scrollbarPaintBehavior.add(WebCore.RenderLayerScrollableArea.ScrollbarPaintBehaviors(.Snapshot))
            }
            WebCore.RenderLayerScrollableArea.paintScrollbar(scrollbar, context, damageRect, scrollbarPaintBehavior)
        }

        paintScrollBarIfNecessary(m_hBar.get(), damageRect)
        paintScrollBarIfNecessary(m_vBar.get(), damageRect)

        if layerForScrollCorner() != nil && !paintBehavior.contains(.FlattenCompositingLayers) {
            return
        }

        let rects = controlRects ?? overflowControlsRects()

        // We fill our scroll corner with white if we have a scrollbar that doesn't run all the way up to the
        // edge of the box.
        paintScrollCorner(context, adjustedPaintOffset, rects.scrollCorner, damageRect)

        // Paint our resizer last, since it sits on top of the scroll corner.
        paintResizer(context, WebCore.LayoutPoint(adjustedPaintOffset), rects.resizer, WebCore.LayoutRect(damageRect))
    }

    // MARK: Scroll state

    @cxx
    @implementation
    public func restoreScrollPosition() {
        guard let element = m_layer.renderer().element() else {
            return
        }

        if m_layer.renderBox() != nil {
            // We save and restore only the scrollOffset as the other scroll values are recalculated.
            m_scrollPosition = element.savedLayerScrollPosition()
            if !m_scrollPosition.isZero() {
                setScrollAnimatorCurrentPosition(m_scrollPosition)
            }
        }

        element.setSavedLayerScrollPosition(WebCore.ScrollPosition())
    }

    @cxx
    @implementation
    public func isUserScrollInProgress() -> Bool {
        userScrollInProgress()
    }

    // ScrollableArea's overrides that Swift calls on self: a call by the member's name resolves to ScrollableArea's.
    func userScrollInProgress() -> Bool {
        if !scrollsOverflow() {
            return false
        }

        if let scrollingCoordinator = m_layer.page().scrollingCoordinator() {
            if scrollingCoordinator.isUserScrollInProgress(scrollingNodeID()) {
                return true
            }
        }

        return existingScrollAnimatorIsUserScrollInProgress()
    }

    @cxx
    @implementation
    public func isRubberBandInProgress() -> Bool {
        rubberBandInProgress()
    }

    func rubberBandInProgress() -> Bool {
        #if os(macOS) // HAVE(RUBBER_BANDING)
        // HAVE(RUBBER_BANDING)
        if !scrollsOverflow() {
            return false
        }

        if let scrollingCoordinator = m_layer.page().scrollingCoordinator() {
            if scrollingCoordinator.isRubberBandInProgress(scrollingNodeID()) {
                return true
            }
        }

        return existingScrollAnimatorIsRubberBandInProgress()
        #else
        return false
        #endif
    }

    @cxx
    @implementation
    public func isScrollSnapInProgress() -> Bool {
        if !scrollsOverflow() {
            return false
        }

        if let scrollingCoordinator = m_layer.page().scrollingCoordinator() {
            if scrollingCoordinator.isScrollSnapInProgress(scrollingNodeID()) {
                return true
            }
        }

        return existingScrollAnimatorIsScrollSnapInProgress()
    }

    // MARK: Overflow controls invalidation

    @cxx
    @implementation
    public func scrollbarOffset(_ scrollbar: borrowing WebCore.Scrollbar) -> WebCore.IntSize {
        let rects = overflowControlsRects()

        if WebCore.RenderLayerScrollableArea.isSameScrollbar(copy scrollbar, m_vBar.get()) {
            return WebCore.toIntSize(rects.verticalScrollbar.location())
        }

        if WebCore.RenderLayerScrollableArea.isSameScrollbar(copy scrollbar, m_hBar.get()) {
            return WebCore.toIntSize(rects.horizontalScrollbar.location())
        }

        assertionFailure()
        return WebCore.IntSize()
    }

    @cxx
    @implementation
    public func invalidateScrollbarRectInLayer(_ scrollbar: borrowing WebCore.Scrollbar, _ rect: WebCore.IntRect) {
        if !showsOverflowControls() {
            return
        }

        let isVerticalScrollbar = WebCore.RenderLayerScrollableArea.isSameScrollbar(copy scrollbar, m_vBar.get())
        if isVerticalScrollbar {
            if let layer = layerForVerticalScrollbar() {
                layer.setNeedsDisplayInRect(WebCore.FloatRect(rect), .Clip)
                return
            }
        } else {
            if let layer = layerForHorizontalScrollbar() {
                layer.setNeedsDisplayInRect(WebCore.FloatRect(rect), .Clip)
                return
            }
        }

        var scrollRect = rect
        let box = m_layer.renderBox()!
        // If we are not yet inserted into the tree, there is no need to repaint.
        if parentRendererOfRenderObject(box) == nil {
            return
        }

        let rects = overflowControlsRects()

        if isVerticalScrollbar {
            scrollRect.moveBy(rects.verticalScrollbar.location())
        } else {
            scrollRect.moveBy(rects.horizontalScrollbar.location())
        }

        var repaintRect = WebCore.LayoutRect(scrollRect)
        box.physicalToBlockStartRelative(&repaintRect)
        box.repaintRectangle(repaintRect, true)
    }

    @cxx
    @implementation
    public func invalidateScrollCornerRectInLayer(_ rect: WebCore.IntRect) {
        if !showsOverflowControls() {
            return
        }

        if layerForScrollCorner() != nil {
            invalidateScrollCornerForSwift(rect)
            return
        }

        if let scrollCorner = scrollCornerForSwift() {
            scrollCorner.repaintRectangle(WebCore.LayoutRect(rect), true)
        }
        if let resizer = resizerForSwift() {
            resizer.repaintRectangle(WebCore.LayoutRect(rect), true)
        }
    }

    @cxx
    @implementation
    public func canShowNonOverlayScrollbars() -> Bool {
        canHaveScrollbars() && !(m_layer.renderBox()?.canUseOverlayScrollbars() ?? false)
    }

    // MARK: Scrollbar update

    @cxx
    @implementation
    public func updateScrollbarsAfterStyleChange(_ hasOldStyle: Bool, _ oldStyleShouldPlaceVerticalScrollbarOnLeft: Bool) {
        // Overflow is a box concept.
        guard let box = m_layer.renderBox() else {
            return
        }

        // List box parts handle the scrollbars by themselves so we have nothing to do.
        if box[.Style].usedAppearance() == .Listbox {
            return
        }

        let hadVerticalScrollbar = hasVerticalScrollbar()
        updateScrollbarPresenceAndState(.init(), .init())
        let hasVerticalScrollbar = self.hasVerticalScrollbar()

        if hadVerticalScrollbar != hasVerticalScrollbar
            || (hasVerticalScrollbar && hasOldStyle
                && oldStyleShouldPlaceVerticalScrollbarOnLeft != box[.Style].shouldPlaceVerticalScrollbarOnLeft())
        {
            computeScrollOrigin()
        }

        if !m_scrollDimensionsDirty {
            updateScrollableAreaSet(hasScrollableHorizontalOverflow() || hasScrollableVerticalOverflow())
        }

        let scrollbarsHaveDarkAppearance = useDarkAppearanceForScrollbars()
        if scrollbarsHaveDarkAppearance != m_useDarkAppearanceForScrollbars {
            m_useDarkAppearanceForScrollbars = scrollbarsHaveDarkAppearance
            m_layer.setNeedsCompositingGeometryUpdate()
            // The scroll corner must be repainted to match the new scrollbar appearance.
            invalidateScrollCornerForSwift(overflowControlsRects().scrollCorner)
        }
    }

    @cxx
    @implementation
    public func updateAllScrollbarRelatedStyle() {
        if let hBar = m_hBar.get() {
            hBar.styleChanged()
        }
        if let vBar = m_vBar.get() {
            vBar.styleChanged()
        }
        updateScrollCornerStyle()
        updateResizerStyle()
    }

    // MARK: Scroll position

    @cxx
    @implementation
    public func setPostLayoutScrollPosition(_ position: WebCore.RenderLayerScrollableArea.OptionalScrollPosition) {
        m_postLayoutScrollPosition = position
    }

    @cxx
    @implementation
    public func applyPostLayoutScrollPositionIfNeeded() {
        guard let position = m_postLayoutScrollPosition.value else {
            return
        }

        m_postLayoutScrollPosition = .init()
        _ = scrollToOffset(scrollOffsetFromPositionForSwift(position), .createProgrammatic())
    }

    @cxx
    @implementation
    public func clampScrollOffset(_ scrollOffset: WebCore.ScrollOffset) -> WebCore.ScrollOffset {
        scrollOffset.constrainedBetween(minimumScrollOffset(), maximumScrollOffset())
    }

    @cxx
    @implementation
    public func scrollDidEnd() {
        if !isAwaitingScrollend() {
            return
        }
        setIsAwaitingScrollendForSwift(false)
        if let element = m_layer.renderer().element() {
            element.document().addPendingScrollEventTarget(element, .Scrollend)
        }
    }

    @cxx
    @implementation
    public func visibleContentRectInternal(
        _ scrollbarInclusion: WebCore.RenderLayerScrollableArea.VisibleContentRectIncludesScrollbars,
        _ behavior: WebCore.RenderLayerScrollableArea.VisibleContentRectBehavior
    ) -> WebCore.IntRect {
        var scrollbarSpace = WebCore.IntSize()
        if showsOverflowControls() && scrollbarInclusion == .Yes {
            scrollbarSpace = scrollbarIntrusion()
        }

        let visibleSize = m_layer.visibleSize()
        // Wraps on overflow, as int arithmetic does in practice.
        return WebCore.IntRect(
            scrollPosition(),
            WebCore.IntSize(max(0, visibleSize.width() &- scrollbarSpace.width()), max(0, visibleSize.height() &- scrollbarSpace.height()))
        )
    }

    // MARK: Page and frame queries

    @cxx
    @implementation
    public func shouldSuspendScrollAnimations() -> Bool {
        m_layer.renderer().view().frameView().shouldSuspendScrollAnimations()
    }

    @cxx
    @implementation
    public func lastKnownMousePositionInView() -> WebCore.IntPoint {
        m_layer.renderer().view().frameView().lastKnownMousePositionInView()
    }

    @cxx
    @implementation
    public func scrollAnimatorEnabled() -> Bool {
        m_layer.page().settings().scrollAnimatorEnabled()
    }
}

extension WebCore.RenderLayerScrollableArea {
    // MARK: Scrolling

    @cxx
    @implementation
    public func scrollToXPosition(_ x: Int32, _ options: WebCore.ScrollPositionChangeOptions) {
        let position = WebCore.ScrollPosition(x, m_scrollPosition.y())
        setScrollPosition(position, options)
    }

    @cxx
    @implementation
    public func scrollToYPosition(_ y: Int32, _ options: WebCore.ScrollPositionChangeOptions) {
        let position = WebCore.ScrollPosition(m_scrollPosition.x(), y)
        setScrollPosition(position, options)
    }

    @cxx
    @implementation
    public func setScrollPosition(_ position: WebCore.ScrollPosition, _ options: WebCore.ScrollPositionChangeOptions) {
        _ = scrollToOffset(scrollOffsetFromPositionForSwift(position), options)
    }

    @cxx
    @implementation
    public func scrollTo(_ position: WebCore.ScrollPosition) {
        guard let box = m_layer.renderBox() else {
            return
        }

        let newPosition = position
        if !box.isHTMLMarquee() {
            // Ensure that the dimensions will be computed if they need to be (for overflow:hidden blocks).
            if m_scrollDimensionsDirty {
                computeScrollDimensions()
            }
        }

        if isSameIntPoint(m_scrollPosition, newPosition) && scrollAnimationStatus() == .NotAnimating {
            // FIXME: Nothing guarantees we get a scrollTo() with an unchanged position at the end of a user gesture.
            // The ScrollingCoordinator probably needs to message the main thread when a gesture ends.
            if requiresScrollPositionReconciliation() {
                m_layer.setNeedsCompositingGeometryUpdate()
                updateCompositingLayersAfterScroll()
            }
            return
        }

        m_scrollPosition = newPosition
        m_layer.setSelfAndDescendantsNeedPositionUpdate()

        let renderer = m_layer.renderer()
        if let element = renderer.element() {
            element.setSavedLayerScrollPosition(m_scrollPosition)
        }

        let view = renderer.view()

        // Update the positions of our child layers (if needed as only fixed layers should be impacted by a scroll).
        // We don't update compositing layers, because we need to do a deep update from the compositing ancestor.
        if !view.frameView().isInRenderTreeLayoutForSwift() {
            // If we're in the middle of layout, we'll just update layers once layout has finished.
            view.frameView().updateLayerPositionsAfterOverflowScroll(m_layer)

            if !m_updatingMarqueePosition {
                // Avoid updating compositing layers if, higher on the stack, we're already updating layer
                // positions. Updating layer positions requires a full walk of up-to-date RenderLayers, and
                // in this case we're still updating their positions; we'll update compositing layers later
                // when that completes.
                // usesCompositedScrolling(), which Swift resolves to ScrollableArea's.
                if hasCompositedScrollableOverflow() && m_layer.isComposited() {
                    m_layer.setNeedsCompositingGeometryUpdate()

                    // Scroll position can affect the location of a composited descendant (which may be a sibling in z-order),
                    // so trigger a descendant walk from the stacking context.
                    if let paintParent = m_layer.stackingContext() {
                        paintParent.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
                    }
                }

                updateCompositingLayersAfterScroll()
            }

            // Update regions, scrolling may change the clip of a particular region.
            renderer.document().invalidateRenderingDependentRegions()
            renderer.frame().debugPageOverlaysDidLayoutForSwift()
        }

        let frame = renderer.frame()
        let repaintContainer = renderer.containerForRepaint().renderer.get()
        // The caret rect needs to be invalidated after scrolling
        frame.setCaretRectNeedsUpdateForSwift()

        let rectForRepaint = m_layer.cachedClippedOverflowRect().value ?? renderer.clippedOverflowRectForRepaint(repaintContainer)

        var quadForFakeMouseMoveEvent = WebCore.FloatQuad(floatRect(rectForRepaint))
        if let repaintContainer {
            quadForFakeMouseMoveEvent = repaintContainer.localToAbsoluteQuadForSwift(quadForFakeMouseMoveEvent)
        }
        frame.dispatchFakeMouseMoveEventSoonInQuadForSwift(quadForFakeMouseMoveEvent)

        var requiresRepaint = true
        // usesCompositedScrolling(), which Swift resolves to ScrollableArea's.
        if hasCompositedScrollableOverflow() && m_layer.isComposited() {
            m_layer.setNeedsCompositingGeometryUpdate()
            m_layer.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
            requiresRepaint = m_layer.backing()!.needsRepaintOnCompositedScroll()
        }

        // Just schedule a full repaint of our object.
        if requiresRepaint {
            renderer.repaintUsingContainerForSwift(repaintContainer, rectForRepaint)
            // We also have to repaint any descendant composited layers that have fixed backgrounds.
            m_layer.compositor().repaintSlowRepaintObjectsScrolledByLayer(m_layer)
        }

        // Schedule the scroll and scroll-related DOM events.
        if let element = renderer.element() {
            setIsAwaitingScrollendForSwift(true)
            element.document().addPendingScrollEventTarget(element, .Scroll)
        }

        if scrollsOverflow() {
            view.frameView().didChangeScrollOffset()
        }

        if !view.frameView().isInRenderTreeLayoutForSwift() {
            view.frameView().viewportContentsChanged()
        }

        frame.renderLayerDidScrollForSwift(m_layer)
    }

    @cxx
    @implementation
    public func scrollRectToVisible(_ absoluteRect: WebCore.LayoutRect, _ options: WebCore.ScrollRectToVisibleOptions) -> WebCore.LayoutRect
    {
        let box = m_layer.renderBox()!

        let scrollingViewport = box.paddingBoxRect()

        var scrollPadding = box.scrollPaddingForViewportRect(scrollingViewport)
        if (scrollPadding.valueAt(.Left) + scrollPadding.valueAt(.Right)).rawValue() > scrollingViewport.width().rawValue() {
            let shrinkFactor =
                scrollingViewport.width().toFloat() / (scrollPadding.valueAt(.Left) + scrollPadding.valueAt(.Right)).toFloat()
            scrollPadding.setLeft(scaledLayoutUnit(scrollPadding.valueAt(.Left), shrinkFactor))
            scrollPadding.setRight(scaledLayoutUnit(scrollPadding.valueAt(.Right), shrinkFactor))
        }

        if (scrollPadding.valueAt(.Top) + scrollPadding.valueAt(.Bottom)).rawValue() > scrollingViewport.height().rawValue() {
            let shrinkFactor =
                scrollingViewport.height().toFloat() / (scrollPadding.valueAt(.Top) + scrollPadding.valueAt(.Bottom)).toFloat()
            scrollPadding.setTop(scaledLayoutUnit(scrollPadding.valueAt(.Top), shrinkFactor))
            scrollPadding.setBottom(scaledLayoutUnit(scrollPadding.valueAt(.Bottom), shrinkFactor))
        }

        var scrollingViewportWithPadding = scrollingViewport
        scrollingViewportWithPadding.contract(scrollPadding)

        let localExposeRect = computeLocalExposeRect(absoluteRect, box)
        var localVisiblityRect = WebCore.RenderLayer.OptionalLayoutRect()
        if let visibilityCheckRect = options.visibilityCheckRect.value {
            localVisiblityRect = WebCore.RenderLayer.OptionalLayoutRect(computeLocalExposeRect(visibilityCheckRect, box))
        }

        var revealRect = getRectToExposeForScrollIntoView(
            scrollingViewportWithPadding,
            localExposeRect,
            options.alignX,
            options.alignY,
            localVisiblityRect
        )
        revealRect.move(
            WebCore.LayoutSize(
                WebCore.LayoutUnit() - scrollingViewportWithPadding.x(),
                WebCore.LayoutUnit() - scrollingViewportWithPadding.y()
            )
        )

        var scrollPositionOptions = WebCore.ScrollPositionChangeOptions.createProgrammatic()
        if !box.frame().autoscrollInProgressForSwift(), let element = box.element(), WebCore.useSmoothScrolling(options.behavior, element) {
            scrollPositionOptions.animated = .Yes
        }

        if let result = updateScrollPositionForScrollIntoView(
            scrollPositionOptions,
            WebCore.toLayoutSize(revealRect.location()),
            localExposeRect
        ) {
            return result
        }

        return absoluteRect
    }

    private func updateScrollPositionForScrollIntoView(
        _ options: WebCore.ScrollPositionChangeOptions,
        _ revealOffset: WebCore.LayoutSize,
        _ localExposeRect: WebCore.LayoutRect
    ) -> WebCore.LayoutRect? {
        let box = m_layer.renderBox()!

        let clampedScrollOffset = clampScrollOffset(scrollOffset() + WebCore.roundedIntSize(revealOffset))
        if isSameIntPoint(clampedScrollOffset, scrollOffset()) && scrollAnimationStatus() == .NotAnimating {
            return nil
        }

        let oldScrollOffset = scrollOffset()
        let realScrollOffset = scrollToOffset(clampedScrollOffset, options)

        let scrollOffsetDifference = realScrollOffset - oldScrollOffset
        var localExposeRectScrolled = localExposeRect
        localExposeRectScrolled.move(WebCore.LayoutSize(negatedIntSize(scrollOffsetDifference)))
        return WebCore.LayoutRect(box.localToAbsoluteQuadForSwift(WebCore.FloatQuad(floatRect(localExposeRectScrolled))).boundingBox())
    }

    // MARK: Scrollable area sets

    @cxx
    @implementation
    public func clear() {
        // The layer is being destroyed: reading m_layer would retain it.
        let renderer = layerRendererForSwift()
        if m_registeredScrollableArea {
            _ = removeFromFrameViewScrollableAreas()
        }

        if m_isRegisteredForAnimatedScroll {
            removeFromFrameViewAnimatedScrollAreas()
            m_isRegisteredForAnimatedScroll = false
        }

        updateTouchEventListenerForScrolling(false)
        if let element = renderer.element() {
            element.setSavedLayerScrollPosition(m_scrollPosition)
        }

        destroyScrollbar(.Horizontal)
        destroyScrollbar(.Vertical)

        clearScrollCorner()
        clearResizer()
    }

    @cxx
    @implementation
    public func updateScrollableAreaSet(_ hasOverflow: Bool) {
        let renderer = m_layer.renderer()
        let frameView = renderer.view().frameView()

        var isVisibleToHitTest = renderer.visibleToHitTesting()
        if let owner = frameView.frame().ownerElement() {
            let ownerIsVisibleToHitTest = owner.renderer()?.visibleToHitTesting() ?? false
            isVisibleToHitTest = isVisibleToHitTest && ownerIsVisibleToHitTest
        }

        let needsToBeRegistered = (hasOverflow && isVisibleToHitTest) || scrollAnimationStatus() == .Animating
        var addedOrRemoved = false

        if needsToBeRegistered {
            if !m_registeredScrollableArea {
                addedOrRemoved = addToFrameViewScrollableAreas()
                m_registeredScrollableArea = true
            }
        } else if m_registeredScrollableArea {
            addedOrRemoved = removeFromFrameViewScrollableAreas()
            m_registeredScrollableArea = false
        }

        if addedOrRemoved {
            updateTouchEventListenerForScrolling(needsToBeRegistered)
        }
    }

    @cxx
    @implementation
    public func registerScrollableAreaForAnimatedScroll() {
        if !m_registeredScrollableArea {
            addToFrameViewAnimatedScrollAreas()
            m_isRegisteredForAnimatedScroll = true
        }
    }

    @cxx
    @implementation
    public func animatedScrollDidEnd() {
        if m_isRegisteredForAnimatedScroll {
            m_isRegisteredForAnimatedScroll = false
            removeFromFrameViewAnimatedScrollAreas()
        }
    }

    // MARK: Layout

    // This is called from layout code (before updateLayerPositions).
    @cxx
    @implementation
    public func updateScrollInfoAfterLayoutForScope() -> WebCore.RenderLayerScrollableArea.ScrollInfoAfterLayout {
        guard let box = m_layer.renderBox() else {
            return WebCore.RenderLayerScrollableArea.ScrollInfoAfterLayout()
        }

        m_scrollDimensionsDirty = true
        let originalScrollPosition = scrollPosition()

        computeScrollDimensions()
        m_layer.updateSelfPaintingLayerForScrollableArea()

        // FIXME: Ensure that offsets are also updated in case of programmatic style changes.
        // https://bugs.webkit.org/show_bug.cgi?id=135964
        updateSnapOffsets()

        if !box.isHTMLMarquee() && !rubberBandInProgress() && !userScrollInProgress() {
            // Layout may cause us to be at an invalid scroll position. In this case we need
            // to pull our scroll offsets back to the max (or push them up to the min).
            let scrollOffset = self.scrollOffset()
            if !isSameIntPoint(scrollOffset, minimumScrollOffset()) {
                let clampedScrollOffset = clampScrollOffset(scrollOffset)
                if !isSameIntPoint(clampedScrollOffset, scrollOffset) {
                    _ = scrollToOffset(clampedScrollOffset, .createProgrammatic())
                }
            }
        }

        // List box parts handle the scrollbars by themselves so we have nothing to do.
        if box[.Style].usedAppearance() == .Listbox {
            return WebCore.RenderLayerScrollableArea.ScrollInfoAfterLayout()
        }

        let hadHorizontalScrollbar = hasHorizontalScrollbar()
        let hadVerticalScrollbar = hasVerticalScrollbar()

        let hasHorizontalOverflow = self.hasHorizontalOverflow()
        let hasVerticalOverflow = self.hasVerticalOverflow()

        updateScrollbarPresenceAndState(
            WebCore.RenderLayerScrollableArea.OptionalBool(hasHorizontalOverflow),
            WebCore.RenderLayerScrollableArea.OptionalBool(hasVerticalOverflow)
        )

        // Scrollbars with auto behavior may need to lay out again if scrollbars got added or removed.
        let horizontalAutoScrollbarChanged = box.hasAutoScrollbar(.Horizontal) && (hadHorizontalScrollbar != hasHorizontalScrollbar())
        let verticalAutoScrollbarChanged = box.hasAutoScrollbar(.Vertical) && (hadVerticalScrollbar != hasVerticalScrollbar())

        if horizontalAutoScrollbarChanged || verticalAutoScrollbarChanged {
            if verticalAutoScrollbarChanged && shouldPlaceVerticalScrollbarOnLeft() {
                computeScrollOrigin()
            }
            m_layer.updateSelfPaintingLayerForScrollableArea()
        }

        var info = WebCore.RenderLayerScrollableArea.ScrollInfoAfterLayout()
        info.originalScrollPosition = originalScrollPosition
        info.needsScrollbarUpdateScope = true
        info.horizontalAutoScrollbarChanged = horizontalAutoScrollbarChanged
        info.verticalAutoScrollbarChanged = verticalAutoScrollbarChanged
        info.hasHorizontalOverflow = hasHorizontalOverflow
        info.hasVerticalOverflow = hasVerticalOverflow
        return info
    }

    // MARK: Scroll corner and resizer painting

    @cxx
    @implementation
    public func paintScrollCorner(
        _ context: WebCore.LentGraphicsContext,
        _ paintOffset: WebCore.IntPoint,
        _ scrollCornerRect: WebCore.IntRect,
        _ damageRect: WebCore.IntRect
    ) {
        var absRect = scrollCornerRect
        absRect.moveBy(paintOffset)
        if !absRect.intersects(damageRect) {
            return
        }

        if context.invalidatingControlTints() {
            updateScrollCornerStyle()
            return
        }

        if scrollCornerForSwift() != nil {
            paintScrollCornerPart(context, WebCore.LayoutPoint(paintOffset), WebCore.LayoutRect(absRect))
            return
        }

        // We don't want to paint a corner if we have overlay scrollbars, since we need
        // to see what is behind it.
        if !hasOverlayScrollbarsForSwift() {
            paintScrollCornerWithTheme(context, absRect)
        }
    }

    @cxx
    @implementation
    public func paintResizer(
        _ context: WebCore.LentGraphicsContext,
        _ paintOffset: WebCore.LayoutPoint,
        _ resizerRect: WebCore.IntRect,
        _ damageRect: WebCore.LayoutRect
    ) {
        let renderer = m_layer.renderer()
        if !renderer[.Style].hasResize() {
            return
        }

        var resizerAbsRect = WebCore.LayoutRect(resizerRect)
        resizerAbsRect.moveBy(paintOffset)
        if !resizerAbsRect.intersects(damageRect) {
            return
        }

        if context.invalidatingControlTints() {
            updateResizerStyle()
            return
        }

        if resizerForSwift() != nil {
            paintResizerPart(context, paintOffset, resizerAbsRect)
            return
        }

        paintPlatformResizer(context, resizerAbsRect)

        // Draw a frame around the resizer if there are any scrollbars present.
        if !hasOverlayScrollbarsForSwift() && (m_vBar.get() != nil || m_hBar.get() != nil) && !renderer[.Style].scrollbarWidthIsNone() {
            paintPlatformResizerFrame(context, resizerAbsRect)
        }
    }

    // MARK: Scrollbar coordinates

    @cxx
    @implementation
    public func convertFromScrollbarToContainingViewInLayer(
        _ scrollbar: borrowing WebCore.Scrollbar,
        _ scrollbarRect: WebCore.IntRect
    ) -> WebCore.IntRect {
        let renderer = m_layer.renderer()
        var rect = scrollbarRect
        rect.move(scrollbarOffset(scrollbar))
        return renderer.view().frameView().convertFromRendererToContainingView(renderer, rect)
    }

    @cxx
    @implementation
    public func convertFromContainingViewToScrollbarInLayer(
        _ scrollbar: borrowing WebCore.Scrollbar,
        _ parentRect: WebCore.IntRect
    ) -> WebCore.IntRect {
        let renderer = m_layer.renderer()
        var rect = renderer.view().frameView().convertFromContainingViewToRenderer(renderer, parentRect)
        rect.move(negatedIntSize(scrollbarOffset(scrollbar)))
        return rect
    }

    @cxx
    @implementation
    public func convertFromScrollbarToContainingViewInLayer(
        _ scrollbar: borrowing WebCore.Scrollbar,
        _ scrollbarPoint: WebCore.IntPoint
    ) -> WebCore.IntPoint {
        let renderer = m_layer.renderer()
        var point = scrollbarPoint
        point.move(scrollbarOffset(scrollbar))
        return renderer.view().frameView().convertFromRendererToContainingView(renderer, point)
    }

    @cxx
    @implementation
    public func convertFromContainingViewToScrollbarInLayer(
        _ scrollbar: borrowing WebCore.Scrollbar,
        _ parentPoint: WebCore.IntPoint
    ) -> WebCore.IntPoint {
        let renderer = m_layer.renderer()
        var point = renderer.view().frameView().convertFromContainingViewToRenderer(renderer, parentPoint)
        point.move(negatedIntSize(scrollbarOffset(scrollbar)))
        return point
    }

    // MARK: Page, frame and style queries

    @cxx
    @implementation
    public func isActive() -> Bool {
        m_layer.page().focusControllerIsActiveForSwift()
    }

    @cxx
    @implementation
    public func isHandlingWheelEvent() -> Bool {
        m_layer.renderer().frame().isHandlingWheelEventForSwift()
    }

    @cxx
    @implementation
    public func isVisibleToHitTesting() -> Bool {
        let renderer = m_layer.renderer()
        let frameView = renderer.view().frameView()
        return renderer.visibleToHitTesting() && frameView.isVisibleToHitTesting()
    }

    @cxx
    @implementation
    public func horizontalOverscrollBehavior() -> WebCore.OverscrollBehavior {
        if m_layer.renderBox() != nil {
            return m_layer.renderer()[.Style].overscrollBehaviorX()
        }
        return .Auto
    }

    @cxx
    @implementation
    public func verticalOverscrollBehavior() -> WebCore.OverscrollBehavior {
        if m_layer.renderBox() != nil {
            return m_layer.renderer()[.Style].overscrollBehaviorY()
        }
        return .Auto
    }
}

// IntSize's unary minus. Wraps at INT_MIN, as int negation does in practice.
private func negatedIntSize(_ size: WebCore.IntSize) -> WebCore.IntSize {
    WebCore.IntSize(0 &- size.width(), 0 &- size.height())
}

private func isSameIntPoint(_ a: WebCore.IntPoint, _ b: WebCore.IntPoint) -> Bool {
    a.x() == b.x() && a.y() == b.y()
}

private func isSameIntRect(_ a: WebCore.IntRect, _ b: WebCore.IntRect) -> Bool {
    a.x() == b.x() && a.y() == b.y() && a.width() == b.width() && a.height() == b.height()
}

extension WebCore.RenderLayer {
    // MARK: Reflection and overlay scrollbars

    @cxx
    @implementation
    public func isReflectionLayer(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        isReflectionLayerBody(copy layer)
    }

    @inline(always)
    func isReflectionLayerBody(_ layer: WebCore.RenderLayer) -> Bool {
        guard let reflection = reflectionForSwift() else {
            return false
        }
        return isSameRenderLayer(layer, reflection.layer())
    }

    @cxx
    @implementation
    public func layoutReflectionAfterPositionUpdate(_ verifyOnly: Bool) {
        guard let reflection = reflectionForSwift() else {
            return
        }
        if !verifyOnly {
            reflection.layout()
        } else {
            layerPositionsAssert(!reflection.needsLayout())
        }
    }

    @cxx
    @implementation
    public func hasOverlayScrollbars() -> Bool {
        scrollableArea()?.hasOverlayScrollbarsForSwift() ?? false
    }
}

extension WebCore.RenderLayer {
    @cxx
    @implementation
    public func shouldTryToScrollForScrollIntoView(_ options: WebCore.ScrollRectToVisibleOptions) -> Bool {
        let renderer = renderer()
        if !renderer.isRenderBox() || !renderer.hasNonVisibleOverflow() {
            return false
        }

        if options.allowScrollingOverflowHidden == .No {
            if renderer[.Style].overflowX() == .Hidden && renderer[.Style].overflowY() == .Hidden {
                return false
            }
        }

        // Don't scroll to reveal an overflow layer that is restricted by the -webkit-line-clamp property.
        // FIXME: Is this still needed? It used to be relevant for Safari RSS.
        if let parent = parentRendererOfRenderObject(renderer), parent[.Style].hasLegacyLineClamp() {
            return false
        }

        let box = renderBox()!

        if box.frame().autoscrollInProgressForSwift() {
            // The "programmatically" here is misleading; this asks whether the box has scrollable overflow,
            // or is a special case like a form control.
            return box.canBeProgramaticallyScrolled()
        }

        // Programmatic scrolls can scroll overflow: hidden but not overflow: clip.
        return box.hasPotentiallyScrollableOverflow() && (box.hasHorizontalOverflow() || box.hasVerticalOverflow())
    }
}

extension WebCore.RenderLayerScrollableArea {
    @cxx
    @implementation
    public func scrollToOffset(_ scrollOffset: WebCore.ScrollOffset, _ options: WebCore.ScrollPositionChangeOptions) -> WebCore.ScrollOffset
    {
        let clampedScrollOffset = options.clamping == .Clamped ? clampScrollOffset(scrollOffset) : scrollOffset
        let snappedOffset = WebCore.ceiledIntPoint(
            scrollOffsetAdjustedForSnappingForSwift(WebCore.FloatPoint(clampedScrollOffset), options.snapPointSelectionMethod)
        )
        let snappedPosition = scrollPositionFromOffsetForSwift(snappedOffset)

        if scrollAnimationStatus() == .Animating {
            // If a smooth scroll animation is already running and the new request is also
            // animated, retarget the running animation to the new destination instead of
            // cancelling it. Cancelling tears the animation down, which prematurely fires a
            // scrollend event at the current intermediate position rather than running to
            // the new destination.
            if options.animated == .Yes && retargetRunningAnimationForSwift(WebCore.FloatPoint(snappedPosition), options.animationCurve) {
                return snappedOffset
            }
            cancelAnimationsForSwift()
            stopAsyncAnimatedScroll()
        }

        if isSameIntPoint(clampedScrollOffset, scrollOffsetForSwift()) {
            return clampedScrollOffset
        }

        let previousScrollType = currentScrollTypeForSwift()
        setCurrentScrollTypeForSwift(options.type)
        defer { setCurrentScrollTypeForSwift(previousScrollType) }
        setCurrentScrollRelativityForSwift(WebCore.scrollRelativityFor(options.snapPointSelectionMethod))

        if options.animated == .Yes {
            registerScrollableAreaForAnimatedScroll()
            scrollToPositionWithAnimationForSwift(WebCore.FloatPoint(snappedPosition), options)
        } else if !requestScrollToPosition(snappedPosition, options) {
            _ = scrollToPositionWithoutAnimationForSwift(WebCore.FloatPoint(snappedPosition), options.clamping)
        }

        return snappedOffset
    }
}
