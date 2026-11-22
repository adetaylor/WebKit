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
 * Copyright (C) 2009-2026 Apple Inc. All rights reserved.
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
 * Copyright (C) 2009, 2010, 2011 Apple Inc. All rights reserved.
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

// RenderLayerBacking's GraphicsLayers: the layers a backing adds around its primary layer (foreground, background,
// contents containment, viewport anchor and clipping, child clipping, 3D flattening, overflow controls, scrolling),
// tile coverage, and the GraphicsLayerClient callbacks it forwards to the compositor. WebCore.RenderLayerBacking names
// this file in SWIFT_PRIVATE_FILEID.

internal import WebCore_Private

// MARK: - Layers

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func updateAppliesPageScale() {
        // Only the root frame's RenderView layer applies page scale to its own geometry, and only when scaling
        // isn't delegated. The compositor's root contents layer does it otherwise, see ensureRootLayer().
        if !m_isRootFrameRenderViewLayer {
            return
        }

        #if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS) // PLATFORM(IOS_FAMILY)
        // iOS always delegates scaling. Page::delegatesScaling() isn't set until didCommitLoad, so it would read
        // false for layers created before then.
        let appliesPageScale = false
        #else
        // updateConfiguration() calls this again, since delegatesScaling is set at didCommitLoad, which can
        // happen after this layer is created.
        let appliesPageScale = !renderer().page().delegatesScaling()
        #endif

        // A fixed root background splits the RenderView's layers, and the contents containment layer carries the
        // flag for the pair. Only one of the two may apply the scale, and neither may when the root contents layer
        // above already does, or we scale twice.
        if let containment = contentsContainmentLayer() {
            containment.setAppliesPageScale(appliesPageScale)
            graphicsLayer()!.setAppliesPageScale(false)
            return
        }

        graphicsLayer()!.setAppliesPageScale(appliesPageScale)
    }

    @cxx
    @implementation
    public func updateReflectionLayer() {
        if m_owningLayer.hasReflection() {
            if let reflectionBacking = m_owningLayer.reflectionLayer()!.backing() {
                graphicsLayer()!.setReplicatedByLayerForSwift(reflectionBacking.graphicsLayer())
            }
        } else {
            graphicsLayer()!.setReplicatedByLayerForSwift(nil)
        }
    }

    @cxx
    @implementation
    public func willDestroyLayer(_ layer: WebCore.GraphicsLayer?) {
        if let layer, layer.type() == .Normal, layer.tiledBacking() != nil {
            compositor().layerTiledBackingUsageChanged(layer, false)
        }
    }

    @cxx
    @implementation
    public func updateForegroundLayer(_ needsForegroundLayer: Bool) -> Bool {
        var layerChanged = false
        if needsForegroundLayer {
            if foregroundLayer() == nil {
                createGraphicsLayer(.Foreground, .Normal)
                foregroundLayer()!.setDrawsContent(true)
                layerChanged = true
            }
        } else if destroyGraphicsLayer(.Foreground) {
            layerChanged = true
        }

        return layerChanged
    }

    @cxx
    @implementation
    public func updateBackgroundLayer(_ needsBackgroundLayer: Bool) -> Bool {
        var layerChanged = false
        if needsBackgroundLayer {
            if backgroundLayer() == nil {
                createGraphicsLayer(.Background, .Normal)
                backgroundLayer()!.setDrawsContent(true)
                backgroundLayer()!.setAnchorPoint(WebCore.FloatPoint3D())
                layerChanged = true
            }
            if !WebCore.RenderLayerBacking.modelProcessEnabledForSwift() && contentsContainmentLayer() == nil {
                createGraphicsLayer(.ContentsContainment, .Normal)
                contentsContainmentLayer()!.setAppliesPageScale(true)
                graphicsLayer()!.setAppliesPageScale(false)
                layerChanged = true
            }
        } else {
            if destroyGraphicsLayer(.Background) {
                layerChanged = true
            }
            if !WebCore.RenderLayerBacking.modelProcessEnabledForSwift() && destroyGraphicsLayer(.ContentsContainment) {
                layerChanged = true
                graphicsLayer()!.setAppliesPageScale(true)
            }
        }

        if WebCore.RenderLayerBacking.modelProcessEnabledForSwift() && updateContentsContainmentLayerForSwift() {
            layerChanged = true
        }

        return layerChanged
    }

    @cxx
    @implementation
    public func updateTransformFlatteningLayer(_ compositingAncestor: WebCore.RenderLayer?) -> Bool {
        var needsFlatteningLayer = false
        // If our parent layer has preserve-3d or perspective, and it's not our DOM parent, then we need a flattening layer to block that
        // from being applied in 3d.
        if ancestorLayerWillCombineTransform(compositingAncestor) && !m_owningLayer.ancestorLayerIsDOMParent(compositingAncestor) {
            needsFlatteningLayer = true
        }

        var layerChanged = false
        if needsFlatteningLayer {
            if transformFlatteningLayer() == nil {
                createGraphicsLayer(.TransformFlattening, .Normal)
                layerChanged = true
            }
        } else if destroyGraphicsLayer(.TransformFlattening) {
            layerChanged = true
        }

        return layerChanged
    }

    @cxx
    @implementation
    public func updateViewportConstrainedSublayers(_ sublayers: WebCore.ViewportConstrainedSublayers) -> Bool {
        var layerChanged = false

        var needsAnchorLayer = false
        var needsClippingLayer = false
        switch sublayers {
        case .None:
            break
        case .ClippingAndAnchor:
            needsClippingLayer = true
            needsAnchorLayer = true
        case .Anchor:
            needsAnchorLayer = true
        @unknown default:
            break
        }

        if needsAnchorLayer {
            if viewportAnchorLayer() == nil {
                createGraphicsLayer(.ViewportAnchor, .Structural)
                layerChanged = true
            }
        } else if destroyGraphicsLayer(.ViewportAnchor) {
            layerChanged = true
        }

        if needsClippingLayer {
            if graphicsLayerForSwift(.ViewportClipping) == nil {
                createGraphicsLayer(.ViewportClipping, .Normal)
                graphicsLayerForSwift(.ViewportClipping)!.setMasksToBounds(true)
                layerChanged = true
            }
        } else if destroyGraphicsLayer(.ViewportClipping) {
            layerChanged = true
        }

        return layerChanged
    }

    // Returns true if the layer changed.
    @cxx
    @implementation
    public func updateDescendantClippingLayer(_ needsDescendantClip: Bool) -> Bool {
        var layersChanged = false

        if needsDescendantClip {
            if childContainmentLayer() == nil && !m_isFrameLayerWithTiledBacking {
                createGraphicsLayer(.ChildClipping, .Normal)
                childContainmentLayer()!.setMasksToBounds(true)
                childContainmentLayer()!.setContentsRectClipsDescendants(true)
                layersChanged = true
            }
        } else if hasClippingLayer() {
            _ = destroyGraphicsLayer(.ChildClipping)
            layersChanged = true
        }

        return layersChanged
    }

    @cxx
    @implementation
    public func updateOverflowControlsLayers(
        _ needsHorizontalScrollbarLayer: Bool,
        _ needsVerticalScrollbarLayer: Bool,
        _ needsScrollCornerLayer: Bool
    ) -> Bool {
        func createOrDestroyLayer(_ name: WebCore.RenderLayerBacking.GraphicsLayerName, _ needLayer: Bool, _ drawsContent: Bool) -> Bool {
            if needLayer == (graphicsLayerForSwift(name) != nil) {
                return false
            }

            if needLayer {
                createGraphicsLayer(name, .Normal)
                let layer = graphicsLayerForSwift(name)!
                if drawsContent {
                    layer.setAllowsBackingStoreDetaching(false)
                    layer.setAllowsTiling(false)
                } else {
                    layer.setPaintingPhase(WebCore.GraphicsLayerPaintingPhases())
                    layer.setDrawsContent(false)
                }
            } else {
                _ = destroyGraphicsLayer(name)
            }
            return true
        }

        var layersChanged = createOrDestroyLayer(
            .OverflowControlsContainer,
            needsHorizontalScrollbarLayer || needsVerticalScrollbarLayer || needsScrollCornerLayer,
            false
        )

        let horizontalScrollbarLayerChanged = createOrDestroyLayer(.HorizontalScrollbar, needsHorizontalScrollbarLayer, true)
        layersChanged = layersChanged || horizontalScrollbarLayerChanged

        let verticalScrollbarLayerChanged = createOrDestroyLayer(.VerticalScrollbar, needsVerticalScrollbarLayer, true)
        layersChanged = layersChanged || verticalScrollbarLayerChanged

        let scrollCornerLayerChanged = createOrDestroyLayer(.ScrollCorner, needsScrollCornerLayer, true)
        layersChanged = layersChanged || scrollCornerLayerChanged

        if horizontalScrollbarLayerChanged {
            scrollableAreaScrollbarLayerDidChange(.Horizontal)
        }
        if verticalScrollbarLayerChanged {
            scrollableAreaScrollbarLayerDidChange(.Vertical)
        }

        return layersChanged
    }

    @cxx
    @implementation
    public func clearOverflowControlsLayers() {
        _ = destroyGraphicsLayer(.OverflowControlsContainer)
        _ = destroyGraphicsLayer(.HorizontalScrollbar)
        _ = destroyGraphicsLayer(.VerticalScrollbar)
        _ = destroyGraphicsLayer(.ScrollCorner)
    }

    @cxx
    @implementation
    public func positionOverflowControlsLayers() {
        guard let scrollableArea = m_owningLayer.scrollableArea(), scrollableArea.hasScrollbars() else {
            return
        }
        // FIXME: Should do device-pixel snapping.
        let box = renderBox()!
        let borderBox = WebCore.snappedIntRect(box.borderBoxRect())

        // The overflow controls container is positioned using the paddingBoxRectIncludingScrollbar.
        let paddingBox = WebCore.snappedIntRect(box.paddingBoxRectIncludingScrollbar())
        let paddingBoxInset = paddingBox.location() - borderBox.location()

        func positionScrollbarLayer(_ layer: WebCore.GraphicsLayer, _ scrollbarRect: WebCore.IntRect) {
            layer.setPosition(WebCore.FloatPoint(scrollbarRect.location() - paddingBoxInset))
            layer.setSize(WebCore.FloatSize(scrollbarRect.size()))
            if layer.usesContentsLayer() {
                let barRect = WebCore.IntRect(WebCore.IntPoint(), scrollbarRect.size())
                layer.setContentsRect(WebCore.FloatRect(barRect))
                layer.setContentsClippingRect(WebCore.FloatRoundedRect(WebCore.FloatRect(barRect), WebCore.CornerRadii()))
            }
        }

        // These rects are relative to the borderBoxRect.
        let rects = scrollableArea.overflowControlsRects()
        if let layer = layerForHorizontalScrollbar() {
            positionScrollbarLayer(layer, rects.horizontalScrollbar)
            layer.setDrawsContent(scrollableArea.horizontalScrollbar() != nil && !layer.usesContentsLayer())
        }

        if let layer = layerForVerticalScrollbar() {
            positionScrollbarLayer(layer, rects.verticalScrollbar)
            layer.setDrawsContent(scrollableArea.verticalScrollbar() != nil && !layer.usesContentsLayer())
        }

        if let layer = layerForScrollCorner() {
            let cornerRect = rects.scrollCornerOrResizerRect()
            layer.setPosition(WebCore.FloatPoint(cornerRect.location() - paddingBoxInset))
            layer.setSize(WebCore.FloatSize(cornerRect.size()))
            layer.setDrawsContent(!cornerRect.isEmpty())
        }
    }

    @cxx
    @implementation
    public func updateScrollingLayers(_ needsScrollingLayers: Bool) -> Bool {
        if needsScrollingLayers == (scrollContainerLayer() != nil) {
            return false
        }

        if scrollContainerLayer() == nil {
            // Outer layer which corresponds with the scroll view. This never paints content.
            createGraphicsLayer(.ScrollContainer, .ScrollContainer)
            let container = scrollContainerLayer()!
            container.setPaintingPhase(WebCore.GraphicsLayerPaintingPhases())
            container.setDrawsContent(false)
            container.setMasksToBounds(true)

            // Inner layer which renders the content that scrolls.
            createGraphicsLayer(.ScrolledContents, .ScrolledContents)
            let contents = scrolledContentsLayer()!
            contents.setDrawsContent(true)
            contents.setAnchorPoint(WebCore.FloatPoint3D())
            container.addChildForSwift(contents)
        } else {
            compositor().willRemoveScrollingLayerWithBacking(self)

            willDestroyLayer(scrollContainerLayer())
            willDestroyLayer(scrolledContentsLayer())

            unparentAndClearGraphicsLayer(.ScrollContainer)
            unparentAndClearGraphicsLayer(.ScrolledContents)
        }

        if scrollContainerLayer() != nil {
            compositor().didAddScrollingLayer(m_owningLayer)
        }

        return true
    }

    @cxx
    @implementation
    public func createPrimaryGraphicsLayer() {
        createGraphicsLayer(.Primary, m_isFrameLayerWithTiledBacking ? .PageTiledBacking : .Normal)

        if m_isFrameLayerWithTiledBacking {
            createGraphicsLayer(.PageTiledBackingContainment, .Normal)
            graphicsLayer()!.addChildForSwift(childContainmentLayer()!)
        }

        #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) // !PLATFORM(IOS_FAMILY)
        if m_isMainFrameRenderViewLayer {
            graphicsLayer()!.setContentsOpaque(!viewHasTransparentBackgroundForSwift())
        }
        #endif
        updateAppliesPageScale()

        if WebCore.RenderLayerBacking.usesCAForSwift() && !compositor().acceleratedDrawingEnabled() && renderer().isRenderHTMLCanvas() {
            if canvasShouldAccelerate() {
                graphicsLayer()!.setAcceleratesDrawing(true)
            }
        }
        updateOpacity()
        updateTransform(renderer()[.Style])
        updateFilters(renderer()[.Style])
        updateBackdropFilters(renderer()[.Style])
        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        updateAppleVisualEffect(renderer()[.Style])
        #endif
        updateBackdropRoot()
        updateScreenCaptureProtection()
        updateIsHostedInSpatialPortalSceneForSwift()
        updateBlendMode()
        if WebCore.RenderLayerBacking.videoEnabledForSwift() {
            updateVideoGravity()
        }
        updateContentsScalingFilters()
    }

    @cxx
    @implementation
    public func destroyGraphicsLayers() {
        if graphicsLayer() != nil {
            if graphicsLayer()!.hasContentsDisplayDelegate() {
                clearCanvasContentsFromLayer()
            }
            graphicsLayer()!.setMaskLayerForSwift(nil)
            graphicsLayer()!.setReplicatedByLayerForSwift(nil)
            willDestroyLayer(graphicsLayer())
        }

        clearGraphicsLayer(.Mask)

        if hasClippingStack(.Ancestor) {
            removeClippingStackLayers(.Ancestor)
        }

        if hasClippingStack(.OverflowControlsHost) {
            removeClippingStackLayers(.OverflowControlsHost)
        }

        unparentAndClearGraphicsLayer(.TransformFlattening)
        unparentAndClearGraphicsLayer(.ViewportAnchor)
        unparentAndClearGraphicsLayer(.ViewportClipping)
        unparentAndClearGraphicsLayer(.ContentsContainment)
        unparentAndClearGraphicsLayer(.Foreground)
        clearSVGSegmentLayers()
        unparentAndClearGraphicsLayer(.Background)
        unparentAndClearGraphicsLayer(.ChildClipping)
        unparentAndClearGraphicsLayer(.ScrollContainer)
        unparentAndClearGraphicsLayer(.ScrolledContents)
        unparentAndClearSystemPreviewLayers()
        unparentAndClearGraphicsLayer(.Primary)
    }

    @cxx
    @implementation
    public func updateInternalHierarchy() {
        // The foreground layer has to be inserted in the correct order with child layers,
        // so it's not inserted here.
        var lastClippingLayer: WebCore.GraphicsLayer? = nil
        if hasClippingStack(.Ancestor) {
            connectClippingStackLayers(.Ancestor)
            // The stack is not empty here, so this cannot overflow.
            lastClippingLayer = clippingStackEntryParentForSublayers(.Ancestor, clippingStackSize(.Ancestor) &- 1)
        }

        var orderedLayers: [WebCore.GraphicsLayer] = []

        if let lastClippingLayer {
            orderedLayers.append(lastClippingLayer)
        }

        if let viewportClipping = graphicsLayerForSwift(.ViewportClipping) {
            orderedLayers.append(viewportClipping)
        }

        if let viewportAnchor = viewportAnchorLayer() {
            orderedLayers.append(viewportAnchor)
        }

        // Insert the system-preview wrapper above the contents containment so the badge layer (added
        // as a sibling below) composites in front of the model's separated portal subtree.
        if let systemPreviewWrapper = systemPreviewWrapperLayerForSwift() {
            orderedLayers.append(systemPreviewWrapper)
        }

        if let containment = contentsContainmentLayer() {
            containment.removeAllChildren()

            if let background = backgroundLayer() {
                containment.addChildForSwift(background)
            }

            // The loop below will add a second child to the contents containment layer.
            orderedLayers.append(containment)
        }

        orderedLayers.append(graphicsLayer()!)

        // The transform flattening layer is outside the clipping stack, so we need
        // to make sure we add the first layer in the clipping stack as its child.
        if let flattening = transformFlatteningLayer() {
            if lastClippingLayer != nil {
                flattening.addChildForSwift(clippingStackEntryLayer(.Ancestor, 0, .Clipping)!)
            } else {
                flattening.addChildForSwift(orderedLayers[0])
            }
        }

        if let childContainment = childContainmentLayer() {
            orderedLayers.append(childContainment)
        }

        if let scrollContainer = scrollContainerLayer() {
            orderedLayers.append(scrollContainer)
        }

        var previousLayer: WebCore.GraphicsLayer? = nil
        for layer in orderedLayers {
            if let previousLayer {
                previousLayer.addChildForSwift(layer)
            }

            previousLayer = layer
        }

        // Add the badge as the topmost child of the wrapper, after the loop has already parented
        // the contents containment layer (or the primary layer) under the wrapper. The badge therefore
        // composites in front of the model subtree.
        if let systemPreviewWrapper = systemPreviewWrapperLayerForSwift(), let systemPreviewBadge = systemPreviewBadgeLayerForSwift() {
            systemPreviewWrapper.addChildForSwift(systemPreviewBadge)
        }

        // The clip for child layers does not include space for overflow controls, so they exist as
        // siblings of the clipping layer if we have one. Normal children of this layer are set as
        // children of the clipping layer.
        if let overflowControls = overflowControlsContainer() {
            if let horizontalScrollbar = layerForHorizontalScrollbar() {
                overflowControls.addChildForSwift(horizontalScrollbar)
            }

            if let verticalScrollbar = layerForVerticalScrollbar() {
                overflowControls.addChildForSwift(verticalScrollbar)
            }

            if let scrollCorner = layerForScrollCorner() {
                overflowControls.addChildForSwift(scrollCorner)
            }

            // The overflow controls container may get reparented later.
            graphicsLayer()!.addChildForSwift(overflowControls)
        }
    }

    @cxx
    @implementation
    public func updateMaskingLayer(_ hasMask: Bool, _ hasClipPath: Bool) -> Bool {
        var layerChanged = false
        if hasMask || hasClipPath {
            var maskPhases = WebCore.GraphicsLayerPaintingPhases()
            if hasMask {
                maskPhases = WebCore.GraphicsLayerPaintingPhases(.Mask)
            }

            func shouldAddClipPathPaintingPhase() -> Bool {
                if !hasClipPath {
                    return false
                }

                // If we have a mask, we need to paint the combined clip-path and mask into the mask layer.
                if hasMask {
                    return true
                }

                if clipPathIsReferencePath() {
                    return true
                }

                if !WebCore.GraphicsLayer.supportsLayerType(.Shape) {
                    return true
                }

                return false
            }
            if shouldAddClipPathPaintingPhase() {
                maskPhases.add(WebCore.GraphicsLayerPaintingPhases(.ClipPath))
            }

            let paintsContent = !maskPhases.isEmpty()
            let requiredLayerType: WebCore.GraphicsLayerType = paintsContent ? .Normal : .Shape
            if maskLayer() != nil && maskLayer()!.type() != requiredLayerType {
                graphicsLayer()!.setMaskLayerForSwift(nil)
                willDestroyLayer(maskLayer())
                clearGraphicsLayer(.Mask)
            }

            if maskLayer() == nil {
                createGraphicsLayer(.Mask, requiredLayerType)
                layerChanged = true
                graphicsLayer()!.setMaskLayerForSwift(maskLayer())
                // We need a geometry update to size the new mask layer.
                m_owningLayer.setNeedsCompositingGeometryUpdate()
            }
            maskLayer()!.setDrawsContent(paintsContent)
            maskLayer()!.setPaintingPhase(maskPhases)
        } else if maskLayer() != nil {
            graphicsLayer()!.setMaskLayerForSwift(nil)
            willDestroyLayer(maskLayer())
            clearGraphicsLayer(.Mask)
            layerChanged = true
        }

        return layerChanged
    }

    @cxx
    @implementation
    public func setBackgroundLayerPaintsFixedRootBackground(_ backgroundLayerPaintsFixedRootBackground: Bool) {
        if backgroundLayerPaintsFixedRootBackground == m_backgroundLayerPaintsFixedRootBackground {
            return
        }

        m_backgroundLayerPaintsFixedRootBackground = backgroundLayerPaintsFixedRootBackground

        if m_backgroundLayerPaintsFixedRootBackground {
            assert(m_isFrameLayerWithTiledBacking)
            renderer().view().frameView().removeSlowRepaintObject(renderer().view().rendererForRootBackground()!)
        }
    }

    @cxx
    @implementation
    public func setRequiresBackgroundLayer(_ requiresBackgroundLayer: Bool) {
        if requiresBackgroundLayer == m_requiresBackgroundLayer {
            return
        }

        m_requiresBackgroundLayer = requiresBackgroundLayer
        m_owningLayer.setNeedsCompositingConfigurationUpdate()
    }

    @cxx
    @implementation
    public func requiresLayerForScrollbar(_ scrollbar: WebCore.Scrollbar?) -> Bool {
        guard let scrollbar else {
            return false
        }
        #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) // !PLATFORM(IOS_FAMILY)
        return scrollbar.isOverlayScrollbar() || renderer().settings().asyncOverflowScrollingEnabled()
        #else
        return scrollbar.isOverlayScrollbar()
        #endif
    }

    @cxx
    @implementation
    public func requiresHorizontalScrollbarLayer() -> Bool {
        if let scrollableArea = m_owningLayer.scrollableArea() {
            return requiresLayerForScrollbar(scrollableArea.horizontalScrollbar())
        }
        return false
    }

    @cxx
    @implementation
    public func requiresVerticalScrollbarLayer() -> Bool {
        if let scrollableArea = m_owningLayer.scrollableArea() {
            return requiresLayerForScrollbar(scrollableArea.verticalScrollbar())
        }
        return false
    }

    @cxx
    @implementation
    public func requiresScrollCornerLayer() -> Bool {
        if m_owningLayer.renderer().asRenderBox() == nil {
            return false
        }

        guard let scrollableArea = m_owningLayer.scrollableArea() else {
            return false
        }

        let cornerRect = scrollableArea.overflowControlsRects().scrollCornerOrResizerRect()
        if cornerRect.isEmpty() {
            return false
        }

        let verticalScrollbar = scrollableArea.verticalScrollbar()
        let scrollbar = verticalScrollbar != nil ? verticalScrollbar : scrollableArea.horizontalScrollbar()
        return requiresLayerForScrollbar(scrollbar)
    }

    @cxx
    @implementation
    public func compositingOpacity(_ rendererOpacity: Float) -> Float {
        var finalOpacity = rendererOpacity

        var current = m_owningLayer.stackingContext()
        while let layer = current {
            // If we found a compositing layer, we want to compute opacity
            // relative to it. So we can break here.
            if layer.isComposited() {
                break
            }

            finalOpacity *= layer.renderer().opacity()
            current = layer.stackingContext()
        }

        return finalOpacity
    }
}

private func ancestorLayerWillCombineTransform(_ compositingAncestor: WebCore.RenderLayer?) -> Bool {
    guard let compositingAncestor else {
        return false
    }

    let renderer = compositingAncestor.renderer()
    return renderer[.Style].usedTransformStyle3D() == .Preserve3D || !renderer[.Style].perspectiveIsNone()
}

// MARK: - Ancestor clipping stacks and scrolling nodes

extension WebCore.RenderLayerBacking {
    private func clippingStackEntryParentForSublayers(
        _ stack: WebCore.RenderLayerBacking.ClippingStackName,
        _ index: Int
    ) -> WebCore.GraphicsLayer? {
        clippingStackEntryLayer(stack, index, .Scrolling) ?? clippingStackEntryLayer(stack, index, .Clipping)
    }

    @cxx
    @implementation
    public func ensureClippingStackLayers(_ stack: WebCore.RenderLayerBacking.ClippingStackName) {
        for index in 0..<clippingStackSize(stack) {
            if clippingStackEntryLayer(stack, index, .Clipping) == nil {
                createClippingStackEntryLayer(stack, index, .Clipping)
                let clippingLayer = clippingStackEntryLayer(stack, index, .Clipping)!
                clippingLayer.setMasksToBounds(true)
                clippingLayer.setPaintingPhase(WebCore.GraphicsLayerPaintingPhases())
            }

            if clippingStackEntryNeedsShapeMask(stack, index) {
                if clippingStackEntryLayer(stack, index, .ShapeMask) == nil {
                    createClippingStackEntryLayer(stack, index, .ShapeMask)
                    clippingStackEntryLayer(stack, index, .Clipping)!
                        .setMaskLayerForSwift(clippingStackEntryLayer(stack, index, .ShapeMask))
                }
            } else if clippingStackEntryLayer(stack, index, .ShapeMask) != nil {
                clippingStackEntryLayer(stack, index, .Clipping)!.setMaskLayerForSwift(nil)
                unparentAndClearClippingStackEntryLayer(stack, index, .ShapeMask)
            }

            if clippingStackEntryIsOverflowScroll(stack, index) {
                if clippingStackEntryLayer(stack, index, .Scrolling) == nil {
                    createClippingStackEntryLayer(stack, index, .Scrolling)
                }
            } else if clippingStackEntryLayer(stack, index, .Scrolling) != nil {
                unparentAndClearClippingStackEntryLayer(stack, index, .Scrolling)
            }
        }
    }

    @cxx
    @implementation
    public func removeClippingStackLayers(_ stack: WebCore.RenderLayerBacking.ClippingStackName) {
        for index in 0..<clippingStackSize(stack) {
            if let clippingLayer = clippingStackEntryLayer(stack, index, .Clipping),
                clippingStackEntryLayer(stack, index, .ShapeMask) != nil
            {
                clippingLayer.setMaskLayerForSwift(nil)
            }
            unparentAndClearClippingStackEntryLayer(stack, index, .ShapeMask)
            unparentAndClearClippingStackEntryLayer(stack, index, .Clipping)
            unparentAndClearClippingStackEntryLayer(stack, index, .Scrolling)
        }
    }

    @cxx
    @implementation
    public func connectClippingStackLayers(_ stack: WebCore.RenderLayerBacking.ClippingStackName) {
        func connectEntryLayers(_ index: Int) {
            if let scrollingLayer = clippingStackEntryLayer(stack, index, .Scrolling) {
                setChildrenOfGraphicsLayer(clippingStackEntryLayer(stack, index, .Clipping)!, [scrollingLayer])
            }
        }

        // On an empty stack count - 1 wraps to the largest unsigned value, and the first entry read traps.
        let count = clippingStackSize(stack)
        var index = 0
        while UInt(index) < UInt(bitPattern: count &- 1) {
            connectEntryLayers(index)

            let entryParentForSublayers = clippingStackEntryParentForSublayers(stack, index)!
            let childLayer = clippingStackEntryLayer(stack, index + 1, .Clipping)!
            setChildrenOfGraphicsLayer(entryParentForSublayers, [childLayer])
            index += 1
        }

        connectEntryLayers(count &- 1)
        clippingStackEntryParentForSublayers(stack, count &- 1)!.removeAllChildren()
    }

    // Returns true if the layer changed.
    @cxx
    @implementation
    public func updateAncestorClipping(_ needsAncestorClip: Bool, _ compositingAncestor: WebCore.RenderLayer?) -> Bool {
        var layersChanged = false

        if needsAncestorClip {
            if compositor().updateAncestorClippingStack(m_owningLayer, compositingAncestor) {
                if hasClippingStack(.Ancestor) {
                    ensureClippingStackLayers(.Ancestor)
                }

                layersChanged = true
            }
        } else if hasClippingStack(.Ancestor) {
            clearClippingStack(.Ancestor)

            if hasClippingStack(.OverflowControlsHost) {
                clearClippingStack(.OverflowControlsHost)
            }

            layersChanged = true
        }

        return layersChanged
    }

    @cxx
    @implementation
    public func clearAncestorClippingStack() {
        func clearStack(_ stack: WebCore.RenderLayerBacking.ClippingStackName) {
            if !hasClippingStack(stack) {
                return
            }

            for index in 0..<clippingStackSize(stack) {
                unparentAndClearClippingStackEntryLayer(stack, index, .Clipping)
                unparentAndClearClippingStackEntryLayer(stack, index, .Scrolling)
            }
            destroyClippingStack(stack)
        }

        clearStack(.Ancestor)
        clearStack(.OverflowControlsHost)
    }

    @cxx
    @implementation
    public func detachFromScrollingCoordinator(_ roles: WebCore.ScrollCoordinationRoles) {
        if !hasAnyScrollingNodeID() {
            return
        }

        // The owning layer may be being destroyed (willBeDestroyed()): reading m_owningLayer would retain it.
        guard let scrollingCoordinator = renderer().page().scrollingCoordinator() else {
            return
        }

        if roles.contains(.Scrolling) && scrollingNodeIDForRole(.Scrolling).value != nil {
            scrollingCoordinator.unparentChildrenAndDestroyNode(scrollingNodeIDForRole(.Scrolling))
            m_scrollingNodeID = .init()

            #if os(macOS) || ENABLE_SCROLLING_THREAD // ENABLE(SCROLLING_THREAD)
            scrollContainerLayer()?.setScrollingNodeID(.init())
            layerForHorizontalScrollbar()?.setScrollingNodeID(.init())
            layerForVerticalScrollbar()?.setScrollingNodeID(.init())
            layerForScrollCorner()?.setScrollingNodeID(.init())
            #endif
        }

        if roles.contains(.ScrollingProxy) && hasClippingStack(.Ancestor) {
            detachAncestorClippingStackFromScrollingCoordinator()
        }

        if roles.contains(.FrameHosting) && scrollingNodeIDForRole(.FrameHosting).value != nil {
            scrollingCoordinator.unparentChildrenAndDestroyNode(scrollingNodeIDForRole(.FrameHosting))
            m_frameHostingNodeID = .init()
        }

        if roles.contains(.PluginHosting) && scrollingNodeIDForRole(.PluginHosting).value != nil {
            scrollingCoordinator.unparentChildrenAndDestroyNode(scrollingNodeIDForRole(.PluginHosting))
            m_pluginHostingNodeID = .init()
        }

        if roles.contains(.ViewportConstrained) && scrollingNodeIDForRole(.ViewportConstrained).value != nil {
            scrollingCoordinator.unparentChildrenAndDestroyNode(scrollingNodeIDForRole(.ViewportConstrained))
            m_viewportConstrainedNodeID = .init()
        }

        if roles.contains(.Positioning) && scrollingNodeIDForRole(.Positioning).value != nil {
            scrollingCoordinator.unparentChildrenAndDestroyNode(scrollingNodeIDForRole(.Positioning))
            m_positioningNodeID = .init()
            #if os(macOS) || ENABLE_SCROLLING_THREAD // ENABLE(SCROLLING_THREAD)
            graphicsLayer()!.setScrollingNodeID(.init())
            #endif
        }
    }

    @cxx
    @implementation
    public func setScrollingNodeIDForRole(_ nodeID: WebCore.ScrollingNodeID, _ role: WebCore.ScrollCoordinationRole) {
        switch role {
        case .Scrolling:
            m_scrollingNodeID = .init(nodeID)
            #if os(macOS) || ENABLE_SCROLLING_THREAD // ENABLE(SCROLLING_THREAD)
            scrollContainerLayer()?.setScrollingNodeID(scrollingNodeIDForRole(.Scrolling))
            layerForHorizontalScrollbar()?.setScrollingNodeID(scrollingNodeIDForRole(.Scrolling))
            layerForVerticalScrollbar()?.setScrollingNodeID(scrollingNodeIDForRole(.Scrolling))
            layerForScrollCorner()?.setScrollingNodeID(scrollingNodeIDForRole(.Scrolling))
            #endif
        case .ScrollingProxy:
            // These node IDs are stored in the ancestor clipping stack.
            assertionFailure()
        case .FrameHosting:
            m_frameHostingNodeID = .init(nodeID)
        case .PluginHosting:
            m_pluginHostingNodeID = .init(nodeID)
        case .ViewportConstrained:
            m_viewportConstrainedNodeID = .init(nodeID)
        case .Positioning:
            m_positioningNodeID = .init(nodeID)
            #if os(macOS) || ENABLE_SCROLLING_THREAD // ENABLE(SCROLLING_THREAD)
            graphicsLayer()!.setScrollingNodeID(scrollingNodeIDForRole(.Positioning))
            #endif
        @unknown default:
            break
        }
    }
}

private func setChildrenOfGraphicsLayer(_ parent: WebCore.GraphicsLayer, _ children: [WebCore.GraphicsLayer]) {
    var childList = WebCore.GraphicsLayerChildList()
    for child in children {
        childList.append(child)
    }
    childList.setAsChildrenOf(parent)
}

// MARK: - Tiled backing

private func coverage(_ value: Int) -> WebCore.TiledBacking.TileCoverage {
    WebCore.TiledBacking.TileCoverage(value)
}

extension WebCore.RenderLayerBacking {
    private func computePageTiledBackingCoverage() -> WebCore.TiledBacking.TileCoverage {
        // If the page is non-visible, don't incur the cost of keeping extra tiles for scrolling.
        if !m_owningLayer.page().isVisible() {
            return coverage(WebCore.TiledBacking.CoverageForVisibleArea)
        }

        let frameView = m_owningLayer.renderer().view().frameView()

        var tileCoverage = coverage(WebCore.TiledBacking.CoverageForVisibleArea)
        let useMinimalTilesDuringLiveResize = frameView.inLiveResize()
        if frameView.speculativeTilingEnabled() && !useMinimalTilesDuringLiveResize {
            let clipsToExposedRect = frameView.viewExposedRect().value != nil
            if frameView.horizontalScrollbarMode() != .AlwaysOff || clipsToExposedRect {
                tileCoverage |= coverage(WebCore.TiledBacking.CoverageForHorizontalScrolling)
            }

            if frameView.verticalScrollbarMode() != .AlwaysOff || clipsToExposedRect {
                tileCoverage |= coverage(WebCore.TiledBacking.CoverageForVerticalScrolling)
            }
        }
        return tileCoverage
    }

    private func computeOverflowTiledBackingCoverage() -> WebCore.TiledBacking.TileCoverage {
        // If the page is non-visible, don't incur the cost of keeping extra tiles for scrolling.
        if !m_owningLayer.page().isVisible() {
            return coverage(WebCore.TiledBacking.CoverageForVisibleArea)
        }

        var tileCoverage = coverage(WebCore.TiledBacking.CoverageForVisibleArea)
        let useMinimalTilesDuringLiveResize = m_owningLayer.renderer().view().frameView().inLiveResize()
        if !useMinimalTilesDuringLiveResize {
            if let scrollableArea = m_owningLayer.scrollableArea() {
                if scrollableArea.hasScrollableHorizontalOverflow() {
                    tileCoverage |= coverage(WebCore.TiledBacking.CoverageForHorizontalScrolling)
                }

                if scrollableArea.hasScrollableVerticalOverflow() {
                    tileCoverage |= coverage(WebCore.TiledBacking.CoverageForVerticalScrolling)
                }
            }
        }
        return tileCoverage
    }
}

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func adjustTiledBackingCoverage() {
        if m_isFrameLayerWithTiledBacking {
            let tileCoverage = computePageTiledBackingCoverage()
            if let tiled = tiledBacking() {
                tiled.setTileCoverage(tileCoverage)
            }
        }

        if m_owningLayer.hasCompositedScrollableOverflow(), let scrolled = scrolledContentsLayer() {
            let tileCoverage = computeOverflowTiledBackingCoverage()
            scrolled.setTileCoverage(tileCoverage)
        }
    }

    @cxx
    @implementation
    public func setTiledBackingHasMargins(_ margins: WebCore.BoxSideSet) {
        if !m_isFrameLayerWithTiledBacking {
            return
        }

        tiledBacking()!.setHasMargins(margins.contains(.Top), margins.contains(.Bottom), margins.contains(.Left), margins.contains(.Right))
    }
}

// MARK: - GraphicsLayerClient

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func tiledBackingUsageChanged(_ layer: WebCore.GraphicsLayer?, _ usingTiledBacking: Bool) {
        compositor().layerTiledBackingUsageChanged(layer, usingTiledBacking)
    }

    @cxx
    @implementation
    public func pageScaleFactor() -> Float {
        compositor().pageScaleFactor()
    }

    @cxx
    @implementation
    public func zoomedOutPageScaleFactor() -> Float {
        compositor().zoomedOutPageScaleFactor()
    }

    @cxx
    @implementation
    public func delegatesScaling() -> Bool {
        compositor().delegatesScaling()
    }

    @cxx
    @implementation
    public func enclosingFrameViewVisibleSize() -> WebCore.FloatSize {
        compositor().enclosingFrameViewVisibleSize()
    }

    @cxx
    @implementation
    public func deviceScaleFactor() -> Float {
        compositor().deviceScaleFactor()
    }

    @cxx
    @implementation
    public func pixelSnappingScaleFactor() -> Float {
        renderer().document().pixelSnappingScaleFactor()
    }

    @cxx
    @implementation
    public func contentsScaleMultiplierForNewTiles(_ layer: WebCore.GraphicsLayer?) -> Float {
        compositor().contentsScaleMultiplierForNewTiles(layer)
    }

    @cxx
    @implementation
    public func paintsOpaquelyAtNonIntegralScales(_: WebCore.GraphicsLayer?) -> Bool {
        m_isMainFrameRenderViewLayer
    }

    @cxx
    @implementation
    public func didChangePlatformLayerForLayer(_ layer: WebCore.GraphicsLayer?) {
        compositor().didChangePlatformLayerForLayer(m_owningLayer, layer)
    }

    @cxx
    @implementation
    public func shouldSkipLayerInDump(_ layer: WebCore.GraphicsLayer?, _ options: WebCore.LayerTreeAsTextOptionSet) -> Bool {
        if options.contains(.Debug) {
            return false
        }

        // Skip the root tile cache's flattening layer.
        return m_isMainFrameRenderViewLayer && layer != nil
            && WebCore.RenderLayerBacking.isSameGraphicsLayer(layer, childContainmentLayer())
    }

    @cxx
    @implementation
    public func shouldAggressivelyRetainTiles(_: WebCore.GraphicsLayer?) -> Bool {
        // Only the main frame TileController has enough information about in-window state to
        // correctly implement aggressive tile retention.
        if !m_isMainFrameRenderViewLayer {
            return false
        }

        return renderer().settings().aggressiveTileRetentionEnabled()
    }

    @cxx
    @implementation
    public func shouldTemporarilyRetainTileCohorts(_: WebCore.GraphicsLayer?) -> Bool {
        renderer().settings().temporaryTileCohortRetentionEnabled()
    }

    @cxx
    @implementation
    public func useGiantTiles() -> Bool {
        renderer().settings().useGiantTiles()
    }

    @cxx
    @implementation
    public func cssUnprefixedBackdropFilterEnabled() -> Bool {
        renderer().settings().cssUnprefixedBackdropFilterEnabled()
    }

    @cxx
    @implementation
    public func setNeedsFixedContainerEdgesUpdateIfNeeded() {
        if !m_owningLayer.isViewportConstrained() {
            return
        }

        setNeedsFixedContainerEdgesUpdateViaChromeClient()
    }
}

// MARK: - Configuration

extension WebCore.RenderLayerBacking {
    // The body of updateConfiguration(), called inside its LayerFreeForbiddenScope.
    @cxx
    @implementation
    public func updateConfigurationInScope(_ compositingAncestor: WebCore.RenderLayer?) -> Bool {
        assert(!m_owningLayer.normalFlowListDirty())
        assert(!m_owningLayer.zOrderListsDirty())
        assert(!renderer().view().needsLayout())

        var layerConfigChanged = false
        let compositor = self.compositor()

        if updateTransformFlatteningLayer(compositingAncestor) {
            layerConfigChanged = true
        }

        if updateViewportConstrainedSublayers(compositor.viewportConstrainedSublayers(m_owningLayer, compositingAncestor)) {
            layerConfigChanged = true
        }

        setBackgroundLayerPaintsFixedRootBackground(compositor.needsFixedRootBackgroundLayer(m_owningLayer))

        if updateBackgroundLayer(m_backgroundLayerPaintsFixedRootBackground || m_requiresBackgroundLayer) {
            layerConfigChanged = true
        }

        // Page::delegatesScaling() is set at didCommitLoad, which can be after this backing was created. Has to
        // come after updateBackgroundLayer(), which decides whether there's a contents containment layer.
        updateAppliesPageScale()

        if updateForegroundLayer(compositor.needsContentsCompositingLayer(m_owningLayer)) {
            layerConfigChanged = true
        }

        // SVG overlay segment layers depend on which children composited this pass, so recompute after
        // foreground (the two are mutually exclusive for SVG, see updatePaintingPhases).
        if updateSVGSegmentLayers() {
            layerConfigChanged = true
        }

        if updateSystemPreviewBadgeLayerForSwift() {
            layerConfigChanged = true
        }

        var needsDescendantsClippingLayer = false
        let usesCompositedScrolling = m_owningLayer.hasCompositedScrollableOverflow()

        if usesCompositedScrolling {
            needsDescendantsClippingLayer = scrollContainerClipHasNonZeroRadii()
        } else {
            needsDescendantsClippingLayer = WebCore.RenderLayerCompositor.clipsCompositingDescendants(m_owningLayer)
        }

        if updateScrollingLayers(usesCompositedScrolling) {
            layerConfigChanged = true
        }

        if updateDescendantClippingLayer(needsDescendantsClippingLayer) {
            layerConfigChanged = true
        }

        if updateAncestorClipping(compositor.clippedByAncestor(m_owningLayer, compositingAncestor), compositingAncestor) {
            layerConfigChanged = true
        }

        if updateOverflowControlsLayers(requiresHorizontalScrollbarLayer(), requiresVerticalScrollbarLayer(), requiresScrollCornerLayer()) {
            layerConfigChanged = true
        }

        if layerConfigChanged {
            updateInternalHierarchy()
        }

        // RenderLayerCompositor::adjustOverflowScrollbarContainerLayers() may have reparented the overflowControlsContainer
        // in an earlier update, so always put it back here. We don't yet know if it will get reparented again.
        if let overflowControls = overflowControlsContainer(),
            !WebCore.RenderLayerBacking.isSameGraphicsLayer(overflowControls.parent(), graphicsLayer())
        {
            graphicsLayer()!.addChildForSwift(overflowControls)
            // Ensure that we fix up the position of m_overflowControlsContainer.
            m_owningLayer.setNeedsCompositingGeometryUpdate()
        }

        // FIXME: Overlow controls need to be above the flattening layer?
        if let flatteningLayer = tileCacheFlatteningLayer() {
            if layerConfigChanged || !WebCore.RenderLayerBacking.isSameGraphicsLayer(flatteningLayer.parent(), graphicsLayer()) {
                // FIXME: m_graphicsLayer children are clobbered in RenderLayerCompositor::updateBackingAndHierarchy(); this probably
                // doesn't work.
                graphicsLayer()!.addChildForSwift(flatteningLayer)
            }
        }

        if updateMaskingLayer(renderer().hasMask(), renderer().hasClipPath()) {
            layerConfigChanged = true
        }

        updateReflectionLayer()

        var contentsInfo = PaintedContentsInfo()

        // Requires layout.
        if !m_owningLayer.isRenderViewLayer() {
            var didUpdateContentsRect = false
            updateDirectlyCompositedBoxDecorations(&contentsInfo, &didUpdateContentsRect)
        } else {
            updateRootLayerConfiguration()
        }

        // Requires layout.
        if contentsInfo.isDirectlyCompositedImage(self) {
            updateImageContents(&contentsInfo)
        }

        let unscaledBitmap = contentsInfo.isUnscaledBitmapOnly(self)
        if unscaledBitmap == graphicsLayer()!.appliesDeviceScale() {
            graphicsLayer()!.setAppliesDeviceScale(!unscaledBitmap)
            layerConfigChanged = true
        }

        let shouldPaintUsingCompositeCopy = unscaledBitmap && renderer().isRenderHTMLCanvas() && m_owningLayer.hasVisibleContent()
        if shouldPaintUsingCompositeCopy != m_shouldPaintUsingCompositeCopy {
            m_shouldPaintUsingCompositeCopy = shouldPaintUsingCompositeCopy
            graphicsLayer()!.setShouldPaintUsingCompositeCopy(shouldPaintUsingCompositeCopy)
            layerConfigChanged = true
        }

        if updateContentsLayerForReplacedRenderer() {
            layerConfigChanged = true
        }

        // FIXME: Why do we do this twice?
        if compositor.attachWidgetContentLayersIfNecessaryForSwift(renderer()).layerHierarchyChanged {
            m_owningLayer.setNeedsCompositingGeometryUpdate()
            layerConfigChanged = true
        }

        #if os(visionOS) // HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
        let clipsDescendants =
            WebCore.RenderLayerCompositor.hasCompositedWidgetContents(renderer())
            || WebCore.RenderLayerCompositor.isSeparated(renderer())
        updateSeparatedProperties()
        #else
        let clipsDescendants = WebCore.RenderLayerCompositor.hasCompositedWidgetContents(renderer())
        #endif
        if clipsDescendants {
            graphicsLayer()!.setContentsRectClipsDescendants(true)
            updateContentsRects()
        }

        if updateBackdropRoot() {
            layerConfigChanged = true
        }

        updateScreenCaptureProtection()

        if layerConfigChanged {
            updatePaintingPhases()
        }

        return layerConfigChanged
    }

    // The body of updateConfigurationAfterStyleChange(), called inside its LayerFreeForbiddenScope.
    @cxx
    @implementation
    public func updateConfigurationAfterStyleChangeInScope() {
        _ = updateMaskingLayer(renderer().hasMask(), renderer().hasClipPath())

        updateReflectionLayer()

        // FIXME: do we care if opacity is animating?
        updateOpacity()
        updateFilters(renderer()[.Style])

        updateBackdropFilters(renderer()[.Style])
        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        updateAppleVisualEffect(renderer()[.Style])
        #endif
        _ = updateBackdropRoot()
        updateScreenCaptureProtection()
        updateBlendMode()
        updateContentsScalingFilters()

        if WebCore.RenderLayerBacking.videoEnabledForSwift() {
            updateVideoGravity()
        }
    }

    fileprivate func updateRootLayerConfiguration() {
        if !m_isFrameLayerWithTiledBacking {
            return
        }

        var backgroundColor = WebCore.Color()
        let viewIsTransparent = viewHasTransparentBackgroundForSwift(&backgroundColor)

        if m_backgroundLayerPaintsFixedRootBackground, let background = backgroundLayer() {
            if m_isMainFrameRenderViewLayer {
                background.setBackgroundColor(backgroundColor)
                background.setContentsOpaque(!viewIsTransparent)
            }

            graphicsLayer()!.setBackgroundColor(WebCore.Color())
            graphicsLayer()!.setContentsOpaque(false)
        } else if m_isMainFrameRenderViewLayer {
            graphicsLayer()!.setBackgroundColor(backgroundColor)
            graphicsLayer()!.setContentsOpaque(!viewIsTransparent)
        }
    }

    fileprivate func updatePaintingPhases() {
        // Phases for m_maskLayer are set elsewhere.
        var primaryLayerPhases = WebCore.GraphicsLayerPaintingPhases(.Background)
        primaryLayerPhases.add(WebCore.GraphicsLayerPaintingPhases(.Foreground))

        if let foreground = foregroundLayer() {
            var foregroundLayerPhases = WebCore.GraphicsLayerPaintingPhases(.Foreground)

            if scrolledContentsLayer() != nil {
                foregroundLayerPhases.add(WebCore.GraphicsLayerPaintingPhases(.OverflowContents))
            }

            foreground.setPaintingPhase(foregroundLayerPhases)
            primaryLayerPhases.remove(WebCore.GraphicsLayerPaintingPhases(.Foreground))
        }

        if let background = backgroundLayer() {
            background.setPaintingPhase(WebCore.GraphicsLayerPaintingPhases(.Background))
            primaryLayerPhases.remove(WebCore.GraphicsLayerPaintingPhases(.Background))
        }

        if let scrolledContents = scrolledContentsLayer() {
            var scrolledContentLayerPhases = WebCore.GraphicsLayerPaintingPhases(.OverflowContents)
            scrolledContentLayerPhases.add(WebCore.GraphicsLayerPaintingPhases(.CompositedScroll))
            if foregroundLayer() == nil {
                scrolledContentLayerPhases.add(WebCore.GraphicsLayerPaintingPhases(.Foreground))
            }
            scrolledContents.setPaintingPhase(scrolledContentLayerPhases)

            primaryLayerPhases.remove(WebCore.GraphicsLayerPaintingPhases(.Foreground))
            primaryLayerPhases.add(WebCore.GraphicsLayerPaintingPhases(.CompositedScroll))
        }

        graphicsLayer()!.setPaintingPhase(primaryLayerPhases)

        // Overlay segment layers paint the foreground of their flat-list range. The primary graphics layer
        // keeps the Foreground phase (it paints the primary segment). Each layer's content is scoped by limiting its range,
        // not by removing a phase. A foreground layer and segments are never used together.
        assert(foregroundLayer() == nil || !hasSVGPaintOrderSegments())
        for index in 0..<svgSegmentCountForSwift() {
            svgSegmentLayerForSwift(index)?.setPaintingPhase(WebCore.GraphicsLayerPaintingPhases(.Foreground))
        }
    }
}

// MARK: - Bounds, anchor points and backdrop roots

private func floatRect(_ rect: WebCore.LayoutRect) -> WebCore.FloatRect {
    WebCore.FloatRect(rect.x().toFloat(), rect.y().toFloat(), rect.width().toFloat(), rect.height().toFloat())
}

private func layerOrAncestorIsTransformedOrUsingCompositedScrolling(_ layer: WebCore.RenderLayer) -> Bool {
    var current: WebCore.RenderLayer? = layer
    while let curr = current {
        if curr.isTransformed() || curr.hasCompositedScrollableOverflow() {
            return true
        }
        current = curr.parent()
    }

    return false
}

private func expandClipRectByFilterSamplingOutsets(_ clipRect: inout WebCore.LayoutRect, _ outsets: WebCore.IntOutsets) {
    // Preserve empty / infinite rects.
    if outsets.isZero() || clipRect.isEmpty() || clipRect.isInfinite() {
        return
    }
    clipRect.expand(WebCore.toLayoutBoxExtent(outsets))
}

extension WebCore.RenderLayerBacking {
    // Intersects clipRect with the clips that apply to the layer before the filters of its ancestors sample it, in rootLayer's
    // coordinates, and returns the outsets that the filters of the layer and its ancestors sample.
    fileprivate static func intersectClipsSampledByFilters(
        _ layer: WebCore.RenderLayer,
        _ rootLayer: WebCore.RenderLayer,
        _ clipRect: inout WebCore.LayoutRect
    ) -> WebCore.IntOutsets {
        var accumulatedOutsets = WebCore.RenderLayerBacking.filterSamplingOutsets(layer)
        var pendingClipRoot: WebCore.RenderLayer? = nil

        traverseRenderLayerAncestors(layer) { ancestorLayer, isContainingBlockChain, _ in
            if WebCore.RenderLayerBacking.ancestorLayerMayClipForSwift(layer, ancestorLayer, isContainingBlockChain) {
                pendingClipRoot = ancestorLayer
            }

            let outsets = WebCore.RenderLayerBacking.filterSamplingOutsets(ancestorLayer)
            if outsets.isZero() {
                return false
            }

            if let clipRoot = pendingClipRoot {
                // The clips from this layer up to and including clipRoot apply before the filter of ancestorLayer.
                let clipsBeforeFilter = layer.backgroundClipRect(
                    RenderLayerClipRectsContext(clipRoot, WebCore.AbsoluteClipRects, WebCore.RenderLayer.clipRectTemporaryOptionsForSwift())
                )
                if !clipsBeforeFilter.isInfinite() {
                    var rect = clipsBeforeFilter.rectValue()
                    rect.moveBy(clipRoot.convertToLayerCoords(rootLayer, WebCore.LayoutPoint(), WebCore.RenderLayer.AdjustForColumns))
                    expandClipRectByFilterSamplingOutsets(&rect, accumulatedOutsets)
                    clipRect.intersect(rect)
                }
                pendingClipRoot = nil
            }

            accumulatedOutsets = WebCore.RenderLayerBacking.accumulatedFilterSamplingOutsets(accumulatedOutsets, outsets)
            return false
        }

        return accumulatedOutsets
    }
}

private func backgroundRectForBox(_ box: WebCore.RenderBox, _ clip: WebCore.FillBox) -> WebCore.LayoutRect {
    switch clip {
    case .BorderBox:
        return box.borderBoxRect()
    case .PaddingBox:
        return box.paddingBoxRect()
    case .ContentBox:
        return box.contentBoxRect()
    default:
        break
    }

    assertionFailure()
    return WebCore.LayoutRect()
}

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func updateChildrenTransformAndAnchorPoint(
        _ primaryGraphicsLayerRect: WebCore.LayoutRect,
        _ offsetFromParentGraphicsLayer: WebCore.LayoutSize
    ) {
        let defaultAnchorPoint =
            m_owningLayer.isRenderViewLayer() || renderer().effectiveCapturedInViewTransition()
            ? WebCore.FloatPoint3D() : WebCore.FloatPoint3D(0.5, 0.5, 0)

        if !renderer().hasTransformRelatedProperty() || renderer().effectiveCapturedInViewTransition() {
            graphicsLayer()!.setAnchorPoint(defaultAnchorPoint)
            if let containment = contentsContainmentLayer() {
                containment.setAnchorPoint(defaultAnchorPoint)
            }

            if let childContainment = childContainmentLayer() {
                childContainment.setAnchorPoint(defaultAnchorPoint)
            }

            if let scrollContainer = scrollContainerLayer() {
                scrollContainer.setAnchorPoint(defaultAnchorPoint)
            }

            if let scrolledContents = scrolledContentsLayer() {
                scrolledContents.setPreserves3D(false)
            }
            return
        }

        let pixelSnappingScaleFactor = self.pixelSnappingScaleFactor()
        let transformOrigin = m_owningLayer.transformOriginPixelSnappedIfNeeded()
        let layerOffset = WebCore.roundPointToDevicePixels(WebCore.toLayoutPoint(offsetFromParentGraphicsLayer), pixelSnappingScaleFactor)
        let anchor = WebCore.FloatPoint3D(
            primaryGraphicsLayerRect.width().rawValue() != 0
                ? ((layerOffset.x() - primaryGraphicsLayerRect.x().toFloat()) + transformOrigin.x())
                    / primaryGraphicsLayerRect.width().toFloat() : 0.5,
            primaryGraphicsLayerRect.height().rawValue() != 0
                ? ((layerOffset.y() - primaryGraphicsLayerRect.y().toFloat()) + transformOrigin.y())
                    / primaryGraphicsLayerRect.height().toFloat() : 0.5,
            transformOrigin.z()
        )

        if let containment = contentsContainmentLayer() {
            containment.setAnchorPoint(anchor)
        } else {
            graphicsLayer()!.setAnchorPoint(anchor)
        }

        func removeChildrenTransformFromLayers(_ layerToIgnore: WebCore.GraphicsLayer? = nil) {
            if let clippingLayer = clippingLayer(), !WebCore.RenderLayerBacking.isSameGraphicsLayer(clippingLayer, layerToIgnore) {
                clippingLayer.setChildrenTransform(WebCore.TransformationMatrix())
                clippingLayer.setAnchorPoint(defaultAnchorPoint)
            }

            if let scrollContainer = scrollContainerLayer(), !WebCore.RenderLayerBacking.isSameGraphicsLayer(scrollContainer, layerToIgnore)
            {
                scrollContainer.setChildrenTransform(WebCore.TransformationMatrix())
                scrollContainer.setAnchorPoint(defaultAnchorPoint)
                scrolledContentsLayer()!.setPreserves3D(false)
            }

            if !WebCore.RenderLayerBacking.isSameGraphicsLayer(graphicsLayer(), layerToIgnore) {
                graphicsLayer()!.setChildrenTransform(WebCore.TransformationMatrix())
            }
        }

        if renderer()[.Style].perspectiveIsNone() {
            removeChildrenTransformFromLayers()
            return
        }

        let layerForPerspective: WebCore.GraphicsLayer
        let layerForPerspectiveRect: WebCore.FloatRect
        if let scrollContainer = scrollContainerLayer() {
            // Scroll container layers are only created for RenderBox derived renderers.
            layerForPerspective = scrollContainer
            layerForPerspectiveRect = floatRect(renderer().asRenderBox()!.paddingBoxRect())
        } else if let clipping = clippingLayer() {
            layerForPerspective = clipping
            layerForPerspectiveRect = floatRect(clippingLayerBoxForSwift())
        } else {
            layerForPerspective = graphicsLayer()!
            layerForPerspectiveRect = renderer().transformReferenceBoxRect(renderer()[.Style])
        }

        if !WebCore.RenderLayerBacking.isSameGraphicsLayer(layerForPerspective, graphicsLayer()) {
            // If we have scrolling layers, we need the children transform on m_scrollContainerLayer to
            // affect children of m_scrolledContentsLayer, so set setPreserves3D(true).
            if WebCore.RenderLayerBacking.isSameGraphicsLayer(layerForPerspective, scrollContainerLayer()) {
                scrolledContentsLayer()!.setPreserves3D(true)
            }

            let perspectiveAnchorPoint = WebCore.FloatPoint3D(
                layerForPerspectiveRect.width() != 0
                    ? (transformOrigin.x() - layerForPerspectiveRect.x()) / layerForPerspectiveRect.width() : 0.5,
                layerForPerspectiveRect.height() != 0
                    ? (transformOrigin.y() - layerForPerspectiveRect.y()) / layerForPerspectiveRect.height() : 0.5,
                transformOrigin.z()
            )

            layerForPerspective.setAnchorPoint(perspectiveAnchorPoint)
        }

        layerForPerspective.setChildrenTransform(m_owningLayer.perspectiveTransform())
        removeChildrenTransformFromLayers(layerForPerspective)
    }

    @cxx
    @implementation
    public func updateBackdropRoot() -> Bool {
        // Don't try to make the RenderView's layer a backdrop root if it's going to
        // paint into the window since it won't work (WebKitLegacy only).
        var willBeBackdropRoot = m_owningLayer.isBackdropRoot() && !paintsIntoWindow()

        // If the RenderView is opaque, then that will occlude any pixels behind it and we don't need
        // to isolate it as a backdrop root.
        //
        // Always allow for the main frame so that clients can intentionally allow backdrop blending outside of the webview by setting it to
        // transparent.
        if m_owningLayer.isRenderViewLayer() && (m_isMainFrameRenderViewLayer || !viewHasTransparentBackgroundForSwift()) {
            willBeBackdropRoot = false
        }

        if graphicsLayer()!.isBackdropRoot() == willBeBackdropRoot {
            return false
        }

        graphicsLayer()!.setIsBackdropRoot(willBeBackdropRoot)
        return true
    }

    @cxx
    @implementation
    public func shouldClipCompositedBounds() -> Bool {
        #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) // !PLATFORM(IOS_FAMILY)
        // Scrollbar layers use this layer for relative positioning, so don't clip.
        if layerForHorizontalScrollbar() != nil || layerForVerticalScrollbar() != nil {
            return false
        }
        #endif

        if renderer().effectiveCapturedInViewTransition() {
            return false
        }
        if renderer()[.Style].pseudoElementType().value == .ViewTransitionNew {
            return false
        }

        if m_isFrameLayerWithTiledBacking {
            return false
        }

        if layerOrAncestorIsTransformedOrUsingCompositedScrolling(m_owningLayer) {
            return false
        }

        return true
    }

    // Returns true if changed.
    @cxx
    @implementation
    public func updateCompositedBounds() -> Bool {
        var boundsFlags = WebCore.RenderLayer.defaultCalculateLayerBoundsFlags()
        boundsFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.ExcludeHiddenDescendants))
        boundsFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.DontConstrainForMask))

        var layerBounds = m_owningLayer.calculateLayerBounds(m_owningLayer, WebCore.LayoutSize(), boundsFlags)
        // Clip to the size of the document or enclosing overflow-scroll layer.
        // If this or an ancestor is transformed, we can't currently compute the correct rect to intersect with.
        // We'd need RenderObject::convertContainerToLocalQuad(), which doesn't yet exist.
        if shouldClipCompositedBounds() {
            let view = renderer().view()
            let rootLayer = view.layer()!

            var clippingBounds: WebCore.LayoutRect
            if renderer().isFixedPositioned() && WebCore.RenderObject.isSameRenderer(renderer().container(), view) {
                clippingBounds = view.frameView().rectForFixedPositionLayout()
            } else {
                clippingBounds = WebCore.LayoutRect(view.unscaledDocumentRect())
            }

            if !isSameRenderLayer(m_owningLayer, rootLayer) {
                var outsetsForFilters = WebCore.IntOutsets()
                if view.hasRenderersWithPixelMovingFilter() {
                    var clipsSampledByFilters = WebCore.LayoutRect.infiniteRect()
                    outsetsForFilters = WebCore.RenderLayerBacking.intersectClipsSampledByFilters(
                        m_owningLayer,
                        rootLayer,
                        &clipsSampledByFilters
                    )
                    expandClipRectByFilterSamplingOutsets(&clippingBounds, outsetsForFilters)
                    clippingBounds.intersect(clipsSampledByFilters)
                }

                var backgroundClipRect = m_owningLayer.backgroundClipRect(RenderLayerClipRectsContext(rootLayer, WebCore.AbsoluteClipRects))
                    .rectValue() // FIXME: Incorrect for CSS regions.
                expandClipRectByFilterSamplingOutsets(&backgroundClipRect, outsetsForFilters)
                clippingBounds.intersect(backgroundClipRect)
            }

            let delta = m_owningLayer.convertToLayerCoords(rootLayer, WebCore.LayoutPoint(), WebCore.RenderLayer.AdjustForColumns)
            clippingBounds.move(WebCore.LayoutSize() - WebCore.toLayoutSize(delta))

            layerBounds.intersect(clippingBounds)
        }

        // If the backing provider has overflow:clip, we know all sharing layers are affected by the clip because they are containing-block
        // descendants.
        if !renderer().hasNonVisibleOverflow() {
            let sharingLayers = backingSharingLayersForSwift()
            for index in 0..<sharingLayers.size() {
                guard let layer = sharingLayers.layerAt(index) else {
                    continue
                }
                let boundsRootLayer = m_owningLayer
                assert(layer.isDescendantOf(m_owningLayer))
                let offset = layer.offsetFromAncestor(m_owningLayer, WebCore.RenderLayer.DontAdjustForColumns)
                let bounds = layer.calculateLayerBounds(boundsRootLayer, offset, boundsFlags)
                layerBounds.unite(bounds)
            }
        }

        // If the element has a transform-origin that has fixed lengths, and the renderer has zero size,
        // then we need to ensure that the compositing layer has non-zero size so that we can apply
        // the transform-origin via the GraphicsLayer anchorPoint (which is expressed as a fractional value).
        if layerBounds.isEmpty() && (rendererHasNonZeroTransformOrigin() || !renderer()[.Style].perspectiveIsNone()) {
            layerBounds.setWidth(WebCore.LayoutUnit(Int32(1)))
            layerBounds.setHeight(WebCore.LayoutUnit(Int32(1)))
            m_artificiallyInflatedBounds = true
        } else {
            m_artificiallyInflatedBounds = false
        }

        return setCompositedBounds(layerBounds)
    }

    @cxx
    @implementation
    public func updateAllowsBackingStoreDetaching(_ allowDetachingForFixed: Bool) {
        func setAllowsBackingStoreDetaching(_ allowDetaching: Bool) {
            if graphicsLayer()!.allowsBackingStoreDetaching() == allowDetaching {
                return
            }

            // isDirectlyCompositedImage depends on this value
            m_owningLayer.setNeedsCompositingConfigurationUpdate()

            graphicsLayer()!.setAllowsBackingStoreDetaching(allowDetaching)
            if let foreground = foregroundLayer() {
                foreground.setAllowsBackingStoreDetaching(allowDetaching)
            }
            for index in 0..<svgSegmentCountForSwift() {
                svgSegmentLayerForSwift(index)?.setAllowsBackingStoreDetaching(allowDetaching)
            }
            if let background = backgroundLayer() {
                background.setAllowsBackingStoreDetaching(allowDetaching)
            }
            if let scrolledContents = scrolledContentsLayer() {
                scrolledContents.setAllowsBackingStoreDetaching(allowDetaching)
            }
        }

        if !m_owningLayer.behavesAsFixed() {
            setAllowsBackingStoreDetaching(!isInPromotedSpatialPortalChildForSwift())
            return
        }

        setAllowsBackingStoreDetaching(allowDetachingForFixed)
    }

    @cxx
    @implementation
    public func updateAfterLayout(_ needsClippingUpdate: Bool, _ needsFullRepaint: Bool) {
        // This is the main trigger for layout changing layer geometry, but we have to do the work again in updateBackingAndHierarchy()
        // when we know the final compositing hierarchy. We can't just set dirty bits from RenderLayer::setSize() because that doesn't
        // take overflow into account.
        if updateCompositedBounds() {
            m_owningLayer.setNeedsCompositingGeometryUpdate()
            // This layer's geometry affects those of its children.
            m_owningLayer.setChildrenNeedCompositingGeometryUpdate()
            m_owningLayer.setSubsequentLayersNeedCompositingRequirementsTraversal()
        } else if needsClippingUpdate {
            m_owningLayer.setNeedsCompositingConfigurationUpdate()
            m_owningLayer.setNeedsCompositingGeometryUpdate()
        }

        if needsFullRepaint && canIssueSetNeedsDisplay() {
            setContentsNeedDisplay(.Clip)
        }
    }

    @cxx
    @implementation
    public func paintsIntoWindow() -> Bool {
        if m_isFrameLayerWithTiledBacking {
            return false
        }

        if m_owningLayer.isRenderViewLayer() {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
            if compositor().inForcedCompositingMode() {
                return false
            }
            #endif

            // Site-isolated root frames don't have a window to paint into.
            if m_isRootFrameRenderViewLayer && !m_isMainFrameRenderViewLayer {
                return false
            }

            return compositor().rootLayerAttachment() != WebCore.RenderLayerCompositor.RootLayerAttachedViaEnclosingFrame
        }

        return false
    }

    @cxx
    @implementation
    public func setRequiresOwnBackingStore(_ requiresOwnBacking: Bool) {
        if requiresOwnBacking == m_requiresOwnBackingStore {
            return
        }

        m_requiresOwnBackingStore = requiresOwnBacking

        // This affects the answer to paintsIntoCompositedAncestor(), which in turn affects
        // cached clip rects, so we have to notify the layer.
        m_owningLayer.compositingStatusChangedForCompositor(.Yes)

        compositor().repaintInCompositedAncestor(m_owningLayer, compositedBounds())

        // This change can make m_owningLayer start or stop being a segment anchor in its enclosing SVG
        // container, so re-run that container's segmentation.
        m_owningLayer.invalidateEnclosingSVGContainerSegmentation()

        #if os(visionOS) // ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
        if !requiresOwnBacking {
            clearInteractionRegions()
        }
        #endif
    }

    @cxx
    @implementation
    public func backgroundBoxForSimpleContainerPainting() -> WebCore.FloatRect {
        guard let box = renderer().asRenderBox() else {
            return WebCore.FloatRect()
        }

        var backgroundBox = backgroundRectForBox(box, renderer()[.Style].backgroundFirstLayerClip())
        backgroundBox.move(contentOffsetInCompositingLayer())
        return WebCore.snapRectToDevicePixels(backgroundBox, pixelSnappingScaleFactor())
    }
}

// MARK: - Painted contents

private enum PaintedContentsType {
    case unknown
    case simpleContainer
    case directlyCompositedImage
    case unscaledBitmapOnly
    case painted
}

// This acts as a cache of what we know about what is painting into a RenderLayerBacking.
private struct PaintedContentsInfo {
    var boxDecorations = WebCore.RequestState.Unknown
    var content = WebCore.RequestState.Unknown
    #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
    var hdrContent = WebCore.RequestState.DontCare
    var rendererHDRContent = WebCore.RequestState.DontCare
    #endif
    var contentsType = PaintedContentsType.unknown

    #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
    mutating func setDetectsHDRContent() {
        hdrContent = .Unknown
        rendererHDRContent = .Unknown
    }
    #endif

    mutating func determinePaintsBoxDecorations(_ backing: WebCore.RenderLayerBacking) {
        if boxDecorations != .Unknown {
            return
        }

        boxDecorations = backing.paintsBoxDecorations() ? .True : .False
    }

    mutating func paintsBoxDecorations(_ backing: WebCore.RenderLayerBacking) -> Bool {
        determinePaintsBoxDecorations(backing)
        return boxDecorations == .True || boxDecorations == .Undetermined
    }

    func isPaintsContentSatisfied() -> Bool {
        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        if hdrContent == .Unknown {
            return false
        }
        #endif
        return content != .Unknown
    }

    mutating func determinePaintsContent(_ backing: WebCore.RenderLayerBacking) {
        if isPaintsContentSatisfied() {
            return
        }

        var contentRequest = WebCore.RenderLayer.PaintedContentRequest()
        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        contentRequest.setHDRRequestState(hdrContent)
        #endif

        backing.determinePaintsContent(&contentRequest)
        content = contentRequest.hasPaintedContent
        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        hdrContent = contentRequest.hasHDRContent
        #endif
    }

    mutating func paintsContent(_ backing: WebCore.RenderLayerBacking) -> Bool {
        determinePaintsContent(backing)
        return content == .True || content == .Undetermined
    }

    #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
    mutating func paintsHDRContent(_ backing: WebCore.RenderLayerBacking) -> Bool {
        determinePaintsContent(backing)
        return hdrContent == .True
    }
    #endif

    func isContentsTypeSatisfied() -> Bool {
        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        if rendererHDRContent == .Unknown {
            return false
        }
        #endif
        return contentsType != .unknown
    }

    mutating func determineContentsType(_ backing: WebCore.RenderLayerBacking) {
        if isContentsTypeSatisfied() {
            return
        }

        contentsType = backing.contentsType(&self)

        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        if rendererHDRContent == .Unknown {
            rendererHDRContent = backing.owningLayer().rendererHasHDRContent() ? .True : .False
        }
        #endif
    }

    mutating func isSimpleContainer(_ backing: WebCore.RenderLayerBacking) -> Bool {
        determineContentsType(backing)
        return contentsType == .simpleContainer
    }

    mutating func isDirectlyCompositedImage(_ backing: WebCore.RenderLayerBacking) -> Bool {
        determineContentsType(backing)
        return contentsType == .directlyCompositedImage
    }

    mutating func isUnscaledBitmapOnly(_ backing: WebCore.RenderLayerBacking) -> Bool {
        determineContentsType(backing)
        return contentsType == .unscaledBitmapOnly
    }

    #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
    mutating func rendererHasHDRContent(_ backing: WebCore.RenderLayerBacking) -> Bool { // FIXME: Why do we need this?
        determineContentsType(backing)
        return rendererHDRContent == .True
    }
    #endif
}

// FIXME: Code is duplicated in RenderLayer. Also, we should probably not consider filters a box decoration here.
private func hasVisibleBoxDecorations(_ renderer: WebCore.RenderLayerModelObject) -> Bool {
    renderer[.Style].borderHasVisibleBorder()
        || renderer[.Style].hasBorderRadius()
        || renderer[.Style].hasOutline()
        || renderer[.Style].hasUsedAppearance()
        || !renderer[.Style].boxShadowIsNone()
        || renderer[.Style].hasFilter()
}

private func hasPerspectiveOrPreserves3D(_ renderer: WebCore.RenderLayerModelObject) -> Bool {
    !renderer[.Style].perspectiveIsNone() || renderer[.Style].usedTransformStyle3D() == .Preserve3D
}

extension WebCore.RenderLayerBacking {
    fileprivate func hasPaintedBoxDecorationsOrBackgroundImage() -> Bool {
        if hasVisibleBoxDecorations(renderer()) {
            return true
        }

        if !renderer()[.Style].hasImageInAnyBackgroundLayer() {
            return false
        }

        return !canDirectlyCompositeBackgroundImage()
    }

    fileprivate func supportsDirectlyCompositedBoxDecorations() -> Bool {
        if renderer().hasClip() {
            return false
        }

        if renderer()[.Style].borderHasNonRoundCornerShape() {
            return false
        }

        if hasPaintedBoxDecorationsOrBackgroundImage() {
            return false
        }

        // FIXME: We can't create a directly composited background if this
        // layer will have children that intersect with the background layer.
        // A better solution might be to introduce a flattening layer if
        // we do direct box decoration composition.
        // https://bugs.webkit.org/show_bug.cgi?id=119461
        if hasPerspectiveOrPreserves3D(renderer()) {
            return false
        }

        return true
    }

    fileprivate func paintsBoxDecorations() -> Bool {
        if !m_owningLayer.hasVisibleBoxDecorations() {
            return false
        }

        return !supportsDirectlyCompositedBoxDecorations()
    }

    fileprivate func determinePaintsContent(_ request: inout WebCore.RenderLayer.PaintedContentRequest) {
        m_owningLayer.updateDescendantDependentFlags()
        var shouldScanDescendants = m_owningLayer.hasVisibleContent()

        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        if !request.isHDRContentSatisfied() {
            shouldScanDescendants = true
        }
        #endif

        if shouldScanDescendants {
            m_owningLayer.determineNonLayerDescendantsPaintedContent(&request)

            if request.isSatisfied() {
                return
            }
        }

        determineNonCompositedLayerDescendantsPaintedContent(&request)

        if request.isSatisfied() {
            return
        }

        if m_owningLayer.renderer().isRenderSVGModelObject() {
            // FIXME: [LBSE] Eventually cache if we're part of a RenderSVGHiddenContainer subtree to avoid tree walks.
            // FIXME: [LBSE] Eventually refine the logic to end up with a narrower set of conditions (webkit.org/b/243417).
            if m_owningLayer.hasVisibleContent() && !isInRenderSVGHiddenContainer(m_owningLayer.renderer()) {
                request.setHasPaintedContent()
            }

            if request.isSatisfied() {
                return
            }
        }

        if request.hasPaintedContent == .Unknown {
            request.hasPaintedContent = .False
        }

        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        if request.hasHDRContent == .Unknown {
            request.hasHDRContent = .False
        }
        #endif
    }

    // A "simple container layer" is a RenderLayer which has no visible content to render.
    // It may have no children, or all its children may be themselves composited.
    // This is a useful optimization, because it allows us to avoid allocating backing store.
    fileprivate func isSimpleContainerCompositingLayer(_ contentsInfo: inout PaintedContentsInfo) -> Bool {
        if m_owningLayer.isRenderViewLayer() {
            return false
        }

        if (rendererIsSpatialPortal() || isInPromotedSpatialPortalChildForSwift()) && rendererBackgroundColor().isVisible() {
            return false
        }

        // Scroll containers intentionally use the bitmap path for their background
        // in updateDrawsContent(), so they are not simple containers.
        if scrollContainerLayer() != nil {
            return false
        }

        if hasBackingSharingLayers() {
            return false
        }

        if rendererIsReplacedAndPaintsContent() {
            return false
        }

        if renderer().isRenderTextControl() {
            return false
        }

        if contentsInfo.paintsBoxDecorations(self) || contentsInfo.paintsContent(self) {
            return false
        }

        if renderer()[.Style].backgroundFirstLayerClip() == .Text
            || renderer()[.Style].backgroundFirstLayerClip() == .BorderAreaText
        {
            return false
        }

        if renderer().isDocumentElementRenderer() && m_owningLayer.isolatesCompositedBlending() {
            return false
        }

        return true
    }

    fileprivate func contentsType(_ contentsInfo: inout PaintedContentsInfo) -> PaintedContentsType {
        if isSimpleContainerCompositingLayer(&contentsInfo) {
            return .simpleContainer
        }
        if isDirectlyCompositedImage() {
            return .directlyCompositedImage
        }
        if isUnscaledBitmapOnly() {
            return .unscaledBitmapOnly
        }
        return .painted
    }

    fileprivate func determineNonCompositedLayerDescendantsPaintedContent(_ request: inout WebCore.RenderLayer.PaintedContentRequest) {
        var hasPaintingDescendant = false
        _ = traverseLayersForPaintedContentDetection(m_owningLayer) { layer in
            var localRequest = WebCore.RenderLayer.PaintedContentRequest()
            #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
            localRequest.setHDRRequestState(request.hasHDRContent)
            #endif
            if layer.isVisuallyNonEmptyForSwift(&localRequest) {
                let mayIntersect = intersectsWithAncestor(layer, m_owningLayer, compositedBounds()) ?? true
                if mayIntersect {
                    hasPaintingDescendant = true
                    request.setHasPaintedContent()
                }
            }
            #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
            if localRequest.probablyHasPaintedContent() && localRequest.hasHDRContent == .True {
                request.hasHDRContent = .True
            }
            #endif
            return (hasPaintingDescendant && request.isSatisfied()) ? .stop : .continue
        }
    }

    fileprivate func hasVisibleNonCompositedDescendants() -> Bool {
        var hasVisibleDescendant = false
        _ = traverseVisibleNonCompositedDescendantLayers(m_owningLayer) { layer in
            hasVisibleDescendant = hasVisibleDescendant || layer.hasVisibleContent()
            return hasVisibleDescendant ? .stop : .continue
        }

        return hasVisibleDescendant
    }

    fileprivate func containsPaintedContent(_ contentsInfo: inout PaintedContentsInfo) -> Bool {
        if contentsInfo.isSimpleContainer(self) || paintsIntoWindow() || paintsIntoCompositedAncestor() || m_artificiallyInflatedBounds
            || m_owningLayer.isReflection()
        {
            return false
        }

        return rendererContainsPaintedContent(contentsInfo.isDirectlyCompositedImage(self))
    }

    fileprivate func updateDirectlyCompositedBoxDecorations(_ contentsInfo: inout PaintedContentsInfo, _ didUpdateContentsRect: inout Bool)
    {
        if !m_owningLayer.hasVisibleContent() {
            return
        }

        // The order of operations here matters, since the last valid type of contents needs
        // to also update the contentsRect.
        updateDirectlyCompositedBackgroundColor(&contentsInfo, &didUpdateContentsRect)
        updateDirectlyCompositedBackgroundImage(&contentsInfo, &didUpdateContentsRect)
    }

    fileprivate func updateDirectlyCompositedBackgroundColor(_ contentsInfo: inout PaintedContentsInfo, _ didUpdateContentsRect: inout Bool)
    {
        if let background = backgroundLayer(), !m_backgroundLayerPaintsFixedRootBackground, !contentsInfo.paintsBoxDecorations(self) {
            graphicsLayer()!.setContentsToSolidColor(WebCore.Color())
            background.setContentsToSolidColor(rendererBackgroundColor())

            var contentsRect = backgroundBoxForSimpleContainerPainting()
            // NOTE: This is currently only used by RenderFullScreen, which we want to be
            // big enough to hide overflow areas of the root.
            contentsRect.inflate(contentsRect.size())
            background.setContentsRect(contentsRect)
            background.setContentsClippingRect(WebCore.FloatRoundedRect(contentsRect, WebCore.CornerRadii()))
            return
        }

        if !contentsInfo.isSimpleContainer(self) || (renderer().asRenderBox() != nil && !boxPaintsOwnBackground()) {
            graphicsLayer()!.setContentsToSolidColor(WebCore.Color())
            return
        }

        let backgroundColor = rendererBackgroundColor()

        // An unset (invalid) color will remove the solid color.
        graphicsLayer()!.setContentsToSolidColor(backgroundColor)
        let contentsRect = backgroundBoxForSimpleContainerPainting()
        graphicsLayer()!.setContentsRect(contentsRect)
        graphicsLayer()!.setContentsClippingRect(WebCore.FloatRoundedRect(contentsRect, WebCore.CornerRadii()))
        didUpdateContentsRect = true
    }

    fileprivate func updateDirectlyCompositedBackgroundImage(_ contentsInfo: inout PaintedContentsInfo, _ didUpdateContentsRect: inout Bool)
    {
        if !WebCore.GraphicsLayer.supportsContentsTiling() {
            return
        }

        if contentsInfo.isDirectlyCompositedImage(self) {
            return
        }

        if updateDirectlyCompositedBackgroundImage(contentsInfo.isSimpleContainer(self)) {
            didUpdateContentsRect = true
        }
    }

    fileprivate func updateImageContents(_ contentsInfo: inout PaintedContentsInfo) {
        if !updateImageContents() {
            return
        }

        updateContentsRects()
        updateDrawsContent(&contentsInfo)
    }

    // The body of updateAfterDescendants(), called inside its LayerFreeForbiddenScope.
    @cxx
    @implementation
    public func updateAfterDescendantsInScope() {
        // FIXME: this potentially duplicates work we did in updateConfiguration().
        var contentsInfo = PaintedContentsInfo()

        if !m_owningLayer.isRenderViewLayer() {
            var didUpdateContentsRect = false
            updateDirectlyCompositedBoxDecorations(&contentsInfo, &didUpdateContentsRect)
            if !didUpdateContentsRect && graphicsLayer()!.usesContentsLayer() {
                resetContentsRect()
            }
        }

        updateDrawsContent(&contentsInfo)

        if !m_isMainFrameRenderViewLayer && !m_isFrameLayerWithTiledBacking && !m_requiresBackgroundLayer {
            // For non-root layers, background is always painted by the primary graphics layer.
            assert(backgroundLayer() == nil)
            graphicsLayer()!
                .setContentsOpaque(!m_hasSubpixelRounding && m_owningLayer.backgroundIsKnownToBeOpaqueInRect(compositedBounds()))
        }

        graphicsLayer()!.setContentsVisible(m_owningLayer.hasVisibleContent() || hasVisibleNonCompositedDescendants())
        if let scrollContainer = scrollContainerLayer() {
            scrollContainer.setContentsVisible(renderer().usedVisibility() == .Visible)

            let userInteractive = renderer().visibleToHitTesting(.init())
            scrollContainer.setUserInteractionEnabled(userInteractive)
            layerForHorizontalScrollbar()?.setUserInteractionEnabled(userInteractive)
            layerForVerticalScrollbar()?.setUserInteractionEnabled(userInteractive)
            layerForScrollCorner()?.setUserInteractionEnabled(userInteractive)
        }

        updatePortalPromotedChildrenForSwift()
    }

    fileprivate func resetContentsRect() {
        updateContentsRects()
        graphicsLayer()!.setContentsTileSize(WebCore.FloatSize())
        graphicsLayer()!.setContentsTilePhase(WebCore.FloatSize())
    }

    // The body of updateDrawsContent(), called inside its LayerFreeForbiddenScope.
    @cxx
    @implementation
    public func updateDrawsContentInScope() {
        var contentsInfo = PaintedContentsInfo()
        updateDrawsContent(&contentsInfo)
    }

    fileprivate func updateDrawsContent(_ contentsInfo: inout PaintedContentsInfo) {
        if scrollContainerLayer() != nil {
            // We don't have to consider overflow controls, because we know that the scrollbars are drawn elsewhere.
            // m_graphicsLayer only needs backing store if the non-scrolling parts (background, outlines, borders, shadows etc) need to
            // paint.
            // m_scrollContainerLayer never has backing store.
            // m_scrolledContentsLayer only needs backing store if the scrolled contents need to paint.
            let hasNonScrollingPaintedContent = m_owningLayer.hasVisibleContent() && m_owningLayer.hasVisibleBoxDecorationsOrBackground()
            graphicsLayer()!.setDrawsContent(hasNonScrollingPaintedContent)

            let hasScrollingPaintedContent =
                hasBackingSharingLayers()
                || (m_owningLayer.hasVisibleContent() && (renderer().hasBackground() || contentsInfo.paintsContent(self)))
            scrolledContentsLayer()!.setDrawsContent(hasScrollingPaintedContent)
            return
        }

        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        if renderer().document().drawsHDRContent() {
            contentsInfo.setDetectsHDRContent()
        }
        #endif

        let hasPaintedContent = containsPaintedContent(&contentsInfo)

        // FIXME: we could refine this to only allocate backing for one of these layers if possible.
        graphicsLayer()!.setDrawsContent(hasPaintedContent)
        if let foreground = foregroundLayer() {
            foreground.setDrawsContent(hasPaintedContent)
        }

        if hasSVGPaintOrderSegments() {
            updateSVGSegmentLayersDrawsContent(hasPaintedContent)
        }

        if let background = backgroundLayer() {
            background.setDrawsContent(
                m_backgroundLayerPaintsFixedRootBackground ? hasPaintedContent : contentsInfo.paintsBoxDecorations(self)
            )
        }

        #if os(macOS) || os(iOS) || os(visionOS) // HAVE(SUPPORT_HDR_DISPLAY)
        updateDrawsHDRContent(contentsInfo.paintsHDRContent(self) || contentsInfo.rendererHasHDRContent(self))
        #endif
    }

    // The body of contentChanged(), called inside its LayerFreeForbiddenScope.
    @cxx
    @implementation
    public func contentChangedInScope(_ changeType: WebCore.ContentChangeType, _ dirtyRect: WebCore.RenderLayer.OptionalFloatRect) {
        var contentsInfo = PaintedContentsInfo()
        #if os(visionOS) // HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
        if changeType == .Image && WebCore.RenderLayerCompositor.isSeparated(renderer()) {
            updateSeparatedProperties()
        }
        #endif
        if changeType == .Image || changeType == .Canvas {
            if contentsInfo.isDirectlyCompositedImage(self) {
                updateImageContents(&contentsInfo)
                return
            }
            if contentsInfo.isUnscaledBitmapOnly(self) != graphicsLayer()!.appliesDeviceScale() {
                compositor().scheduleCompositingLayerUpdate()
                return
            }
        }

        if changeType == .Video {
            compositor().scheduleCompositingLayerUpdate()
            return
        }

        if WebCore.RenderLayerBacking.modelElementEnabledForSwift() && changeType == .Model {
            compositor().scheduleCompositingLayerUpdate()
            return
        }

        if changeType == .BackgroundImage && canDirectlyCompositeBackgroundImage() {
            m_owningLayer.setNeedsCompositingConfigurationUpdate()
        }

        if changeType == .MaskImage && maskLayer() != nil {
            m_owningLayer.setNeedsCompositingConfigurationUpdate()
        }

        if WebCore.RenderLayerBacking.webGLOrOffscreenCanvasEnabledForSwift() {
            if (changeType == .Canvas || changeType == .CanvasPixels) && renderer().isRenderHTMLCanvas()
                && WebCore.canvasCompositingStrategy(renderer()) == WebCore.CanvasAsLayerContents
            {
                if changeType == .Canvas {
                    compositor().scheduleCompositingLayerUpdate()
                }

                if let rect = dirtyRect.value {
                    graphicsLayer()!.setContentsNeedsDisplayInRect(rect)
                } else {
                    graphicsLayer()!.setContentsNeedsDisplay()
                }
                return
            }
        }
    }
}

private func isInRenderSVGHiddenContainer(_ renderer: WebCore.RenderLayerModelObject) -> Bool {
    if renderer.isRenderSVGHiddenContainer() {
        return true
    }

    var ancestor: WebCore.RenderElement? = (renderer as WebCore.RenderObject).parent()
    while let element = ancestor {
        if element.isRenderSVGHiddenContainer() {
            return true
        }
        ancestor = (element as WebCore.RenderObject).parent()
    }
    return false
}

// Returning .stop stops the traversal.
private enum LayerTraversal {
    case `continue`
    case stop
}

private func traverseVisibleNonCompositedLayers(
    in parent: WebCore.RenderLayer,
    _ list: WebCore.PaintOrderList,
    _ layerFunc: (WebCore.RenderLayer) -> LayerTraversal
) -> LayerTraversal {
    var index = 0
    while index < parent.paintOrderListCount(list) {
        let childLayer = parent.paintOrderListLayer(list, index)
        index += 1
        if WebCore.compositedWithOwnBackingStore(childLayer) || childLayer.paintsIntoProvidedBacking() {
            continue
        }

        if layerFunc(childLayer) == .stop {
            return .stop
        }

        if traverseVisibleNonCompositedDescendantLayers(childLayer, layerFunc) == .stop {
            return .stop
        }
    }
    return .continue
}

private func traverseVisibleNonCompositedDescendantLayers(
    _ parent: WebCore.RenderLayer,
    _ layerFunc: (WebCore.RenderLayer) -> LayerTraversal
) -> LayerTraversal {
    // FIXME: We shouldn't be called with a stale z-order lists. See bug 85512.
    parent.updateLayerListsIfNeeded()

    return parent.withLayerListMutationForbidden { () -> LayerTraversal in
        if traverseVisibleNonCompositedLayers(in: parent, .NormalFlow, layerFunc) == .stop {
            return .stop
        }

        if parent.isStackingContext() && !parent.hasVisibleDescendant() {
            return .continue
        }

        // Use the m_hasCompositingDescendant bit to optimize?
        if traverseVisibleNonCompositedLayers(in: parent, .Negative, layerFunc) == .stop {
            return .stop
        }

        return traverseVisibleNonCompositedLayers(in: parent, .Positive, layerFunc)
    }
}

private func traverseLayersForPaintedContentDetection(
    _ backingOwnerLayer: WebCore.RenderLayer,
    _ layerFunc: (WebCore.RenderLayer) -> LayerTraversal
) -> LayerTraversal {
    if traverseVisibleNonCompositedDescendantLayers(backingOwnerLayer, layerFunc) == .stop {
        return .stop
    }

    if backingOwnerLayer.isComposited(), let backing = backingOwnerLayer.backing(), backing.hasBackingSharingLayers() {
        let sharingLayers = backing.backingSharingLayersForSwift()
        for index in 0..<sharingLayers.size() {
            guard let sharingLayer = sharingLayers.layerAt(index) else {
                continue
            }

            if layerFunc(sharingLayer) == .stop {
                return .stop
            }

            if traverseVisibleNonCompositedDescendantLayers(sharingLayer, layerFunc) == .stop {
                return .stop
            }
        }
    }

    return .continue
}

private func intersectsWithAncestor(
    _ child: WebCore.RenderLayer,
    _ ancestor: WebCore.RenderLayer,
    _ ancestorCompositedBounds: WebCore.LayoutRect
) -> Bool? {
    // If any layers between child and ancestor are transformed, then adjusting the offset is
    // insufficient to convert coordinates into ancestor's coordinate space.
    if !child.canUseOffsetFromAncestor(ancestor) {
        return nil
    }

    let overlap = child.boundingBox(
        ancestor,
        child.offsetFromAncestor(ancestor, WebCore.RenderLayer.DontAdjustForColumns),
        WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.UseFragmentBoxesExcludingCompositing)
    )
    return overlap.intersects(ancestorCompositedBounds)
}

// MARK: - Style

extension WebCore.RenderLayerBacking {
    fileprivate func updateOpacity() {
        graphicsLayer()!.setOpacity(compositingOpacity(renderer()[.Style].opacityValue()))
    }

    fileprivate func updateBlendMode() {
        // FIXME: where is the blend mode updated when m_ancestorClippingStacks come and go?
        let blendMode = renderer()[.Style].usedBlendMode()
        if hasClippingStack(.Ancestor) {
            clippingStackEntryLayer(.Ancestor, 0, .Clipping)!.setBlendMode(blendMode)
            graphicsLayer()!.setBlendMode(.Normal)
        } else {
            graphicsLayer()!.setBlendMode(blendMode)
        }
    }

    fileprivate func updateVideoGravity() {
        if !renderer().isRenderVideo() {
            return
        }

        let videoGravity: WebCore.MediaPlayerVideoGravity
        if !renderer()[.Style].objectViewBoxIsNone() {
            // The cropped-frame geometry computed for object-view-box already bakes in
            // object-fit/object-position, so let it fill its (precomputed) contents rect as-is.
            videoGravity = .Resize
        } else {
            switch renderer()[.Style].objectFit() {
            case .Contain:
                videoGravity = .ResizeAspect
            case .Cover:
                videoGravity = .ResizeAspectFill
            default:
                // Fill, and None and ScaleDown.
                // FIXME: Add support for "None" and "ScaleDown" with video gravity modes
                videoGravity = .Resize
            }
        }
        graphicsLayer()!.setVideoGravity(videoGravity)
    }

    fileprivate func updateContentsScalingFilters() {
        if !renderer().isRenderHTMLCanvas() || WebCore.canvasCompositingStrategy(renderer()) != WebCore.CanvasAsLayerContents {
            return
        }
        var minificationFilter = WebCore.GraphicsLayer.ScalingFilter.Linear
        var magnificationFilter = WebCore.GraphicsLayer.ScalingFilter.Linear
        switch renderer()[.Style].imageRendering() {
        case .CrispEdges, .Pixelated:
            // FIXME: In order to match other code-paths, we treat these the same.
            minificationFilter = .Nearest
            magnificationFilter = .Nearest
        default:
            break
        }
        graphicsLayer()!.setContentsMinificationFilter(minificationFilter)
        graphicsLayer()!.setContentsMagnificationFilter(magnificationFilter)
    }
}

// MARK: - Geometry

private func negated(_ size: WebCore.LayoutSize) -> WebCore.LayoutSize {
    WebCore.LayoutSize() - size
}

private func negated(_ size: WebCore.FloatSize) -> WebCore.FloatSize {
    WebCore.FloatSize(-size.width(), -size.height())
}

private func floatSize(_ size: WebCore.LayoutSize) -> WebCore.FloatSize {
    WebCore.FloatSize(size.width().toFloat(), size.height().toFloat())
}

private func floatPoint(_ point: WebCore.LayoutPoint) -> WebCore.FloatPoint {
    WebCore.FloatPoint(point.x().toFloat(), point.y().toFloat())
}

private func isSameLayoutSize(_ a: WebCore.LayoutSize, _ b: WebCore.LayoutSize) -> Bool {
    a.width().rawValue() == b.width().rawValue() && a.height().rawValue() == b.height().rawValue()
}

private func isSameFloatSize(_ a: WebCore.FloatSize, _ b: WebCore.FloatSize) -> Bool {
    a.width() == b.width() && a.height() == b.height()
}

private func moved(_ point: WebCore.LayoutPoint, by size: WebCore.LayoutSize) -> WebCore.LayoutPoint {
    WebCore.toLayoutPoint(WebCore.toLayoutSize(point) + size)
}

private func moved(_ point: WebCore.LayoutPoint, back size: WebCore.LayoutSize) -> WebCore.LayoutPoint {
    WebCore.toLayoutPoint(WebCore.toLayoutSize(point) - size)
}

private func subpixelOffsetFromRendererChanged(
    _ oldSubpixelOffsetFromRenderer: WebCore.LayoutSize,
    _ newSubpixelOffsetFromRenderer: WebCore.LayoutSize,
    _ pixelSnappingScaleFactor: Float
) -> Bool {
    let previous = WebCore.snapSizeToDevicePixel(oldSubpixelOffsetFromRenderer, WebCore.LayoutPoint(), pixelSnappingScaleFactor)
    let current = WebCore.snapSizeToDevicePixel(newSubpixelOffsetFromRenderer, WebCore.LayoutPoint(), pixelSnappingScaleFactor)
    return !isSameFloatSize(previous, current)
}

private func subpixelForLayerPainting(_ point: WebCore.LayoutPoint, _ pixelSnappingFactor: Float) -> WebCore.FloatSize {
    var x = point.x()
    var y = point.y()
    x =
        x.rawValue() >= 0
        ? WebCore.LayoutUnit(Double(WebCore.floorToDevicePixel(x, pixelSnappingFactor)))
        : WebCore.LayoutUnit(Double(WebCore.ceilToDevicePixel(x, pixelSnappingFactor)))
    y =
        y.rawValue() >= 0
        ? WebCore.LayoutUnit(Double(WebCore.floorToDevicePixel(y, pixelSnappingFactor)))
        : WebCore.LayoutUnit(Double(WebCore.ceilToDevicePixel(y, pixelSnappingFactor)))
    return floatSize(WebCore.toLayoutSize(point) - WebCore.toLayoutSize(WebCore.LayoutPoint(x, y)))
}

private struct OffsetFromRenderer {
    // 1.2px - > { devicePixelOffset = 1px subpixelOffset = 0.2px }
    var devicePixelOffset: WebCore.LayoutSize
    var subpixelOffset: WebCore.LayoutSize
}

private func computeOffsetFromRenderer(_ offset: WebCore.LayoutSize, _ pixelSnappingScaleFactor: Float) -> OffsetFromRenderer {
    let subpixelOffset = WebCore.LayoutSize(subpixelForLayerPainting(WebCore.toLayoutPoint(offset), pixelSnappingScaleFactor))
    return OffsetFromRenderer(devicePixelOffset: offset - subpixelOffset, subpixelOffset: subpixelOffset)
}

private struct SnappedRectInfo {
    var snappedRect: WebCore.LayoutRect
    var snapDelta: WebCore.LayoutSize
}

private func snappedGraphicsLayer(
    _ offset: WebCore.LayoutSize,
    _ size: WebCore.LayoutSize,
    _ renderer: WebCore.RenderLayerModelObject
) -> SnappedRectInfo {
    let graphicsLayerRect = WebCore.LayoutRect(WebCore.toLayoutPoint(offset), size)
    let snappedRect = WebCore.LayoutRect(WebCore.snapRectToDevicePixelsIfNeeded(graphicsLayerRect, renderer))
    return SnappedRectInfo(snappedRect: snappedRect, snapDelta: WebCore.toLayoutSize(snappedRect.location()) - offset)
}

private func computeOffsetFromAncestorGraphicsLayer(
    _ compositedAncestor: WebCore.RenderLayer?,
    _ location: WebCore.LayoutPoint,
    _ pixelSnappingScaleFactor: Float
) -> WebCore.LayoutSize {
    guard let compositedAncestor else {
        return WebCore.toLayoutSize(location)
    }

    // FIXME: This is a workaround until after webkit.org/b/162634 gets fixed. ancestorSubpixelOffsetFromRenderer
    // could be stale when a dynamic composited state change triggers a pre-order updateGeometry() traversal.
    let ancestorBacking = compositedAncestor.backing()!
    let ancestorSubpixelOffsetFromRenderer = ancestorBacking.subpixelOffsetFromRenderer()
    let ancestorCompositedBounds = ancestorBacking.compositedBounds()
    let floored = WebCore.toLayoutSize(
        WebCore.LayoutPoint(
            WebCore.floorPointToDevicePixels(
                moved(ancestorCompositedBounds.location(), back: ancestorSubpixelOffsetFromRenderer),
                pixelSnappingScaleFactor
            )
        )
    )
    let ancestorRendererOffsetFromAncestorGraphicsLayer = negated(floored + ancestorSubpixelOffsetFromRenderer)
    return ancestorRendererOffsetFromAncestorGraphicsLayer + WebCore.toLayoutSize(location)
}

private struct ComputedOffsets {
    let renderLayer: WebCore.RenderLayer
    let compositingAncestor: WebCore.RenderLayer?
    // Location is relative to the renderer.
    let location: WebCore.LayoutPoint
    let parentGraphicsLayerOffset: WebCore.LayoutSize
    let primaryGraphicsLayerOffset: WebCore.LayoutSize
    let pixelSnappingScaleFactor: Float
    var cachedFromAncestorGraphicsLayer: WebCore.LayoutSize?
    var cachedFromParentGraphicsLayer: WebCore.LayoutSize?
    var cachedFromPrimaryGraphicsLayer: WebCore.LayoutSize?

    init(
        _ renderLayer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer?,
        _ localRect: WebCore.LayoutRect,
        _ parentGraphicsLayerRect: WebCore.LayoutRect,
        _ primaryGraphicsLayerRect: WebCore.LayoutRect
    ) {
        self.renderLayer = renderLayer
        self.compositingAncestor = compositingAncestor
        self.location = localRect.location()
        self.parentGraphicsLayerOffset = WebCore.toLayoutSize(parentGraphicsLayerRect.location())
        self.primaryGraphicsLayerOffset = WebCore.toLayoutSize(primaryGraphicsLayerRect.location())
        self.pixelSnappingScaleFactor = renderLayer.renderer().document().pixelSnappingScaleFactor()
    }

    mutating func fromParentGraphicsLayer() -> WebCore.LayoutSize {
        if let offset = cachedFromParentGraphicsLayer {
            return offset
        }
        let offset = fromAncestorGraphicsLayer() - parentGraphicsLayerOffset
        cachedFromParentGraphicsLayer = offset
        return offset
    }

    mutating func fromPrimaryGraphicsLayer() -> WebCore.LayoutSize {
        if let offset = cachedFromPrimaryGraphicsLayer {
            return offset
        }
        let offset = fromAncestorGraphicsLayer() - parentGraphicsLayerOffset - primaryGraphicsLayerOffset
        cachedFromPrimaryGraphicsLayer = offset
        return offset
    }

    private mutating func fromAncestorGraphicsLayer() -> WebCore.LayoutSize {
        if let offset = cachedFromAncestorGraphicsLayer {
            return offset
        }
        let localPointInAncestorRenderLayerCoords = renderLayer.convertToLayerCoords(
            compositingAncestor,
            location,
            WebCore.RenderLayer.AdjustForColumns
        )
        let offset = computeOffsetFromAncestorGraphicsLayer(
            compositingAncestor,
            localPointInAncestorRenderLayerCoords,
            pixelSnappingScaleFactor
        )
        cachedFromAncestorGraphicsLayer = offset
        return offset
    }
}

extension WebCore.RenderLayerBacking {
    fileprivate func computePrimaryGraphicsLayerRect(
        _ compositedAncestor: WebCore.RenderLayer?,
        _ parentGraphicsLayerRect: WebCore.LayoutRect
    ) -> WebCore.LayoutRect {
        var compositedBoundsOffset = ComputedOffsets(
            m_owningLayer,
            compositedAncestor,
            compositedBounds(),
            parentGraphicsLayerRect,
            WebCore.LayoutRect()
        )
        return WebCore.LayoutRect(
            WebCore.encloseRectToDevicePixels(
                WebCore.LayoutRect(WebCore.toLayoutPoint(compositedBoundsOffset.fromParentGraphicsLayer()), compositedBounds().size()),
                pixelSnappingScaleFactor()
            )
        )
    }

    // FIXME: See if we need this now that updateGeometry() is always called in post-order traversal.
    @cxx
    @implementation
    public func computeParentGraphicsLayerRect(_ compositedAncestor: WebCore.RenderLayer?) -> WebCore.LayoutRect {
        guard let compositedAncestor, let ancestorBacking = compositedAncestor.backing() else {
            return WebCore.LayoutRect(renderer().view().documentRect())
        }

        var parentGraphicsLayerRect = WebCore.LayoutRect()
        if m_owningLayer.isInsideFragmentedFlow() {
            // FIXME: flows/columns need work.
            var ancestorCompositedBounds = ancestorBacking.compositedBounds()
            ancestorCompositedBounds.setLocation(WebCore.LayoutPoint())
            parentGraphicsLayerRect = ancestorCompositedBounds
        }

        guard let ancestorRenderBox = compositedAncestor.renderer().asRenderBox() else {
            return parentGraphicsLayerRect
        }

        if ancestorBacking.hasClippingLayer() {
            // If the compositing ancestor has a layer to clip children, we parent in that, and therefore position relative to it.
            let clippingBox = ancestorBacking.clippingLayerBoxForSwift()
            let clippingBoxOffset = computeOffsetFromAncestorGraphicsLayer(
                compositedAncestor,
                clippingBox.location(),
                pixelSnappingScaleFactor()
            )
            parentGraphicsLayerRect = snappedGraphicsLayer(clippingBoxOffset, clippingBox.size(), renderer()).snappedRect
        }

        if compositedAncestor.hasCompositedScrollableOverflow() {
            let scrollableArea = compositedAncestor.scrollableArea()!

            let ancestorCompositedBounds = ancestorBacking.compositedBounds()
            let scrollContainerBox = ancestorRenderBox.paddingBoxRect()
            let scrollOffset = scrollableArea.scrollOffsetForSwift()
            var scrolledContentsLocation =
                WebCore.toLayoutSize(scrollContainerBox.location()) - WebCore.toLayoutSize(ancestorCompositedBounds.location())
            if !ancestorBacking.hasClippingLayer() {
                // Match the pixel-snapped position of the ancestor's scroll container layer (see updateGeometry()).
                let scrollContainerOffset = computeOffsetFromAncestorGraphicsLayer(
                    compositedAncestor,
                    scrollContainerBox.location(),
                    pixelSnappingScaleFactor()
                )
                scrolledContentsLocation = WebCore.toLayoutSize(
                    snappedGraphicsLayer(scrollContainerOffset, scrollContainerBox.size(), renderer()).snappedRect.location()
                )
            }
            let location = scrolledContentsLocation - WebCore.toLayoutSize(WebCore.LayoutPoint(scrollOffset))
            parentGraphicsLayerRect = WebCore.LayoutRect(WebCore.toLayoutPoint(location), scrollContainerBox.size())
        }

        return parentGraphicsLayerRect
    }

    @cxx
    @implementation
    public func updateClippingStackLayerGeometry(
        _ stack: WebCore.RenderLayerBacking.ClippingStackName,
        _ compositedAncestor: WebCore.RenderLayer?,
        _ parentGraphicsLayerRect: WebCore.LayoutRect
    ) -> WebCore.LayoutRect {
        // All clipRects in the stack are computed relative to m_owningLayer, so convert them back to compositedAncestor.
        let offsetFromCompositedAncestor = WebCore.toLayoutSize(
            m_owningLayer.convertToLayerCoords(compositedAncestor, WebCore.LayoutPoint(), WebCore.RenderLayer.AdjustForColumns)
        )
        var lastClipLayerRect = parentGraphicsLayerRect

        let pixelSnappingScaleFactor = self.pixelSnappingScaleFactor()
        for index in 0..<clippingStackSize(stack) {
            let clipRect = clippingStackEntryClipRect(stack, index)
            let clippingOffset = computeOffsetFromAncestorGraphicsLayer(
                compositedAncestor,
                moved(clipRect.location(), by: offsetFromCompositedAncestor),
                pixelSnappingScaleFactor
            )
            let snappedClippingLayerRect = snappedGraphicsLayer(clippingOffset, clipRect.size(), renderer()).snappedRect

            let clippingLayer = clippingStackEntryLayer(stack, index, .Clipping)!
            let clippingLayerPosition =
                WebCore.toLayoutSize(snappedClippingLayerRect.location()) - WebCore.toLayoutSize(lastClipLayerRect.location())
            clippingLayer.setPosition(floatPoint(WebCore.toLayoutPoint(clippingLayerPosition)))
            clippingLayer.setSize(floatSize(snappedClippingLayerRect.size()))

            updateClippingStackEntryContentsClipping(stack, index, floatSize(snappedClippingLayerRect.size()))

            lastClipLayerRect = snappedClippingLayerRect

            if clippingStackEntryIsOverflowScroll(stack, index) {
                var scrollOffset = WebCore.ScrollOffset()
                if let scrollableArea = clippingStackEntryClippingLayer(stack, index)?.scrollableArea() {
                    scrollOffset = scrollableArea.scrollOffsetForSwift()
                }

                // scrollingLayer size and position are always 0,0.
                clippingStackEntryLayer(stack, index, .Scrolling)!.setBoundsOrigin(WebCore.FloatPoint(scrollOffset))
                // Wraps at INT_MIN, as int negation does in practice.
                lastClipLayerRect.moveBy(WebCore.LayoutPoint(WebCore.IntPoint(0 &- scrollOffset.x(), 0 &- scrollOffset.y())))
            }
        }

        return lastClipLayerRect
    }

    @cxx
    @implementation
    public func updateAnimationExtent() {
        var animationExtent = WebCore.RenderLayer.OptionalFloatRect()
        if rendererIsRunningOrAboutToRunAcceleratedTransformRelatedAnimation() {
            var animatedBounds = WebCore.LayoutRect()
            if m_owningLayer.getOverlapBoundsIncludingChildrenAccountingForTransformAnimations(
                &animatedBounds,
                WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeCompositedDescendants)
            ) {
                animationExtent = WebCore.RenderLayer.OptionalFloatRect(floatRect(animatedBounds))
            }
        }
        graphicsLayer()!.setAnimationExtent(animationExtent)
    }

    fileprivate func updateScrollOffset(_ scrollOffset: WebCore.ScrollOffset) {
        let scrollableArea = m_owningLayer.scrollableArea()!

        if scrollableArea.currentScrollTypeForSwift() == .User {
            // If scrolling is happening externally, we don't want to touch the layer bounds origin here because that will cause jitter.
            scrollContainerLayer()!.syncBoundsOrigin(WebCore.FloatPoint(scrollOffset))
            scrollableArea.setRequiresScrollPositionReconciliation(true)
        } else {
            // Note that we implement the contents offset via the bounds origin on this layer, rather than a position on the sublayer.
            scrollContainerLayer()!.setBoundsOrigin(WebCore.FloatPoint(scrollOffset))
            scrollableArea.setRequiresScrollPositionReconciliation(false)
        }

        assert(scrolledContentsLayer()!.positionForSwift().isZero())
    }

    @cxx
    @implementation
    public func updateGeometry(_ compositedAncestor: WebCore.RenderLayer?) {
        assert(!m_owningLayer.normalFlowListDirty())
        assert(!m_owningLayer.zOrderListsDirty())
        assert(!renderer().view().needsLayout())

        let pixelSnappingScaleFactor = self.pixelSnappingScaleFactor()

        updateTransform(renderer()[.Style])
        updateOpacity()
        updateFilters(renderer()[.Style])
        updateBackdropFilters(renderer()[.Style])
        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        updateAppleVisualEffect(renderer()[.Style])
        #endif
        _ = updateBackdropRoot()
        updateScreenCaptureProtection()
        updateIsHostedInSpatialPortalSceneForSwift()
        updateBlendMode()
        updateContentsScalingFilters()

        if WebCore.RenderLayerBacking.videoEnabledForSwift() {
            updateVideoGravity()
        }

        assert(isSameRenderLayer(compositedAncestor, m_owningLayer.ancestorCompositingLayer()))
        var parentGraphicsLayerRect = computeParentGraphicsLayerRect(compositedAncestor)

        // If our content is being used in a view-transition, then all positioning is handled using a synthesized 'transform' property on
        // the wrapping
        // ::view-transition-new element. Set the parent graphics layer rect to that of the pseudo, adjusted into coordinates of the parent
        // layer.
        if let captureOverflowRect = viewTransitionCaptureOverflowRect().value {
            var computedOffsets = ComputedOffsets(
                m_owningLayer,
                compositedAncestor,
                captureOverflowRect,
                WebCore.LayoutRect(),
                WebCore.LayoutRect()
            )
            parentGraphicsLayerRect = WebCore.LayoutRect(
                WebCore.snapRectToDevicePixelsIfNeeded(
                    WebCore.LayoutRect(WebCore.toLayoutPoint(computedOffsets.fromParentGraphicsLayer()), captureOverflowRect.size()),
                    renderer()
                )
            )
        }

        if hasClippingStack(.Ancestor) {
            parentGraphicsLayerRect = updateClippingStackLayerGeometry(.Ancestor, compositedAncestor, parentGraphicsLayerRect)
        }

        let primaryGraphicsLayerRect = computePrimaryGraphicsLayerRect(compositedAncestor, parentGraphicsLayerRect)

        var compositedBoundsOffset = ComputedOffsets(
            m_owningLayer,
            compositedAncestor,
            compositedBounds(),
            parentGraphicsLayerRect,
            primaryGraphicsLayerRect
        )
        var rendererOffset = ComputedOffsets(
            m_owningLayer,
            compositedAncestor,
            WebCore.LayoutRect(),
            parentGraphicsLayerRect,
            primaryGraphicsLayerRect
        )

        m_compositedBoundsOffsetFromGraphicsLayer = compositedBoundsOffset.fromPrimaryGraphicsLayer()

        var primaryLayerPosition = primaryGraphicsLayerRect.location()

        // FIXME: reflections should force transform-style to be flat in the style: https://bugs.webkit.org/show_bug.cgi?id=106959
        let preserves3D = renderer()[.Style].usedTransformStyle3D() == .Preserve3D && !renderer().hasReflection()

        if let viewportAnchorLayer = viewportAnchorLayer() {
            if let viewportClippingLayer = graphicsLayerForSwift(.ViewportClipping) {
                assert(isSameRenderLayer(compositedAncestor, renderer().view().layer()))
                var fixedPositionRect = renderer().view().frameView().rectForFixedPositionLayout()
                for index in 0..<clippingStackSize(.Ancestor) {
                    if let clippingLayer = clippingStackEntryLayer(.Ancestor, index, .Clipping) {
                        fixedPositionRect.move(negated(WebCore.toLayoutSize(WebCore.LayoutPoint(clippingLayer.positionForSwift()))))
                    }
                }

                // RenderView's layer has a non-zero offsetFromGraphicsLayer in RTL content; we have to account
                // for that to map rectForFixedPositionLayout from content to GraphicsLayer coordinates.
                let renderViewLayer = renderer().view().layer()!
                assert(renderViewLayer.isComposited())
                fixedPositionRect.move(renderViewLayer.backing()!.contentOffsetInCompositingLayer())

                viewportClippingLayer.setPosition(floatPoint(fixedPositionRect.location()))
                viewportClippingLayer.setSize(floatSize(fixedPositionRect.size()))
                primaryLayerPosition = moved(primaryLayerPosition, by: negated(WebCore.toLayoutSize(fixedPositionRect.location())))
            }
            viewportAnchorLayer.setPosition(floatPoint(primaryLayerPosition))
            primaryLayerPosition = WebCore.LayoutPoint()
        }

        setNeedsFixedContainerEdgesUpdateIfNeeded()

        if let systemPreviewWrapperLayer = systemPreviewWrapperLayerForSwift() {
            systemPreviewWrapperLayer.setPreserves3D(preserves3D)
            systemPreviewWrapperLayer.setPosition(floatPoint(primaryLayerPosition))
            primaryLayerPosition = WebCore.LayoutPoint()
            systemPreviewWrapperLayer.setSize(floatSize(primaryGraphicsLayerRect.size()))
        }

        if let contentsContainmentLayer = contentsContainmentLayer() {
            contentsContainmentLayer.setPreserves3D(preserves3D)
            contentsContainmentLayer.setPosition(floatPoint(primaryLayerPosition))
            primaryLayerPosition = WebCore.LayoutPoint()
            // Use the same size as m_graphicsLayer so transforms behave correctly.
            contentsContainmentLayer.setSize(floatSize(primaryGraphicsLayerRect.size()))
        }

        let graphicsLayer = self.graphicsLayer()!
        updateAnimationExtent()
        graphicsLayer.setPreserves3D(preserves3D)
        graphicsLayer.setBackfaceVisibility(renderer()[.Style].backfaceVisibility() == .Visible)

        graphicsLayer.setPosition(floatPoint(primaryLayerPosition))
        graphicsLayer.setSize(floatSize(primaryGraphicsLayerRect.size()))
        if hasTiledBackingFlatteningLayer() {
            childContainmentLayer()!.setSize(floatSize(primaryGraphicsLayerRect.size()))
        }

        // Compute renderer offset from primary graphics layer. Note that primaryGraphicsLayerRect is in parentGraphicsLayer's coordinate
        // system which is not necessarily
        // the same as the ancestor graphics layer.
        let oldSubpixelOffsetFromRenderer = m_subpixelOffsetFromRenderer
        let primaryGraphicsLayerOffsetFromRenderer = computeOffsetFromRenderer(
            negated(rendererOffset.fromPrimaryGraphicsLayer()),
            pixelSnappingScaleFactor
        )
        m_subpixelOffsetFromRenderer = primaryGraphicsLayerOffsetFromRenderer.subpixelOffset
        m_hasSubpixelRounding =
            !m_subpixelOffsetFromRenderer.isZero() || !isSameLayoutSize(compositedBounds().size(), primaryGraphicsLayerRect.size())

        if !isSameFloatSize(floatSize(primaryGraphicsLayerOffsetFromRenderer.devicePixelOffset), graphicsLayer.offsetFromRenderer()) {
            graphicsLayer.setOffsetFromRenderer(floatSize(primaryGraphicsLayerOffsetFromRenderer.devicePixelOffset), .Set)
        }

        // If we have a layer that clips children, position it.
        var clippingBox = WebCore.LayoutRect()
        if let clipLayer = clippingLayer() {
            // clipLayer is the m_childContainmentLayer.
            clippingBox = clippingLayerBoxForSwift()
            // Clipping layer is parented in the primary graphics layer.
            let clipBoxOffsetFromGraphicsLayer = WebCore.toLayoutSize(clippingBox.location()) + rendererOffset.fromPrimaryGraphicsLayer()
            let snappedClippingGraphicsLayer = snappedGraphicsLayer(clipBoxOffsetFromGraphicsLayer, clippingBox.size(), renderer())
            clipLayer.setPosition(floatPoint(snappedClippingGraphicsLayer.snappedRect.location()))
            clipLayer.setSize(floatSize(snappedClippingGraphicsLayer.snappedRect.size()))
            clipLayer.setOffsetFromRenderer(
                floatSize(WebCore.toLayoutSize(moved(clippingBox.location(), back: snappedClippingGraphicsLayer.snapDelta))),
                .Set
            )

            if renderer().hasClipPath() || renderer()[.Style].hasBorderRadius() {
                clipLayer.setContentsClippingRect(innerBorderShapeContentsClippingRect(clipLayer.offsetFromRenderer()))
            } else {
                clipLayer.setContentsClippingRect(
                    WebCore.FloatRoundedRect(
                        WebCore.FloatRect(WebCore.FloatPoint(), floatSize(snappedClippingGraphicsLayer.snappedRect.size())),
                        WebCore.CornerRadii()
                    )
                )
            }

            setClippingLayerContentsClipShapePath(clipLayer)
        }

        if maskLayer() != nil {
            updateMaskingLayerGeometry()
        }

        updateChildrenTransformAndAnchorPoint(primaryGraphicsLayerRect, rendererOffset.fromParentGraphicsLayer())

        if let reflectionLayer = m_owningLayer.reflectionLayer(), reflectionLayer.isComposited() {
            let reflectionBacking = reflectionLayer.backing()!
            reflectionBacking.updateGeometry(m_owningLayer)

            // The reflection layer has the bounds of m_owningLayer.reflectionLayer(),
            // but the reflected layer is the bounds of this layer, so we need to position it appropriately.
            let layerBounds = floatRect(compositedBounds())
            let reflectionLayerBounds = floatRect(reflectionBacking.compositedBounds())
            reflectionBacking.graphicsLayer()!
                .setReplicatedLayerPosition(
                    WebCore.FloatPoint(layerBounds.x() - reflectionLayerBounds.x(), layerBounds.y() - reflectionLayerBounds.y())
                )
        }

        if let scrollContainerLayer = scrollContainerLayer() {
            let scrolledContentsLayer = scrolledContentsLayer()!
            let scrollContainerBox = renderer().asRenderBox()!.paddingBoxRect()
            let parentLayerBounds = clippingLayer() != nil ? scrollContainerBox : compositedBounds()

            let unsnappedScrollContainerPosition =
                WebCore.toLayoutSize(scrollContainerBox.location()) - WebCore.toLayoutSize(parentLayerBounds.location())
            var scrollContainerSnapOffset = WebCore.LayoutSize()
            if clippingLayer() == nil {
                // Snap the same way the clipping layers of descendants are snapped (see updateClippingStackLayerGeometry()),
                // so that content clipped by this layer and content clipped by those layers agree on the first device pixel row.
                // The scrolled contents must not move along with the clip, so the offset from the renderer absorbs the snap.
                let scrollContainerOffsetFromGraphicsLayer =
                    WebCore.toLayoutSize(scrollContainerBox.location()) + rendererOffset.fromPrimaryGraphicsLayer()
                let snappedScrollContainerPosition = snappedGraphicsLayer(
                    scrollContainerOffsetFromGraphicsLayer,
                    scrollContainerBox.size(),
                    renderer()
                )
                .snappedRect.location()
                scrollContainerSnapOffset = WebCore.toLayoutSize(snappedScrollContainerPosition) - unsnappedScrollContainerPosition
            }
            let scrollContainerPosition = unsnappedScrollContainerPosition + scrollContainerSnapOffset
            scrollContainerLayer.setPosition(
                WebCore.FloatPoint(scrollContainerPosition.width().toFloat(), scrollContainerPosition.height().toFloat())
            )
            scrollContainerLayer.setSize(
                WebCore.FloatSize(WebCore.roundedIntSize(WebCore.LayoutSize(scrollContainerBox.width(), scrollContainerBox.height())))
            )

            let scrollableArea = m_owningLayer.scrollableArea()!

            let scrollOffset = scrollableArea.scrollOffsetForSwift()
            updateScrollOffset(scrollOffset)

            let oldScrollingLayerOffset = scrollContainerLayer.offsetFromRenderer()
            scrollContainerLayer.setOffsetFromRenderer(
                floatSize(WebCore.toLayoutSize(scrollContainerBox.location()) + scrollContainerSnapOffset),
                .Set
            )

            let paddingBoxOffsetChanged = !isSameFloatSize(oldScrollingLayerOffset, scrollContainerLayer.offsetFromRenderer())

            let scrollSize = WebCore.FloatSize(WebCore.IntSize(scrollableArea.scrollWidth(), scrollableArea.scrollHeight()))
            if !isSameFloatSize(scrollSize, scrolledContentsLayer.sizeForSwift()) || paddingBoxOffsetChanged {
                scrolledContentsLayer.setNeedsDisplay()
            }

            scrolledContentsLayer.setSize(scrollSize)
            scrolledContentsLayer.setScrollOffset(scrollOffset, .DoNotSet)
            scrolledContentsLayer.setOffsetFromRenderer(
                floatSize(WebCore.toLayoutSize(scrollContainerBox.location()) + scrollContainerSnapOffset),
                .DoNotSet
            )

            adjustTiledBackingCoverage()
        }

        if let overflowControlsContainer = overflowControlsContainer() {
            let overflowControlsBox = renderer().asRenderBox()!.paddingBoxRectIncludingScrollbar()
            let boxOffsetFromGraphicsLayer =
                WebCore.toLayoutSize(overflowControlsBox.location()) + rendererOffset.fromPrimaryGraphicsLayer()
            let snappedBoxInfo = snappedGraphicsLayer(boxOffsetFromGraphicsLayer, overflowControlsBox.size(), renderer())

            overflowControlsContainer.setPosition(floatPoint(snappedBoxInfo.snappedRect.location()))
            overflowControlsContainer.setSize(floatSize(snappedBoxInfo.snappedRect.size()))
            overflowControlsContainer.setMasksToBounds(true)
        }

        // Computes the base size and offset shared by the foreground layer and the SVG segment overlay
        // layers. All of them start from the primary graphics layer's geometry. A segment paints only part
        // of the content, but which part is decided by its range in the flat item list, not by geometry, so
        // every overlay starts at this full size and gets cropped down to its slice.
        // FIXME: an overlay crops only the far (bottom-right) edge of its backing, never the near
        // (top-left) edge, so it keeps the primary layer's origin and stays larger than its slice.
        // Cropping the near edge too would move that origin and shift the paint coordinate system. Making
        // that work reliably needs a follow-up investigation.
        func foregroundLikeGeometry() -> (
            size: WebCore.FloatSize, offset: WebCore.FloatSize, needsDisplay: WebCore.GraphicsLayer.ShouldSetNeedsDisplay
        ) {
            if let scrolledContentsLayer = scrolledContentsLayer() {
                let offsetFromRenderer = scrolledContentsLayer.offsetFromRenderer()
                let scrollOffset = floatSize(WebCore.toLayoutSize(WebCore.LayoutPoint(scrolledContentsLayer.scrollOffset())))
                return (
                    scrolledContentsLayer.sizeForSwift(),
                    WebCore.FloatSize(
                        offsetFromRenderer.width() - scrollOffset.width(),
                        offsetFromRenderer.height() - scrollOffset.height()
                    ), .DoNotSet
                )
            }
            if hasClippingLayer() {
                // If we have a clipping layer (which clips descendants), then the foreground layer is a child of it,
                // so that it gets correctly sorted with children. In that case, position relative to the clipping layer.
                return (floatSize(clippingBox.size()), floatSize(WebCore.toLayoutSize(clippingBox.location())), .Set)
            }
            return (floatSize(primaryGraphicsLayerRect.size()), graphicsLayer.offsetFromRenderer(), .Set)
        }

        if let foregroundLayer = foregroundLayer() {
            let geometry = foregroundLikeGeometry()
            foregroundLayer.setPosition(WebCore.FloatPoint())
            foregroundLayer.setSize(geometry.size)
            foregroundLayer.setOffsetFromRenderer(geometry.offset, geometry.needsDisplay)
        }

        if hasSVGPaintOrderSegments() {
            let geometry = foregroundLikeGeometry()
            updateSVGSegmentLayerGeometry(geometry.size, geometry.offset, geometry.needsDisplay)
        }

        updateSystemPreviewBadgeLayerGeometryForSwift()

        if let backgroundLayer = backgroundLayer() {
            var backgroundPosition: WebCore.FloatPoint
            var backgroundSize: WebCore.FloatSize
            if backgroundLayerPaintsFixedRootBackground() {
                let frameView = renderer().view().frameView()
                backgroundPosition = floatPoint(frameView.scrollPositionForFixedPosition())
                backgroundSize = WebCore.FloatSize(frameView.layoutSize())
            } else {
                let boundingBox = renderer().objectBoundingBox()
                backgroundPosition = boundingBox.location()
                backgroundSize = boundingBox.size()
            }
            backgroundLayer.setPosition(backgroundPosition)
            backgroundLayer.setSize(backgroundSize)
            backgroundLayer.setOffsetFromRenderer(graphicsLayer.offsetFromRenderer(), .Set)
        }

        // If this layer was created just for clipping or to apply perspective, it doesn't need its own backing store.
        let ancestorCompositedBounds = compositedAncestor.map { $0.backing()!.compositedBounds() } ?? WebCore.LayoutRect()
        setRequiresOwnBackingStore(
            compositor()
                .requiresOwnBackingStore(
                    m_owningLayer,
                    compositedAncestor,
                    WebCore.LayoutRect(WebCore.toLayoutPoint(compositedBoundsOffset.fromParentGraphicsLayer()), compositedBounds().size()),
                    ancestorCompositedBounds
                )
        )
        updateBackdropFiltersGeometry()
        updateAfterWidgetResize()

        positionOverflowControlsLayers()

        if subpixelOffsetFromRendererChanged(oldSubpixelOffsetFromRenderer, m_subpixelOffsetFromRenderer, pixelSnappingScaleFactor)
            && canIssueSetNeedsDisplay()
        {
            setContentsNeedDisplay(.Clip)
        }

        rendererSizeMayHaveChanged()
    }

    @cxx
    @implementation
    public func adjustOverflowControlsPositionRelativeToAncestor(_ borrowedAncestorLayer: borrowing WebCore.RenderLayer) {
        let ancestorLayer = copy borrowedAncestorLayer
        assert(overflowControlsContainer() != nil)
        assert(ancestorLayer.isComposited())
        if ancestorLayer.backing() == nil {
            return
        }

        var parentGraphicsLayerRect = computeParentGraphicsLayerRect(ancestorLayer)
        let primaryGraphicsLayerRect = computePrimaryGraphicsLayerRect(ancestorLayer, parentGraphicsLayerRect)

        let overflowControlsRect = renderer().asRenderBox()!.paddingBoxRectIncludingScrollbar()

        if hasClippingStack(.OverflowControlsHost) {
            parentGraphicsLayerRect = updateClippingStackLayerGeometry(.OverflowControlsHost, ancestorLayer, parentGraphicsLayerRect)
        }

        var rendererOffset = ComputedOffsets(
            m_owningLayer,
            ancestorLayer,
            WebCore.LayoutRect(),
            parentGraphicsLayerRect,
            primaryGraphicsLayerRect
        )

        let boxOffsetFromGraphicsLayer = WebCore.toLayoutSize(overflowControlsRect.location()) + rendererOffset.fromParentGraphicsLayer()
        let snappedBoxInfo = snappedGraphicsLayer(boxOffsetFromGraphicsLayer, overflowControlsRect.size(), renderer())

        let overflowControlsContainer = overflowControlsContainer()!
        overflowControlsContainer.setPosition(floatPoint(snappedBoxInfo.snappedRect.location()))
        overflowControlsContainer.setSize(floatSize(snappedBoxInfo.snappedRect.size()))
    }

    @cxx
    @implementation
    public func compositedBoundsIncludingMargin() -> WebCore.LayoutRect {
        guard let tiledBacking = tiledBacking(), tiledBacking.hasMargins() else {
            return compositedBounds()
        }

        var boundsIncludingMargin = compositedBounds()
        let leftMarginWidth = WebCore.LayoutUnit(tiledBacking.leftMarginWidth())
        let topMarginHeight = WebCore.LayoutUnit(tiledBacking.topMarginHeight())

        boundsIncludingMargin.move(negated(WebCore.LayoutSize(leftMarginWidth, topMarginHeight)))
        boundsIncludingMargin.expand(
            WebCore.LayoutSize(leftMarginWidth, topMarginHeight)
                + WebCore.LayoutSize(
                    WebCore.LayoutUnit(tiledBacking.rightMarginWidth()),
                    WebCore.LayoutUnit(tiledBacking.bottomMarginHeight())
                )
        )

        return boundsIncludingMargin
    }
}

// MARK: - Display

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func setContentsNeedDisplay(_ shouldClip: WebCore.GraphicsLayerShouldClipToLayer) {
        assert(!paintsIntoCompositedAncestor())

        // Use the repaint as a trigger to re-evaluate direct compositing (which is never used on the root layer).
        if !m_owningLayer.isRenderViewLayer() {
            m_owningLayer.setNeedsCompositingConfigurationUpdate()
        }

        _ = m_owningLayer.invalidateEventRegion(.Paint)

        setNeedsTextBackdropUpdateForCustomColorMode()

        let frameView = renderer().view().frameView()
        if m_isMainFrameRenderViewLayer && frameView.isTrackingRepaints() {
            frameView.addTrackedRepaintRect(m_owningLayer.absoluteBoundingBoxForPainting())
        }

        if let graphicsLayer = graphicsLayer(), graphicsLayer.drawsContent() {
            // By default, setNeedsDisplay will clip to the size of the GraphicsLayer, which does not include margin tiles.
            // So if the TiledBacking has a margin that needs to be invalidated, we need to send in a rect to setNeedsDisplayInRect
            // that is large enough to include the margin. TiledBacking::bounds() includes the margin.
            let rectToRepaint: WebCore.FloatRect
            if let tiledBacking = tiledBacking() {
                rectToRepaint = WebCore.FloatRect(tiledBacking.bounds())
            } else {
                rectToRepaint = WebCore.FloatRect(WebCore.FloatPoint(), graphicsLayer.sizeForSwift())
            }
            graphicsLayer.setNeedsDisplayInRect(rectToRepaint, shouldClip)
        }

        if let foregroundLayer = foregroundLayer(), foregroundLayer.drawsContent() {
            foregroundLayer.setNeedsDisplay()
        }

        for index in 0..<svgSegmentCountForSwift() {
            if let segmentLayer = svgSegmentLayerForSwift(index), segmentLayer.drawsContent() {
                segmentLayer.setNeedsDisplay()
            }
        }

        if let backgroundLayer = backgroundLayer(), backgroundLayer.drawsContent() {
            backgroundLayer.setNeedsDisplay()
        }

        if let maskLayer = maskLayer(), maskLayer.drawsContent() {
            maskLayer.setNeedsDisplay()
        }

        if let scrolledContentsLayer = scrolledContentsLayer(), scrolledContentsLayer.drawsContent() {
            scrolledContentsLayer.setNeedsDisplay()
        }

        setNeedsFixedContainerEdgesUpdateIfNeeded()
    }

    // r is in the coordinate space of the layer's render object
    @cxx
    @implementation
    public func setContentsNeedDisplayInRect(_ r: WebCore.LayoutRect, _ shouldClip: WebCore.GraphicsLayerShouldClipToLayer) {
        assert(!paintsIntoCompositedAncestor())

        // Use the repaint as a trigger to re-evaluate direct compositing (which is never used on the root layer).
        if !m_owningLayer.isRenderViewLayer() {
            m_owningLayer.setNeedsCompositingConfigurationUpdate()
        }

        _ = m_owningLayer.invalidateEventRegion(.Paint)

        setNeedsTextBackdropUpdateForCustomColorMode()

        let pixelSnappedRectForPainting = WebCore.snapRectToDevicePixelsIfNeeded(r, renderer())
        let frameView = renderer().view().frameView()
        if m_isMainFrameRenderViewLayer && frameView.isTrackingRepaints() {
            frameView.addTrackedRepaintRect(pixelSnappedRectForPainting)
        }

        let subpixelOffset = floatSize(m_subpixelOffsetFromRenderer)
        func setLayerNeedsDisplay(_ layer: WebCore.GraphicsLayer, scrollOffset: WebCore.FloatSize? = nil) {
            var layerDirtyRect = pixelSnappedRectForPainting
            let offsetFromRenderer = layer.offsetFromRenderer()
            if let scrollOffset {
                layerDirtyRect.move(
                    WebCore.FloatSize(
                        -offsetFromRenderer.width() + scrollOffset.width() - subpixelOffset.width(),
                        -offsetFromRenderer.height() + scrollOffset.height() - subpixelOffset.height()
                    )
                )
            } else {
                layerDirtyRect.move(
                    WebCore.FloatSize(
                        -offsetFromRenderer.width() - subpixelOffset.width(),
                        -offsetFromRenderer.height() - subpixelOffset.height()
                    )
                )
            }
            layer.setNeedsDisplayInRect(layerDirtyRect, shouldClip)
        }

        if let graphicsLayer = graphicsLayer(), graphicsLayer.drawsContent() {
            setLayerNeedsDisplay(graphicsLayer)
        }

        if let foregroundLayer = foregroundLayer(), foregroundLayer.drawsContent() {
            setLayerNeedsDisplay(foregroundLayer)
        }

        setSVGSegmentLayersNeedDisplayInRect(pixelSnappedRectForPainting, shouldClip)

        // FIXME: need to split out repaints for the background.
        if let backgroundLayer = backgroundLayer(), backgroundLayer.drawsContent() {
            setLayerNeedsDisplay(backgroundLayer)
        }

        if let maskLayer = maskLayer(), maskLayer.drawsContent() {
            setLayerNeedsDisplay(maskLayer)
        }

        if let scrolledContentsLayer = scrolledContentsLayer(), scrolledContentsLayer.drawsContent() {
            var scrollOffset = WebCore.ScrollOffset()
            if let scrollableArea = m_owningLayer.scrollableArea() {
                scrollOffset = scrollableArea.scrollOffsetForSwift()
            }
            setLayerNeedsDisplay(scrolledContentsLayer, scrollOffset: floatSize(WebCore.toLayoutSize(WebCore.LayoutPoint(scrollOffset))))
        }

        setNeedsFixedContainerEdgesUpdateIfNeeded()
    }

    @cxx
    @implementation
    public func paintFlagsForLayer(_ borrowedGraphicsLayer: borrowing WebCore.GraphicsLayer) -> WebCore.RenderLayer.PaintLayerFlags {
        let graphicsLayer = copy borrowedGraphicsLayer
        var paintFlags = WebCore.RenderLayer.PaintLayerFlags()

        let paintingPhase = graphicsLayer.paintingPhase()
        if paintingPhase.contains(.Background) {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingCompositingBackgroundPhase))
        }
        if paintingPhase.contains(.Foreground) {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingCompositingForegroundPhase))
        }
        if paintingPhase.contains(.Mask) {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingCompositingMaskPhase))
        }
        if paintingPhase.contains(.ClipPath) {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingCompositingClipPathPhase))
        }
        if paintingPhase.contains(.ChildClippingMask) {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingChildClippingMaskPhase))
        }
        if paintingPhase.contains(.OverflowContents) {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingOverflowContents))
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingOverflowContentsRoot))
        }

        if paintingPhase.contains(.CompositedScroll) {
            if WebCore.RenderLayerBacking.isSameGraphicsLayer(graphicsLayer, self.graphicsLayer()) {
                paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingOverflowContainer))
            }
        }

        if WebCore.RenderLayerBacking.isSameGraphicsLayer(graphicsLayer, backgroundLayer()) && m_backgroundLayerPaintsFixedRootBackground {
            // Need PaintingCompositingForegroundPhase to walk child layers.
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingRootBackgroundOnly))
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingCompositingForegroundPhase))
        } else if compositor().fixedRootBackgroundLayer() != nil {
            paintFlags.add(WebCore.RenderLayer.PaintLayerFlags(.PaintingSkipRootBackground))
        }

        return paintFlags
    }

    @cxx
    @implementation
    public func updateDebugIndicators(_ showBorder: Bool, _ showRepaintCounter: Bool) {
        // The remote frame's process draws its own repaint counter at the same corner.
        let graphicsLayer = self.graphicsLayer()!
        graphicsLayer.setShowDebugBorder(showBorder)
        graphicsLayer.setShowRepaintCounter(showRepaintCounter && !rendererHostsRemoteFrame())

        // m_viewportAnchorLayer can't show layer borders because it's a structural layer.

        graphicsLayerForSwift(.ViewportClipping)?.setShowDebugBorder(showBorder)

        for index in 0..<clippingStackSize(.Ancestor) {
            clippingStackEntryLayer(.Ancestor, index, .Clipping)!.setShowDebugBorder(showBorder)
        }

        if let foregroundLayer = foregroundLayer() {
            foregroundLayer.setShowDebugBorder(showBorder)
            foregroundLayer.setShowRepaintCounter(showRepaintCounter)
        }

        for index in 0..<svgSegmentCountForSwift() {
            if let segmentLayer = svgSegmentLayerForSwift(index) {
                segmentLayer.setShowDebugBorder(showBorder)
                segmentLayer.setShowRepaintCounter(showRepaintCounter)
            }
        }

        contentsContainmentLayer()?.setShowDebugBorder(showBorder)

        if let childContainmentLayer = childContainmentLayer() {
            childContainmentLayer.setShowDebugBorder(showBorder)
            let showFrameProcessBorders = renderer().settings().showFrameProcessBorders() && m_owningLayer.isRenderViewLayer()
            // depth() is 1-based and counts through cross-process ancestor frames, so subtract 1 to keep the
            // mainframe's indicator unstaggered while nested frames offset further with each level of nesting. depth() is at
            // least 1, so this cannot wrap.
            let frameNestingDepth: UInt32 = showFrameProcessBorders ? frameTreeDepthForSwift() &- 1 : 0
            childContainmentLayer.setShowFrameProcessBorders(showFrameProcessBorders, frameNestingDepth, renderer().frame().frameID())
        }

        if let backgroundLayer = backgroundLayer() {
            backgroundLayer.setShowDebugBorder(showBorder)
            backgroundLayer.setShowRepaintCounter(showRepaintCounter)
        }

        if let maskLayer = maskLayer() {
            maskLayer.setShowDebugBorder(showBorder)
            maskLayer.setShowRepaintCounter(showRepaintCounter)
        }

        layerForHorizontalScrollbar()?.setShowDebugBorder(showBorder)
        layerForVerticalScrollbar()?.setShowDebugBorder(showBorder)
        layerForScrollCorner()?.setShowDebugBorder(showBorder)
        scrollContainerLayer()?.setShowDebugBorder(showBorder)

        if let scrolledContentsLayer = scrolledContentsLayer() {
            scrolledContentsLayer.setShowDebugBorder(showBorder)
            scrolledContentsLayer.setShowRepaintCounter(showRepaintCounter)
        }

        overflowControlsContainer()?.setShowDebugBorder(showBorder)
    }

    @cxx
    @implementation
    public func notifyFlushRequired(_ layer: WebCore.GraphicsLayer?) {
        if renderer().renderTreeBeingDestroyed() {
            return
        }

        compositor().notifyFlushRequired(layer)
    }

    @cxx
    @implementation
    public func notifySubsequentFlushRequired(_ layer: WebCore.GraphicsLayer?) {
        compositor().notifySubsequentFlushRequired(layer)
    }
}

// MARK: - SVG paint-order segments

extension WebCore.RenderLayerBacking {
    func svgSegmentLayerAfterCompositedChild(_ compositedChild: WebCore.RenderLayer) -> WebCore.GraphicsLayer? {
        for index in 0..<svgSegmentCountForSwift() {
            if let segmentLayer = svgSegmentLayerForSwift(index),
                isSameRenderLayer(svgSegmentPrecedingCompositedChildForSwift(index), compositedChild)
            {
                return segmentLayer
            }
        }
        return nil
    }

    fileprivate func updateSVGSegmentLayerGeometry(
        _ foregroundLikeSize: WebCore.FloatSize,
        _ foregroundLikeOffset: WebCore.FloatSize,
        _ needsDisplayOnOffsetChange: WebCore.GraphicsLayer.ShouldSetNeedsDisplay
    ) {
        // Crop the overlay to its segment's bounds only in the plain (non-scrolled, non-clipping)
        // non-transformed case: offsetFromRenderer and position shift by the segment's origin together,
        // landing the content at the backing's top-left while keeping its on-screen location fixed. A
        // transformed container keeps the full foreground-sized backing (no crop): shifting the origin
        // makes the overlay a positioned child of the transformed primary layer, which the compositor
        // misplaces because the layer's anchor point does not seem to be honoured under the transform.
        // That appears to be the underlying cause and needs a follow-up investigation, so for now the
        // origin is kept foreground-aligned to composite identically.
        let canCrop = scrolledContentsLayer() == nil && !hasClippingLayer() && !m_owningLayer.isTransformed()
        let contentOrigin = floatRect(compositedBounds()).location()

        for index in 0..<svgSegmentCountForSwift() {
            setSVGSegmentBoundsInLayerSpaceForSwift(index, WebCore.FloatRect())
            guard let segmentLayer = svgSegmentLayerForSwift(index) else {
                continue
            }

            var segmentSize = foregroundLikeSize
            var segmentOffset = foregroundLikeOffset
            var segmentPosition = WebCore.FloatPoint()

            if canCrop {
                let segmentBounds = computeSVGSegmentBoundsForSwift(index)
                if !segmentBounds.isEmpty() {
                    // The segment in foreground-local space, rounded out so the backing always covers its
                    // content and clamped to the foreground area.
                    var localBounds = WebCore.FloatRect(
                        WebCore.FloatPoint(segmentBounds.x() - contentOrigin.x(), segmentBounds.y() - contentOrigin.y()),
                        segmentBounds.size()
                    )
                    localBounds = WebCore.FloatRect(WebCore.enclosingIntRect(localBounds))
                    localBounds.intersect(WebCore.FloatRect(WebCore.FloatPoint(), foregroundLikeSize))
                    if !localBounds.isEmpty() {
                        setSVGSegmentBoundsInLayerSpaceForSwift(index, localBounds)
                        // Shift offsetFromRenderer by the segment's origin so the paint lands at the
                        // backing's top-left. The matching position keeps the on-screen location fixed.
                        segmentSize = localBounds.size()
                        segmentOffset = WebCore.FloatSize(
                            foregroundLikeOffset.width() + localBounds.x(),
                            foregroundLikeOffset.height() + localBounds.y()
                        )
                        segmentPosition = localBounds.location()
                    }
                }
            }

            segmentLayer.setPosition(segmentPosition)
            segmentLayer.setSize(segmentSize)
            segmentLayer.setOffsetFromRenderer(segmentOffset, needsDisplayOnOffsetChange)
        }
    }

    fileprivate func updateSVGSegmentLayersDrawsContent(_ hasPaintedContent: Bool) {
        // Gate each overlay here so it never allocates a backing store for content it does not paint.
        for index in 0..<svgSegmentCountForSwift() {
            if let segmentLayer = svgSegmentLayerForSwift(index) {
                segmentLayer.setDrawsContent(hasPaintedContent && svgSegmentHasInlineContentForSwift(index))
            }
        }
    }

    fileprivate func setSVGSegmentLayersNeedDisplayInRect(
        _ pixelSnappedRectForPainting: WebCore.FloatRect,
        _ shouldClip: WebCore.GraphicsLayerShouldClipToLayer
    ) {
        // Repaint only the overlays whose segment overlaps the dirty rect. The segment's bounds in layer space (set in
        // updateGeometry) hold the segment in foreground-local space, the same space the dirty rect lands in
        // once the foreground's offset is removed. Empty bounds mean we do not know them
        // (for example the overlay was not cropped), so just repaint it.
        let subpixelOffset = floatSize(m_subpixelOffsetFromRenderer)
        let primaryOffsetFromRenderer = graphicsLayer()!.offsetFromRenderer()
        var foregroundLocalDirtyRect = pixelSnappedRectForPainting
        foregroundLocalDirtyRect.move(
            WebCore.FloatSize(
                -primaryOffsetFromRenderer.width() - subpixelOffset.width(),
                -primaryOffsetFromRenderer.height() - subpixelOffset.height()
            )
        )
        for index in 0..<svgSegmentCountForSwift() {
            guard let segmentLayer = svgSegmentLayerForSwift(index), segmentLayer.drawsContent() else {
                continue
            }
            let segmentBoundsInLayerSpace = svgSegmentBoundsInLayerSpaceForSwift(index)
            if !segmentBoundsInLayerSpace.isEmpty() && !segmentBoundsInLayerSpace.intersects(foregroundLocalDirtyRect) {
                continue
            }
            var layerDirtyRect = pixelSnappedRectForPainting
            let offsetFromRenderer = segmentLayer.offsetFromRenderer()
            layerDirtyRect.move(
                WebCore.FloatSize(
                    -offsetFromRenderer.width() - subpixelOffset.width(),
                    -offsetFromRenderer.height() - subpixelOffset.height()
                )
            )
            segmentLayer.setNeedsDisplayInRect(layerDirtyRect, shouldClip)
        }
    }
}

// MARK: - Bounds, animated properties and testing

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func compositedBounds() -> WebCore.LayoutRect {
        m_compositedBounds
    }

    @cxx
    @implementation
    public func setCompositedBounds(_ bounds: WebCore.LayoutRect) -> Bool {
        if isSameLayoutRect(bounds, m_compositedBounds) {
            return false
        }

        m_compositedBounds = bounds
        return true
    }

    @cxx
    @implementation
    public func contentOffsetInCompositingLayer() -> WebCore.LayoutSize {
        negated(WebCore.LayoutSize(m_compositedBounds.x(), m_compositedBounds.y())) + m_compositedBoundsOffsetFromGraphicsLayer
    }

    @cxx
    @implementation
    public func compositingLayerType() -> WebCore.CompositingLayerType {
        let graphicsLayer = self.graphicsLayer()!
        if graphicsLayer.usesContentsLayer() {
            return WebCore.MediaCompositingLayer
        }

        if graphicsLayer.drawsContent() {
            return graphicsLayer.tiledBacking() != nil ? WebCore.TiledCompositingLayer : WebCore.NormalCompositingLayer
        }

        return WebCore.ContainerCompositingLayer
    }

    @cxx
    @implementation
    public func backingStoreMemoryEstimate() -> Double {
        // Layers in m_ancestorClippingStack, m_contentsContainmentLayer and m_childContainmentLayer are just used for masking or
        // containment, so have no backing.
        var backingMemory = graphicsLayer()!.backingStoreMemoryEstimate()
        if let foregroundLayer = foregroundLayer() {
            backingMemory += foregroundLayer.backingStoreMemoryEstimate()
        }
        for index in 0..<svgSegmentCountForSwift() {
            if let segmentLayer = svgSegmentLayerForSwift(index) {
                backingMemory += segmentLayer.backingStoreMemoryEstimate()
            }
        }
        if let backgroundLayer = backgroundLayer() {
            backingMemory += backgroundLayer.backingStoreMemoryEstimate()
        }
        if let maskLayer = maskLayer() {
            backingMemory += maskLayer.backingStoreMemoryEstimate()
        }

        if let scrolledContentsLayer = scrolledContentsLayer() {
            backingMemory += scrolledContentsLayer.backingStoreMemoryEstimate()
        }

        if let layer = layerForHorizontalScrollbar() {
            backingMemory += layer.backingStoreMemoryEstimate()
        }

        if let layer = layerForVerticalScrollbar() {
            backingMemory += layer.backingStoreMemoryEstimate()
        }

        if let layer = layerForScrollCorner() {
            backingMemory += layer.backingStoreMemoryEstimate()
        }

        return backingMemory
    }

    @cxx
    @implementation
    public func purgeFrontBufferForTesting() {
        graphicsLayer()?.purgeFrontBufferForTesting()
    }

    @cxx
    @implementation
    public func purgeBackBufferForTesting() {
        graphicsLayer()?.purgeBackBufferForTesting()
    }

    @cxx
    @implementation
    public func markFrontBufferVolatileForTesting() {
        graphicsLayer()?.markFrontBufferVolatileForTesting()
    }
}

private func isSameLayoutRect(_ a: WebCore.LayoutRect, _ b: WebCore.LayoutRect) -> Bool {
    a.x().rawValue() == b.x().rawValue() && a.y().rawValue() == b.y().rawValue() && a.width().rawValue() == b.width().rawValue()
        && a.height().rawValue() == b.height().rawValue()
}

// MARK: - Images and contents boxes

extension WebCore.RenderLayerBacking {
    // An image can be directly compositing if it's the sole content of the layer, and has no box decorations
    // that require painting. Direct compositing saves backing store.
    fileprivate func isDirectlyCompositedImage() -> Bool {
        // Cannot be painted, so it is composited whatever else the layer has.
        // FIXME: A clip, corner shape, or filter that has to be painted is not applied to it.
        if renderer().isRenderViewTransitionCapture() && viewTransitionCaptureHasDisplayOnlyImage() {
            return true
        }

        if isInPromotedSpatialPortalChildForSwift() {
            return false
        }

        if m_owningLayer.hasVisibleBoxDecorationsOrBackground() || m_owningLayer.shouldPaintWithFilters(.init()) || renderer().hasClip() {
            return false
        }

        if renderer()[.Style].borderHasNonRoundCornerShape() {
            return false
        }

        // Fixed layers that allow detaching won't have a backing store,
        // so using a directly composited image doesn't help (and has non-zero cost)
        if m_owningLayer.behavesAsFixed() && graphicsLayer()!.allowsBackingStoreDetaching() {
            return false
        }

        if renderer().isRenderViewTransitionCapture() {
            return viewTransitionCaptureImageIsDirectlyComposited()
        }

        guard let imageRenderer = renderer().asRenderImage() else {
            return false
        }

        if WebCore.RenderLayerBacking.videoEnabledForSwift() && renderer().isRenderMedia() {
            return false
        }

        // A directly composited image is never painted, so it could not be inverted.
        if WebCore.RenderLayerBacking.shouldForceInvertBitmapImageForSwift(imageRenderer) {
            return false
        }

        if let cachedImage = imageRenderer.cachedImage() {
            if !cachedImage.hasImage() {
                return false
            }

            guard let image = WebCore.RenderLayerBacking.asBitmapImage(cachedImage.image()) else {
                return false
            }

            if image.currentFrameOrientation().orientation() != .None {
                return false
            }

            return graphicsLayer()!.canDirectlyCompositeNativeImage()
        }

        return false
    }

    fileprivate func isUnscaledBitmapOnly() -> Bool {
        if !renderer().isRenderImage() && !renderer().isRenderHTMLCanvas() {
            return false
        }

        if isInPromotedSpatialPortalChildForSwift() {
            return false
        }

        if m_owningLayer.hasVisibleBoxDecorationsOrBackground() {
            return false
        }

        if compositor().pageScaleFactor() < 1.0 {
            return false
        }

        let contents = contentsBox()
        if contents.x().rawValue() != 0 || contents.y().rawValue() != 0 {
            return false
        }

        if let imageRenderer = renderer().asRenderImage() {
            if let cachedImage = imageRenderer.cachedImage() {
                if !cachedImage.hasImage() {
                    return false
                }

                guard let image = WebCore.RenderLayerBacking.asBitmapImage(cachedImage.image()) else {
                    return false
                }

                if image.currentFrameOrientation().orientation() != .None {
                    return false
                }

                let imageSize = image.size(WebCore.ImageOrientation(.FromImage))
                return contents.width().toFloat() == imageSize.width() && contents.height().toFloat() == imageSize.height()
            }
            return false
        }

        if renderer()[.Style].imageRendering() == .CrispEdges || renderer()[.Style].imageRendering() == .Pixelated {
            return false
        }

        let snappedSize = WebCore.snappedIntRect(contents).size()
        let canvasSize = canvasElementSize()
        return snappedSize.width() == canvasSize.width() && snappedSize.height() == canvasSize.height()
    }

    // Returns true if the layer has the image as its contents.
    fileprivate func updateImageContents() -> Bool {
        if renderer().isRenderViewTransitionCapture() {
            setViewTransitionCaptureImageAsContents()
        } else {
            let imageRenderer = renderer().asRenderImage()!

            guard let cachedImage = imageRenderer.cachedImage() else {
                return false
            }

            guard let image = cachedImage.image() else {
                return false
            }

            // We have to wait until the image is fully loaded before setting it on the layer.
            if !cachedImage.isLoaded() {
                return false
            }

            if let nativeImage = WebCore.RenderLayerBacking.nativeImageForDirectlyCompositedImage(image).get() {
                graphicsLayer()!.setContentsToNativeImage(nativeImage)
            }

            // Image animation is "lazy", in that it automatically stops unless someone is drawing
            // the image. So we have to kick the animation each time; this has the downside that the
            // image will keep animating, even if its layer is not visible.
            image.startAnimation()
        }

        return true
    }

    // The part of containsPaintedContent() that depends on the kind of renderer.
    fileprivate func rendererContainsPaintedContent(_ isDirectlyCompositedImage: Bool) -> Bool {
        if renderer().isRenderViewTransitionCapture() && viewTransitionCaptureHasDisplayOnlyImage() {
            return m_owningLayer.hasVisibleBoxDecorationsOrBackground()
        }

        if isDirectlyCompositedImage {
            return false
        }

        if !rendererMayHaveNonZeroOpacity() {
            return false
        }

        // FIXME: we could optimize cases where the image, video or canvas is known to fill the border box entirely,
        // and set background color on the layer in that case, instead of allocating backing store and painting.
        if WebCore.RenderLayerBacking.videoEnabledForSwift(), let renderVideo = rendererAsRenderVideo(), renderVideo.shouldDisplayVideo() {
            return m_owningLayer.hasVisibleBoxDecorationsOrBackground()
                || (!renderVideo.supportsAcceleratedRendering() && m_requiresOwnBackingStore)
        }

        if WebCore.RenderLayerBacking.webGLOrOffscreenCanvasEnabledForSwift() && renderer().isRenderHTMLCanvas()
            && WebCore.canvasCompositingStrategy(renderer()) == WebCore.CanvasAsLayerContents
        {
            if canvasHasDrawableContent() {
                return true
            }
            return m_owningLayer.hasVisibleBoxDecorationsOrBackground()
        }

        return true
    }

    fileprivate func rendererIsReplacedAndPaintsContent() -> Bool {
        guard let replaced = rendererAsRenderReplaced() else {
            return false
        }
        return replaced.paintsContent()
    }

    @cxx
    @implementation
    public func rendererBackgroundColor() -> WebCore.Color {
        var backgroundRenderer: WebCore.RenderElement? = nil
        if renderer().isDocumentElementRenderer() {
            backgroundRenderer = renderer().view().rendererForRootBackground()
        }

        return (backgroundRenderer ?? renderer())[.Style].visitedDependentUsedBackgroundColorApplyingColorFilter()
    }

    @cxx
    @implementation
    public func contentsBox() -> WebCore.LayoutRect {
        guard let renderBox = renderer().asRenderBox() else {
            return WebCore.LayoutRect()
        }

        var contentsRect: WebCore.LayoutRect
        if WebCore.RenderLayerBacking.videoEnabledForSwift(), let renderVideo = rendererAsRenderVideo() {
            contentsRect = WebCore.LayoutRect(renderVideo.videoBox())
        } else if rendererIsSpatialPortal() {
            // The portal StereoLayer should cover the whole padding box.
            contentsRect = renderBox.paddingBoxRect()
        } else if renderer().isRenderViewTransitionCapture() {
            contentsRect = viewTransitionCaptureLocalOverflowRect()
        } else if let renderReplaced = rendererAsRenderReplaced() {
            contentsRect = renderReplaced.replacedContentPaintRect()
        } else {
            contentsRect = renderBox.contentBoxRect()
        }

        contentsRect.move(contentOffsetInCompositingLayer())
        return contentsRect
    }

    @cxx
    @implementation
    public func inlineVideoContentsBox() -> WebCore.LayoutRect {
        if WebCore.RenderLayerBacking.videoEnabledForSwift(), let renderVideo = rendererAsRenderVideo() {
            var contentsRect = renderVideo.inlineVideoBox()
            contentsRect.move(contentOffsetInCompositingLayer())
            return contentsRect
        }
        return contentsBox()
    }
}

// MARK: - Mask layer geometry

extension WebCore.RenderLayerBacking {
    // FIXME: Avoid repaints when clip path changes.
    fileprivate func updateMaskingLayerGeometry() {
        let maskLayer = maskLayer()!
        maskLayer.setSize(graphicsLayer()!.sizeForSwift())
        maskLayer.setPosition(WebCore.FloatPoint())
        maskLayer.setOffsetFromRenderer(graphicsLayer()!.offsetFromRenderer(), .Set)

        if maskLayer.drawsContent() {
            return
        }

        if renderer().hasClipPath() {
            assert(!clipPathIsReferencePath())

            // FIXME: Use correct reference box for inlines: https://bugs.webkit.org/show_bug.cgi?id=129047,
            // https://github.com/w3c/csswg-drafts/issues/6383
            let boundingBox = m_owningLayer.boundingBox(m_owningLayer, WebCore.LayoutSize(), .init())
            let referenceBoxForClippedInline = WebCore.LayoutRect(WebCore.snapRectToDevicePixelsIfNeeded(boundingBox, renderer()))
            let offset = WebCore.LayoutSize(
                WebCore.snapSizeToDevicePixel(negated(m_subpixelOffsetFromRenderer), WebCore.LayoutPoint(), pixelSnappingScaleFactor())
            )
            var windRule = WebCore.WindRule.NonZero
            var clipPath = clipPathForMaskLayer(referenceBoxForClippedInline, offset, &windRule)

            let pathOffset = maskLayer.offsetFromRenderer()
            if !pathOffset.isZero() {
                clipPath.translate(negated(pathOffset))
            }

            maskLayer.setShapeLayerPath(clipPath)
            maskLayer.setShapeLayerWindRule(windRule)
        }
    }
}

// MARK: - Event regions

#if ENABLE_ASYNC_SCROLLING // ENABLE(ASYNC_SCROLLING)
extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func maintainsEventRegion() -> Bool {
        if m_owningLayer.page().scrollingCoordinator() == nil {
            return false
        }

        if paintsIntoCompositedAncestor() {
            return false
        }

        if renderer().view().needsEventRegionUpdateForNonCompositedFrame() {
            return true
        }

        if documentOrPageRequiresEventRegion() {
            return true
        }

        if m_owningLayer.isRenderViewLayer() {
            return false
        }

        let settings = renderer().settings()
        if !settings.asyncFrameScrollingEnabled() && !settings.asyncOverflowScrollingEnabled() {
            return false
        }

        if !m_owningLayer.page().scrollingCoordinator()!.hasSubscrollers(renderer().view().frame().rootFrame().frameID()) {
            return false
        }

        return true
    }

    @cxx
    @implementation
    public func setNeedsEventRegionUpdate(_ needsUpdate: Bool) {
        m_needsEventRegionUpdate = needsUpdate
    }
}
#endif

// MARK: - Animations

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func animationPaused(_ timeOffset: Double, _ animationName: WTF.String) {
        graphicsLayer()!.pauseAnimation(animationName, timeOffset)
    }

    @cxx
    @implementation
    public func animationFinished(_ animationName: WTF.String) {
        graphicsLayer()!.removeAnimation(animationName, nil)
        m_owningLayer.setNeedsPostLayoutCompositingUpdate()
        m_owningLayer.setNeedsCompositingGeometryUpdate()
        removeFilterAnimationOutsetsForSwift(animationName)
    }

    @cxx
    @implementation
    public func transformRelatedPropertyDidChange() {
        graphicsLayer()!.transformRelatedPropertyDidChange()
    }

    @cxx
    @implementation
    public func startAnimation(
        _ timeOffset: Double,
        _ animation: borrowing WebCore.GraphicsLayerAnimation,
        _ keyframes: WebCore.BlendingKeyframesView,
        _ filterAnimationOutsets: WebCore.IntOutsets
    ) -> Bool {
        if renderer().capturedInViewTransition() {
            return false
        }

        let shouldApplyAnimationsToTargetRenderer = renderer().isRenderBox() || renderer().isSVGLayerAwareRenderer()

        let hasOpacity = keyframes.containsProperty(.Opacity)
        let hasRotate = shouldApplyAnimationsToTargetRenderer && keyframes.containsProperty(.Rotate)
        let hasScale = shouldApplyAnimationsToTargetRenderer && keyframes.containsProperty(.Scale)
        let hasTranslate = shouldApplyAnimationsToTargetRenderer && keyframes.containsProperty(.Translate)
        let hasTransform = shouldApplyAnimationsToTargetRenderer && keyframes.containsProperty(.Transform)
        let hasFilter = keyframes.containsProperty(.Filter)
        let hasBackdropFilter = keyframes.containsProperty(.WebkitBackdropFilter) || keyframes.containsProperty(.BackdropFilter)

        if !hasOpacity && !hasRotate && !hasScale && !hasTranslate && !hasTransform && !hasFilter && !hasBackdropFilter {
            return false
        }

        var referenceBoxRect = renderer().transformReferenceBoxRect(renderer()[.Style])
        if !renderer().isSVGLayerAwareRenderer() {
            referenceBoxRect = WebCore.FloatRect(WebCore.snappedIntRect(WebCore.LayoutRect(referenceBoxRect)))
        }
        let referenceBoxSize = referenceBoxRect.size()

        var didAnimate = false
        func addAnimation(_ property: WebCore.AnimatedProperty) {
            if addAnimationForSwift(property, keyframes, referenceBoxSize, animation, timeOffset) {
                didAnimate = true
            }
        }

        if hasRotate {
            addAnimation(.Rotate)
        }
        if hasScale {
            addAnimation(.Scale)
        }
        if hasTranslate {
            addAnimation(.Translate)
        }
        if hasTransform {
            addAnimation(.Transform)
        }
        if hasOpacity {
            addAnimation(.Opacity)
        }
        var didAnimateFilter = false
        if hasFilter {
            didAnimateFilter = addAnimationForSwift(.Filter, keyframes, referenceBoxSize, animation, timeOffset)
            if didAnimateFilter {
                didAnimate = true
            }
        }
        if hasBackdropFilter {
            addAnimation(.WebkitBackdropFilter)
        }

        if didAnimate {
            m_owningLayer.setNeedsPostLayoutCompositingUpdate()
            m_owningLayer.setNeedsCompositingGeometryUpdate()
        }

        updateFilterAnimationOutsetsForSwift(keyframes, didAnimateFilter && !filterAnimationOutsets.isZero(), filterAnimationOutsets)

        return didAnimate
    }

    @cxx
    @implementation
    public func transformMatrixForProperty(_ property: WebCore.AnimatedProperty) -> WebCore.TransformationMatrix {
        var matrix = WebCore.TransformationMatrix()
        let boxSize = WebCore.FloatSize(WebCore.snappedIntRect(m_owningLayer.rendererBorderBoxRectForBacking()).size())

        switch property {
        case .Translate:
            renderer()[.Style].applyTranslate(&matrix, boxSize)
        case .Scale:
            renderer()[.Style].applyScale(&matrix, boxSize)
        case .Rotate:
            renderer()[.Style].applyRotate(&matrix, boxSize)
        case .Transform:
            renderer()[.Style].applyTransform(&matrix, boxSize)
        default:
            assertionFailure()
        }

        return matrix
    }
}

// MARK: - Contents rects and backdrop geometry

extension WebCore.RenderLayerBacking {
    @cxx
    @implementation
    public func updateContentsRects() {
        let contentOffset = contentOffsetInCompositingLayer()
        let contentOffsetAsFloatSize = WebCore.FloatSize(contentOffset.width().toFloat(), contentOffset.height().toFloat())

        if WebCore.RenderLayerBacking.videoEnabledForSwift(), let renderVideo = rendererAsRenderVideo(),
            !renderer()[.Style].objectViewBoxIsNone()
        {
            var croppedContentsRect = renderVideo.croppedVideoBoxForCompositing()
            croppedContentsRect.move(contentOffset)
            graphicsLayer()!.setContentsRect(WebCore.snapRectToDevicePixelsIfNeeded(croppedContentsRect, renderer()))

            if updateContentsClippingForSeparatedLayer(false) {
                return
            }

            var contentsClippingRect: WebCore.FloatRoundedRect
            if renderVideo.isBypassingObjectViewBoxForPictureInPicture() {
                // Nothing to crop to: the contents rect above is already the full, uncropped
                // natural-size rect. Clamping to the (small, pre-transition) border box below,
                // as the cropping case does, would clip this PiP-sized layer down to the inline
                // box size, showing only its top-left corner.
                contentsClippingRect = WebCore.FloatRoundedRect(graphicsLayer()!.contentsRect(), WebCore.CornerRadii())
            } else {
                contentsClippingRect = replacedContentsClippingRect(renderVideo, true)
                contentsClippingRect.move(contentOffsetAsFloatSize)
            }
            graphicsLayer()!.setContentsClippingRect(contentsClippingRect)
            return
        }

        graphicsLayer()!.setContentsRect(WebCore.snapRectToDevicePixelsIfNeeded(contentsBox(), renderer()))

        if updateContentsClippingForSeparatedLayer(true) {
            return
        }

        if let renderReplaced = rendererAsRenderReplaced() {
            if renderer().isRenderViewTransitionCapture() && !renderer().hasNonVisibleOverflow() {
                graphicsLayer()!.setContentsClippingRect(WebCore.FloatRoundedRect(graphicsLayer()!.contentsRect(), WebCore.CornerRadii()))
            } else {
                // FIXME: Support visible overflow for replaced content.
                var contentsClippingRect = replacedContentsClippingRect(renderReplaced, false)
                contentsClippingRect.move(contentOffsetAsFloatSize)
                graphicsLayer()!.setContentsClippingRect(contentsClippingRect)
            }
        }
    }

    fileprivate func updateBackdropFiltersGeometry() {
        var shouldUpdateBackdropFiltersGeometry = m_canCompositeBackdropFilters
        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        shouldUpdateBackdropFiltersGeometry =
            shouldUpdateBackdropFiltersGeometry || renderer().hasAppleVisualEffectRequiringBackdropFilter()
        #endif
        if !shouldUpdateBackdropFiltersGeometry {
            return
        }

        guard let renderBox = renderer().asRenderBox() else {
            return
        }

        let backdropFiltersRect: WebCore.FloatRoundedRect
        if renderBox[.Style].hasBorderRadius() && !renderBox.hasClip() {
            backdropFiltersRect = backdropFiltersRoundedRect(renderBox)
        } else {
            var boxRect = renderBox.borderBoxRect()
            if renderBox.hasClip() {
                boxRect.intersect(renderBox.clipRect(WebCore.LayoutPoint()))
            }
            boxRect.move(contentOffsetInCompositingLayer())
            backdropFiltersRect = WebCore.FloatRoundedRect(
                WebCore.snapRectToDevicePixels(boxRect, pixelSnappingScaleFactor()),
                WebCore.CornerRadii()
            )
            graphicsLayer()!.setBackdropFiltersShapePath(WebCore.Path())
        }

        graphicsLayer()!.setBackdropFiltersRect(backdropFiltersRect)
    }
}
