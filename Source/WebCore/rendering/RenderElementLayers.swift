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
 * Copyright (C) 1999 Lars Knoll (knoll@kde.org)
 *           (C) 1999 Antti Koivisto (koivisto@kde.org)
 *           (C) 2005 Allan Sandfeld Jensen (kde@carewolf.com)
 * Copyright (C) 2005-2026 Samuel Weinig (sam@webkit.org)
 * Copyright (C) 2005-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2010-2018 Google Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

// RenderElement's part in RenderLayer's tree: where a renderer's layer goes in the layer tree, and the layers of a
// subtree added to, removed from or moved within it. WebCore.RenderElement names this file in SWIFT_PRIVATE_FILEID.

internal import WebCore_Private

// RenderObject's parent(): a RenderElement also sees its layout box's parent().
func parentRendererOfRenderObject(_ renderer: WebCore.RenderObject) -> WebCore.RenderElement? {
    renderer.parent()
}

extension WebCore.RenderElement {
    @cxx
    @implementation
    public func setMayHaveLayerInSubtreeIncludingAncestors() {
        m_mayHaveLayerInSubtree = 1
        var renderer = parentRendererOfRenderObject(self)
        while let current = renderer, current.m_mayHaveLayerInSubtree == 0 {
            current.m_mayHaveLayerInSubtree = 1
            renderer = parentRendererOfRenderObject(current)
        }
    }

    // The layer of this renderer or of a renderer after it in tree order whose parent layer is parentLayer.
    private func findNextLayer(
        _ parentLayer: WebCore.RenderLayer,
        _ siblingToTraverseFrom: WebCore.RenderObject?,
        _ checkParent: Bool
    ) -> WebCore.RenderLayer? {
        let parentRef = WebCore.LayerRef(parentLayer)

        // Step 1: If our layer is a child of the desired parent, then return our layer.
        let ourLayer = hasLayer() ? asRenderLayerModelObject()!.layer() : nil
        let ourRef = WebCore.LayerRef(ourLayer)
        if let ourLayer, WebCore.LayerRef(ourLayer.parent()) == parentRef {
            return ourLayer
        }

        // Step 2: If we don't have a layer, or our layer is the desired parent, then descend
        // into our siblings trying to find the next layer whose parent is the desired parent.
        if ourLayer == nil || ourRef == parentRef {
            var child = siblingToTraverseFrom != nil ? siblingToTraverseFrom!.nextSibling() : firstChild()
            while let current = child {
                if let element = current.asRenderElement(), element.mayHaveLayerInSubtree() {
                    if let nextLayer = element.findNextLayer(parentLayer, nil, false) {
                        return nextLayer
                    }
                }
                child = current.nextSibling()
            }
        }

        // Step 3: If our layer is the desired parent layer, then we're finished. We didn't
        // find anything.
        if ourRef == parentRef {
            return nil
        }

        // Step 4: If |checkParent| is set, climb up to our parent and check its siblings that
        // follow us to see if we can locate a layer.
        if checkParent, let parent = parentRendererOfRenderObject(self) {
            return parent.findNextLayer(parentLayer, self, true)
        }
        return nil
    }

    func nextSiblingLayerRespectingTopLayer(_ parentLayer: WebCore.RenderLayer) -> WebCore.RenderLayer? {
        if let layerModelObject = asRenderLayerModelObject(), isInTopLayerOrBackdropForSwift() {
            assert(layerModelObject.hasLayer())
            return WebCore.RenderLayer.topLayerRenderLayerAfter(view(), layerModelObject.layer()!)
        }
        let parent = parentRendererOfRenderObject(self)!
        // The layer found is a child of parentLayer, so there is none when parentLayer has no children.
        if parentLayer.lastChild() == nil {
            return nil
        }
        return parent.findNextLayer(parentLayer, self, true)
    }

    func parentLayerRespectingTopLayer() -> WebCore.RenderLayer? {
        if hasLayer() && isInTopLayerOrBackdropForSwift() {
            return view().layer()
        }
        return parentRendererOfRenderObject(self)!.enclosingLayer()
    }

    @cxx
    @implementation
    public func linkLayerParent() -> WebCore.LayerRef {
        WebCore.LayerRef(parentLayerRespectingTopLayer())
    }

    @cxx
    @implementation
    public func addLayers(_ insertedRenderer: borrowing WebCore.RenderElement, _ parentLayer: WebCore.RenderLayer) {
        addLayersInSubtree(copy insertedRenderer, parentLayer)
    }

    private func addLayersInSubtree(_ insertedRenderer: WebCore.RenderElement, _ parentLayer: WebCore.RenderLayer) {
        if hasLayer() {
            let layer = asRenderLayerModelObject()!.layer()!
            var layerToUse = parentLayer
            if isInTopLayerOrBackdropForSwift() {
                // The special handling of a toplayer/backdrop content may result in trying to insert the associated
                // layer twice as we connect subtrees.
                if let parentOfLayer = layer.parent() {
                    assert(WebCore.LayerRef(parentOfLayer) == WebCore.LayerRef(view().layer()))
                    return
                }
                layerToUse = insertedRenderer.view().layer()!
            }
            let beforeChild = insertedRenderer.nextSiblingLayerRespectingTopLayer(layerToUse)
            layerToUse.addChildLinks(layer, before: beforeChild)
            return
        }

        var child = firstChild()
        while let current = child {
            if let element = current.asRenderElement(), element.mayHaveLayerInSubtree() {
                element.addLayersInSubtree(insertedRenderer, parentLayer)
            }
            child = current.nextSibling()
        }
    }

    @cxx
    @implementation
    public func removeLayers() {
        removeLayersInSubtree()
    }

    func removeLayersInSubtree() {
        guard let parentLayer = parentLayerRespectingTopLayer() else {
            return
        }

        if hasLayer() {
            parentLayer.removeChildLinks(asRenderLayerModelObject()!.layer()!)
            return
        }

        var child = firstChild()
        while let current = child {
            if let element = current.asRenderElement(), element.mayHaveLayerInSubtree() {
                element.removeLayersInSubtree()
            }
            child = current.nextSibling()
        }
    }

    func moveLayersInSubtree(_ newParent: WebCore.RenderLayer) {
        if hasLayer() {
            if isInTopLayerOrBackdropForSwift() {
                return
            }
            asRenderLayerModelObject()!.layer()!.moveToParentLinks(newParent)
            return
        }

        var child = firstChild()
        while let current = child {
            if let element = current.asRenderElement(), element.mayHaveLayerInSubtree() {
                element.moveLayersInSubtree(newParent)
            }
            child = current.nextSibling()
        }
    }

    @cxx
    @implementation
    public func layerCreationAllowedForSubtree() -> Bool {
        isLayerCreationAllowedForSubtree
    }

    // Read by RenderLayerModelObject; the protected C++ member does not import.
    var isLayerCreationAllowedForSubtree: Bool {
        // In LBSE layers are always created regardless of there position in the render tree.
        // Consider the SVG document fragment: "<defs><mask><rect transform="scale(2)".../>"
        // To paint the <rect> into the mask image, the rect needs to be transformed -
        // which is handled via RenderLayer in LBSE, unlike as in the legacy engine where no
        // layers are involved for any SVG painting features. In the legacy engine we could
        // simply omit the layer creation for any children of a <defs> element (or in general
        // any "hidden container"). For LBSE layers are needed for painting, even if a
        // RenderSVGHiddenContainer is in the render tree ancestor chain -- however they are
        // never painted directly, only indirectly through the "LegacyRenderSVGResourceContainer
        // elements (such as LegacyRenderSVGResourceClipper, RenderSVGResourceMasker, etc.)
        if document().settings().layerBasedSVGEngineEnabled() {
            return true
        }

        var ancestor = parentRendererOfRenderObject(self)
        while let current = ancestor {
            if current.isLegacyRenderSVGHiddenContainer() {
                return false
            }
            ancestor = parentRendererOfRenderObject(current)
        }
        return true
    }

    @cxx
    @implementation
    public func hasSelfPaintingLayer() -> Bool {
        if !hasLayer() {
            return false
        }
        return asRenderLayerModelObject()!.layer()?.isSelfPaintingLayer() ?? false
    }

    @cxx
    @implementation
    public func setMayHaveNonScalingStrokeInSubtreeIncludingAncestors() {
        m_mayHaveNonScalingStrokeInSubtree = 1

        var ancestor = parentRendererOfRenderObject(self)
        while let current = ancestor, !current.isRenderSVGRoot(), current.m_mayHaveNonScalingStrokeInSubtree == 0 {
            current.m_mayHaveNonScalingStrokeInSubtree = 1
            ancestor = parentRendererOfRenderObject(current)
        }
    }

    // MARK: Top layer

    @cxx
    @implementation
    public func establishesTopLayerWillChange() {
        if let layer = asRenderLayerModelObject()?.layer() {
            layer.topLayerWillChange()
        }

        // RenderObject's isOutOfFlowPositioned(): the renderer also sees its layout box's.
        let object: WebCore.RenderObject = self
        guard let renderBox = asRenderBox(), object.isOutOfFlowPositioned() else {
            return
        }

        // Remove from the current containing block's out-of-flow list. The renderer will be
        // re-inserted into the correct containing block's list during the next layout.
        WebCore.RenderBoxModelObject.removeOutOfFlowBox(renderBox)
        if let parent = WebCore.RenderObject.containingBlockForPositionType(.Static, renderBox) {
            parent.setChildNeedsLayout()
        }
        renderBox.setNeedsLayout()
    }

    @cxx
    @implementation
    public func establishesTopLayerDidChange() {
        if let layer = asRenderLayerModelObject()?.layer() {
            layer.topLayerDidChange()
        }
    }

    @cxx
    @implementation
    public static func markRendererDirtyAfterTopLayerChange(
        _ renderer: WebCore.RenderElement?,
        _ containingBlockBeforeStyleResolution: WebCore.RenderBoxModelObject?
    ) {
        guard let renderBox = renderer?.asRenderBox(), let renderBoxParent = parentRendererOfRenderObject(renderBox),
            let containingBlockBeforeStyleResolution
        else {
            return
        }
        let newContainingBlock = renderBox.containingBlock()
        assert(newContainingBlock != nil)
        if WebCore.RenderObject.isSameRenderer(containingBlockBeforeStyleResolution, newContainingBlock) {
            return
        }

        // Let's carry out the same set of tasks we would normally do when containing block changes for out-of-flow content in
        // RenderBox::styleWillChange.
        let object: WebCore.RenderObject = renderBox
        if !object.isOutOfFlowPositioned() {
            return
        }

        WebCore.RenderBoxModelObject.removeOutOfFlowBox(renderBox)
        // This is to make sure we insert the box to the correct containing block list during static position computation.
        renderBoxParent.setChildNeedsLayout()
        newContainingBlock!.setChildNeedsLayout()
        renderBox.setNeedsLayout()
    }
}
