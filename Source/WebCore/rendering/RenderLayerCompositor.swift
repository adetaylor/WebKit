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
 * Copyright (C) 2009-2020 Apple Inc. All rights reserved.
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
 * Copyright (C) 2009, 2013 Apple Inc. All rights reserved.
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
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// RenderLayerCompositor's compositing decisions: whether a layer needs a compositing layer, why, and whether it
// needs its own backing store. WebCore.RenderLayerCompositor names this file in SWIFT_PRIVATE_FILEID.

internal import WebCore_Private

// The compositing state of a reflection should match that of its reflected layer.
// FIXME: remove and never ask questions about reflection layers.
private func rendererForCompositingTests(_ layer: WebCore.RenderLayer) -> WebCore.RenderLayerModelObject {
    let renderer = layer.renderer()
    if layer.isReflection() {
        // The RenderReplica's parent is the object being reflected.
        let rendererObject: WebCore.RenderObject = renderer
        return rendererObject.parent()!.asRenderLayerModelObject()!
    }
    return renderer
}

private enum FullScreenDescendant {
    case yes, no, notApplicable
}

private func isDescendantOfFullScreenLayer(_ layer: WebCore.RenderLayer) -> FullScreenDescendant {
    guard let fullScreenRenderer = layer.renderer().fullscreenElementRendererForSwift() else {
        return .notApplicable
    }
    guard let fullScreenLayer = fullScreenRenderer.layer() else {
        return .notApplicable
    }
    if fullScreenRenderer.hasBackdropRendererForSwift(layer.renderer()) {
        return .yes
    }
    return layer.isDescendantOf(fullScreenLayer) ? .yes : .no
}

private func canUseDescendantClippingLayer(_ layer: WebCore.RenderLayer) -> Bool {
    if layer.isolatesCompositedBlending() {
        return false
    }

    // We can only use the "descendant clipping layer" strategy when the clip rect is entirely within
    // the border box, because of interactions with border-radius clipping and compositing.
    if let renderer = layer.renderBox(), renderer.hasClip() {
        let borderBoxRect = renderer.borderBoxRect()
        let clipRect = renderer.clipRect(WebCore.LayoutPoint())
        return WebCore.intersection(borderBoxRect, clipRect) == clipRect
    }

    return true
}

private typealias CompositingReasons = WebCore.RenderLayerCompositor.CompositingReasons

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func needsToBeComposited(
        _ layer: borrowing WebCore.RenderLayer,
        _ queryData: WebCore.RenderLayerCompositor.RequiresCompositingDataView
    ) -> Bool {
        needsToBeComposited(layer, &queryData.pointee)
    }

    func needsToBeComposited(
        _ layer: borrowing WebCore.RenderLayer,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData
    ) -> Bool {
        if !canBeComposited(layer) {
            return false
        }
        return requiresCompositingLayer(layer, &queryData) || layer.mustCompositeForIndirectReasonsForCompositor()
            || (usesCompositing() && layer.isRenderViewLayer())
    }

    // Note: this specifies whether the RL needs a compositing layer for intrinsic reasons.
    // Use needsToBeComposited() to determine if a RL actually needs a compositing layer.
    // FIXME: is clipsCompositingDescendants() an intrinsic reason?
    @cxx
    @implementation
    public func requiresCompositingLayer(
        _ layer: borrowing WebCore.RenderLayer,
        _ queryData: WebCore.RenderLayerCompositor.RequiresCompositingDataView
    ) -> Bool {
        requiresCompositingLayer(layer, &queryData.pointee)
    }

    private func requiresCompositingLayer(
        _ layer: borrowing WebCore.RenderLayer,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData
    ) -> Bool {
        let renderer = rendererForCompositingTests(layer)

        guard let rendererLayer = renderer.layer() else {
            assertionFailure()
            return false
        }

        // The root layer always has a compositing layer, but it may not have backing.
        if requiresCompositingForTransform(renderer)
            || requiresCompositingForAnimation(renderer)
            || requiresCompositingForPosition(renderer, rendererLayer, &queryData)
            || requiresCompositingForCanvas(renderer)
            || requiresCompositingForFilters(renderer)
            || requiresCompositingForWillChange(renderer)
            || requiresCompositingForBackfaceVisibility(renderer)
            || requiresCompositingForViewTransition(renderer)
            || requiresCompositingForVideo(renderer)
            || requiresCompositingForModel(renderer)
            || requiresCompositingForSpatialPortal(renderer)
            || requiresCompositingForSpatialPortalHosting(rendererLayer)
            || requiresCompositingForScreenCaptureProtection(renderer)
            || requiresCompositingForFrame(renderer, &queryData)
            || requiresCompositingForPlugin(renderer, &queryData)
            || requiresCompositingForOverflowScrolling(rendererLayer, &queryData)
            || requiresCompositingForAnchorPositioning(rendererLayer)
        {
            queryData.intrinsic = true
            return true
        }
        return false
    }

    @cxx
    @implementation
    public func canBeComposited(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        if m_hasAcceleratedCompositing && layer.isSelfPaintingLayer() {
            if layer.renderer().isSkippedContent() {
                return false
            }

            // Drawable canvas descendants can only be recorded.
            if layer.isInsideDrawableCanvasForCompositor() {
                return false
            }

            if layer.renderer().isSVGLayerAwareRenderer() && layer.isFlattenedByEnclosingSVGReferenceFilter() {
                return false
            }

            if !layer.isInsideFragmentedFlow() {
                return true
            }

            // CSS Regions flow threads do not need to be composited as we use composited RenderFragmentContainers
            // to render the background of the RenderFragmentedFlow.
            if layer.isRenderFragmentedFlow() {
                return false
            }

            return true
        }
        return false
    }

    @cxx
    @implementation
    public func requiresOwnBackingStore(
        _ layer: borrowing WebCore.RenderLayer,
        _ compositingAncestorLayer: WebCore.RenderLayer?,
        _ layerCompositedBoundsInAncestor: WebCore.LayoutRect,
        _ ancestorCompositedBounds: WebCore.LayoutRect
    ) -> Bool {
        let renderer = layer.renderer()

        if let compositingAncestorLayer {
            let ancestorBacking = compositingAncestorLayer.backing()!
            if !(ancestorBacking.graphicsLayer()!.drawsContent() || ancestorBacking.paintsIntoWindow()
                || ancestorBacking.paintsIntoCompositedAncestor())
            {
                return true
            }
        }

        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        let hasAppleVisualEffect = renderer.hasAppleVisualEffect()
        #else
        let hasAppleVisualEffect = false
        #endif
        var queryData = WebCore.RenderLayerCompositor.RequiresCompositingData()
        if layer.isRenderViewLayer()
            || layer.transformValue().value != nil // note: excludes perspective and transformStyle3D.
            || requiresCompositingForAnimation(renderer)
            || requiresCompositingForPosition(renderer, layer, &queryData)
            || requiresCompositingForCanvas(renderer)
            || requiresCompositingForFilters(renderer)
            || requiresCompositingForWillChange(renderer)
            || requiresCompositingForBackfaceVisibility(renderer)
            || requiresCompositingForViewTransition(renderer)
            || requiresCompositingForVideo(renderer)
            || requiresCompositingForModel(renderer)
            || requiresCompositingForSpatialPortal(renderer)
            || requiresCompositingForSpatialPortalHosting(layer)
            || requiresCompositingForScreenCaptureProtection(renderer)
            || requiresCompositingForFrame(renderer, &queryData)
            || requiresCompositingForPlugin(renderer, &queryData)
            || requiresCompositingForOverflowScrolling(layer, &queryData)
            || requiresCompositingForAnchorPositioning(layer)
            || needsContentsCompositingLayer(layer)
            || renderer.isTransparent()
            || renderer.hasMask()
            || renderer.hasReflection()
            || renderer.hasFilter()
            || hasAppleVisualEffect
            || renderer.hasBackdropFilter()
        {
            return true
        }

        if layer.isComposited() && layer.backing()!.hasBackingSharingLayers() {
            return true
        }

        // FIXME: We really need to keep track of the ancestor layer that has its own backing store.
        if !ancestorCompositedBounds.contains(layerCompositedBoundsInAncestor) {
            return true
        }

        if layer.mustCompositeForIndirectReasonsForCompositor() {
            let reason = layer.indirectCompositingReason()
            return reason == .Overlap
                || reason == .OverflowScrollPositioning
                || reason == .Stacking
                || reason == .BackgroundLayer
                || reason == .GraphicalEffect
                || reason == .Preserve3D // preserve-3d has to create backing store to ensure that 3d-transformed elements intersect.
        }

        return false
    }

    @cxx
    @implementation
    public func reasonsForCompositing(_ layer: borrowing WebCore.RenderLayer) -> WebCore.RenderLayerCompositor.CompositingReasons {
        var reasons = WebCore.RenderLayerCompositor.CompositingReasons()

        if !layer.isComposited() {
            return reasons
        }

        var queryData = WebCore.RenderLayerCompositor.RequiresCompositingData()

        let renderer = rendererForCompositingTests(layer)
        let rendererLayer = renderer.layer()!

        if requiresCompositingForTransform(renderer) {
            reasons.add(CompositingReasons(.Transform3D))
        }

        if requiresCompositingForVideo(renderer) {
            reasons.add(CompositingReasons(.Video))
        } else if requiresCompositingForCanvas(renderer) {
            reasons.add(CompositingReasons(.Canvas))
        } else if requiresCompositingForModel(renderer) {
            reasons.add(CompositingReasons(.Model))
        } else if requiresCompositingForSpatialPortal(renderer) {
            reasons.add(CompositingReasons(.SpatialPortal))
        } else if requiresCompositingForScreenCaptureProtection(renderer) {
            reasons.add(CompositingReasons(.ScreenCaptureProtection))
        } else if requiresCompositingForPlugin(renderer, &queryData) {
            reasons.add(CompositingReasons(.Plugin))
        } else if requiresCompositingForFrame(renderer, &queryData) {
            reasons.add(CompositingReasons(.IFrame))
        }

        if canRender3DTransforms() && renderer[.Style].backfaceVisibility() == .Hidden {
            reasons.add(CompositingReasons(.BackfaceVisibilityHidden))
        }

        if requiresCompositingForAnimation(renderer) {
            reasons.add(CompositingReasons(.Animation))
        }

        if requiresCompositingForFilters(renderer) {
            reasons.add(CompositingReasons(.Filters))
        }

        if requiresCompositingForWillChange(renderer) {
            reasons.add(CompositingReasons(.WillChange))
        }

        if requiresCompositingForPosition(renderer, rendererLayer, &queryData) {
            reasons.add(CompositingReasons(renderer.isFixedPositioned() ? .PositionFixed : .PositionSticky))
        }

        if requiresCompositingForOverflowScrolling(rendererLayer, &queryData) {
            reasons.add(CompositingReasons(.OverflowScrolling))
        }

        if requiresCompositingForAnchorPositioning(rendererLayer) {
            reasons.add(CompositingReasons(.AnchorPositioning))
        }

        if requiresCompositingForSpatialPortalHosting(rendererLayer) {
            reasons.add(CompositingReasons(.SpatialPortalHosting))
        }

        switch rendererLayer.indirectCompositingReason() {
        case .None:
            break
        case .Clipping:
            reasons.add(CompositingReasons(.ClipsCompositingDescendants))
        case .Stacking:
            reasons.add(CompositingReasons(.Stacking))
        case .OverflowScrollPositioning:
            reasons.add(CompositingReasons(.OverflowScrollPositioning))
        case .Overlap:
            reasons.add(CompositingReasons(.Overlap))
        case .BackgroundLayer:
            reasons.add(CompositingReasons(.NegativeZIndexChildren))
        case .GraphicalEffect:
            if renderer.isTransformed() {
                reasons.add(CompositingReasons(.TransformWithCompositedDescendants))
            }

            if renderer.isTransparent() {
                reasons.add(CompositingReasons(.OpacityWithCompositedDescendants))
            }

            if renderer.hasMask() {
                reasons.add(CompositingReasons(.MaskWithCompositedDescendants))
            }

            if renderer.hasReflection() {
                reasons.add(CompositingReasons(.ReflectionWithCompositedDescendants))
            }

            if renderer.hasFilter() || renderer.hasBackdropFilter() {
                reasons.add(CompositingReasons(.FilterWithCompositedDescendants))
            }

            #if canImport(Darwin) // HAVE(CORE_MATERIAL)
            if renderer.hasAppleVisualEffect() {
                reasons.add(CompositingReasons(.FilterWithCompositedDescendants))
            }
            #endif

            if layer.isBackdropRoot() {
                reasons.add(CompositingReasons(.BackdropRoot))
            }

            if layer.isolatesCompositedBlending() {
                reasons.add(CompositingReasons(.IsolatesCompositedBlendingDescendants))
            }

            if layer.hasBlendMode() {
                reasons.add(CompositingReasons(.BlendingWithCompositedDescendants))
            }

            if renderer.hasClipPath() {
                reasons.add(CompositingReasons(.ClipsCompositingDescendants))
            }
        case .Perspective:
            reasons.add(CompositingReasons(.Perspective))
        case .Preserve3D:
            reasons.add(CompositingReasons(.Preserve3D))
        @unknown default:
            break
        }

        if usesCompositing() && rendererLayer.isRenderViewLayer() {
            reasons.add(CompositingReasons(.Root))
        }

        return reasons
    }

    // Return true if the given layer has some ancestor in the RenderLayer hierarchy that clips,
    // up to the enclosing compositing ancestor. This is required because compositing layers are parented
    // according to the z-order hierarchy, yet clipping goes down the renderer hierarchy.
    // Thus, a RenderLayer can be clipped by a RenderLayer that is an ancestor in the renderer hierarchy,
    // but a sibling in the z-order hierarchy.
    // FIXME: can we do this without a tree walk?
    @cxx
    @implementation
    public func clippedByAncestor(_ layer: WebCore.RenderLayer, _ compositingAncestor: WebCore.RenderLayer?) -> Bool {
        assert(layer.isComposited())
        guard let compositingAncestor else {
            return false
        }

        if layer.renderer().capturedInViewTransition() {
            return false
        }

        // If the compositingAncestor clips, that will be taken care of by clipsCompositingDescendants(),
        // so we only care about clipping between its first child that is our ancestor (the computeClipRoot),
        // and layer. The exception is when the compositingAncestor isolates composited blending children,
        // in this case it is not allowed to clipsCompositingDescendants() and each of its children
        // will be clippedByAncestor()s, including the compositingAncestor.
        var computeClipRoot: WebCore.RenderLayer? = compositingAncestor
        if canUseDescendantClippingLayer(compositingAncestor) {
            computeClipRoot = nil
            var parent: WebCore.RenderLayer? = layer
            while let current = parent {
                let next = current.parent()
                if WebCore.LayerRef(next) == WebCore.LayerRef(compositingAncestor) {
                    computeClipRoot = current
                    break
                }
                parent = next
            }

            guard let root = computeClipRoot, !(WebCore.LayerRef(root) == WebCore.LayerRef(layer)) else {
                return false
            }
        }

        let backgroundClipRect = layer.backgroundClipRect(
            RenderLayerClipRectsContext(computeClipRoot, WebCore.PaintingClipRects, WebCore.RenderLayer.clipRectTemporaryOptionsForSwift())
        )
        return !backgroundClipRect.isInfinite() // FIXME: Incorrect for CSS regions.
    }

    // Return true if the given layer is a stacking context and has compositing child
    // layers that it needs to clip. In this case we insert a clipping GraphicsLayer
    // into the hierarchy between this layer and its children in the z-order hierarchy.
    @cxx
    @implementation
    public static func clipsCompositingDescendants(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        let layerRenderer = layer.renderer()
        // View transition new always has composited descendants in the graphics layer
        // tree due to hosting (but not in the RenderLayer tree).
        if layerRenderer[.Style].pseudoElementType().value == .ViewTransitionNew && layerRenderer.hasClipOrNonVisibleOverflow() {
            return true
        }

        if !(layer.hasCompositingDescendant() && layerRenderer.hasClipOrNonVisibleOverflow()) {
            return false
        }

        if layer.hasCompositedNonContainedDescendants() {
            return false
        }

        return canUseDescendantClippingLayer(layer)
    }

    private func requiresCompositingForBackfaceVisibility(_ renderer: WebCore.RenderLayerModelObject) -> Bool {
        if !hasCompositingTrigger(.ThreeDTransform) {
            return false
        }

        if renderer[.Style].backfaceVisibility() != .Hidden {
            return false
        }

        let rendererLayer = renderer.layer()!
        if rendererLayer.has3DTransformedAncestorForCompositor() {
            return true
        }

        // FIXME: workaround for webkit.org/b/132801
        if let stackingContext = rendererLayer.stackingContext(), stackingContext.renderer()[.Style].usedTransformStyle3D() == .Preserve3D {
            return true
        }

        return false
    }

    private func requiresCompositingForViewTransition(_ renderer: WebCore.RenderLayerModelObject) -> Bool {
        renderer.effectiveCapturedInViewTransition() || renderer.isRenderViewTransitionCapture()
            || renderer.isViewTransitionContainingBlock() || (renderer.isRenderView() && renderer.documentHasActiveViewTransitionForSwift())
    }

    private func requiresCompositingForFilters(_ renderer: WebCore.RenderLayerModelObject) -> Bool {
        if renderer.hasBackdropFilter() {
            return true
        }

        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        if renderer.hasAppleVisualEffect() {
            return true
        }
        #endif

        if !hasCompositingTrigger(.Filter) {
            return false
        }

        return renderer.hasFilter()
    }

    private func requiresCompositingForWillChange(_ renderer: WebCore.RenderLayerModelObject) -> Bool {
        if !renderer[.Style].willChangeCanTriggerCompositing() {
            return false
        }

        if m_ignoresWillChangeOverBudget {
            return false
        }

        // FIXME: does this require layout?
        if let rendererLayer = renderer.layer(), isDescendantOfFullScreenLayer(rendererLayer) == .no {
            return false
        }

        #if !os(macOS) // !PLATFORM(MAC)
        // Ugly workaround for rdar://71881767. Undo when webkit.org/b/222092 and webkit.org/b/222132 are fixed.
        if m_compositingPolicy == .Conservative {
            return false
        }
        #endif

        if renderer.isRenderBox() {
            return true
        }

        return renderer[.Style].willChangeCanTriggerCompositingOnInline()
    }

    private func addToWillChangeAreaEstimate(_ overlapMap: OverlapMapContext, _ layer: WebCore.RenderLayer) {
        if !hasWillChangeAreaEstimateForSwift() {
            return
        }

        if !requiresCompositingForWillChange(rendererForCompositingTests(layer)) {
            return
        }

        // Not the OverlapExtent bounds, which inflate fixed and sticky layers to cover every scroll position.
        let layerBounds = layer.overlapBounds()
        addToWillChangeAreaEstimateForSwift(
            overlapMap.absoluteRect(
                WebCore.FloatRect(
                    layerBounds.x().toFloat(),
                    layerBounds.y().toFloat(),
                    layerBounds.width().toFloat(),
                    layerBounds.height().toFloat()
                )
            )
        )
    }

    private func requiresCompositingForPlugin(
        _ renderer: WebCore.RenderLayerModelObject,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData
    ) -> Bool {
        if !hasCompositingTrigger(.Plugin) {
            return false
        }

        if !WebCore.RenderLayerCompositor.isCompositedPlugin(renderer) {
            return false
        }

        let pluginRenderer = renderer.asRenderBox()!
        if pluginRenderer.usedVisibility() != .Visible {
            return false
        }

        // If we can't reliably know the size of the plugin yet, don't change compositing state.
        if queryData.layoutUpToDate == .No {
            queryData.reevaluateAfterLayout = true
            return pluginRenderer.isComposited()
        }

        // Don't go into compositing mode if height or width are zero, or size is 1x1.
        // The product wraps, as the int product does in practice, for a box over 2^31 square pixels.
        let contentBox = WebCore.snappedIntRect(pluginRenderer.contentBoxRect())
        return contentBox.height() &* contentBox.width() > 1
    }

    private func requiresCompositingForFrame(
        _ renderer: WebCore.RenderLayerModelObject,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData
    ) -> Bool {
        if !renderer.isRenderWidget() {
            return false
        }
        let frameRenderer = renderer.asRenderBox()!

        if frameRenderer.usedVisibility() != .Visible {
            return false
        }

        if !WebCore.RenderLayerCompositor.hasCompositedWidgetContents(renderer) {
            return false
        }

        if queryData.layoutUpToDate == .No {
            queryData.reevaluateAfterLayout = true
            return frameRenderer.isComposited()
        }

        // Don't go into compositing mode if height or width are zero.
        return !WebCore.snappedIntRect(frameRenderer.contentBoxRect()).isEmpty()
    }

    @cxx
    @implementation
    public func requiresCompositingForPosition(
        _ renderer: WebCore.RenderLayerModelObject,
        _ layer: borrowing WebCore.RenderLayer,
        _ queryData: WebCore.RenderLayerCompositor.RequiresCompositingDataView
    ) -> Bool {
        requiresCompositingForPosition(renderer, layer, &queryData.pointee)
    }

    @inline(always)
    private func requiresCompositingForPosition(
        _ renderer: WebCore.RenderLayerModelObject,
        _ layer: borrowing WebCore.RenderLayer,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData
    ) -> Bool {
        // position:fixed elements that create their own stacking context (e.g. have an explicit z-index,
        // opacity, transform) can get their own composited layer. A stacking context is required otherwise
        // z-index and clipping will be broken.
        let rendererObject: WebCore.RenderObject = renderer
        if !rendererObject.isPositioned() {
            return false
        }

        if isDescendantOfFullScreenLayer(layer) == .no {
            return false
        }

        let position = renderer[.Style].position()
        let isFixed = renderer.isFixedPositioned()
        if isFixed && !layer.isStackingContext() {
            return false
        }

        let isSticky = rendererObject.isInFlowPositioned() && position == .Sticky
        if !isFixed && !isSticky {
            return false
        }

        // FIXME: acceleratedCompositingForFixedPositionEnabled should probably be renamed
        // acceleratedCompositingForViewportConstrainedPositionEnabled().
        if !m_renderView.get().settings().acceleratedCompositingForFixedPositionEnabled() {
            return false
        }

        if isSticky {
            // rendererForCompositingTests() substitutes the reflected renderer for a RenderReplica, so `layer` can
            // be the replica's layer while `renderer` is the sticky renderer being reflected. Ask about the sticky
            // renderer's own layer; for every other caller this is the layer we were passed.
            guard let stickyLayer = renderer.layer() else {
                return false
            }
            return isAsyncScrollableStickyLayerForSwift(stickyLayer)
        }

        if queryData.layoutUpToDate == .No {
            queryData.reevaluateAfterLayout = true
            return layer.isComposited()
        }

        let container = renderer.container()
        assert(container != nil)

        // Don't promote fixed position elements that are descendants of a non-view container, e.g. transformed elements.
        // They will stay fixed wrt the container rather than the enclosing frame.
        if !WebCore.RenderObject.isSameRenderer(container, m_renderView.get()) {
            queryData.nonCompositedForPositionReason = WebCore.RenderLayer.NotCompositedForNonViewContainer
            return false
        }

        let paintsContent = layer.isVisuallyNonEmptyForSwift() || layer.hasVisibleDescendant()
        if !paintsContent {
            queryData.nonCompositedForPositionReason = WebCore.RenderLayer.NotCompositedForNoVisibleContent
            return false
        }

        // Scroll-adjusted boxes can be scrolled into view, so don't check viewport intersection on them.
        if layer.anchorScrollAdjustment().value == nil && !fixedLayerIntersectsViewport(layer) {
            queryData.nonCompositedForPositionReason = WebCore.RenderLayer.NotCompositedForBoundsOutOfView
            return false
        }

        return true
    }

    private func requiresCompositingForOverflowScrolling(
        _ layer: borrowing WebCore.RenderLayer,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData
    ) -> Bool {
        if !layer.canUseCompositedScrolling() {
            return false
        }

        if queryData.layoutUpToDate == .No {
            queryData.reevaluateAfterLayout = true
            return layer.isComposited()
        }

        layer.computeHasCompositedScrollableOverflow(.Yes)
        return layer.hasCompositedScrollableOverflow()
    }

    private func requiresCompositingForAnchorPositioning(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        layer.anchorScrollAdjustment().value != nil
    }

    @cxx
    @implementation
    public func computeIndirectCompositingReason(
        _ layer: borrowing WebCore.RenderLayer,
        _ hasCompositedDescendants: Bool,
        _ has3DTransformedDescendants: Bool,
        _ paintsIntoProvidedBacking: Bool
    ) -> WebCore.IndirectCompositingReason {
        // When a layer has composited descendants, some effects, like 2d transforms, filters, masks etc must be implemented
        // via compositing so that they also apply to those composited descendants.
        let renderer = layer.renderer()
        if hasCompositedDescendants
            && (layer.isolatesCompositedBlending() || layer.isBackdropRoot() || layer.transformValue().value != nil
                || renderer.createsGroup() || renderer.hasReflection())
        {
            return .GraphicalEffect
        }

        // A layer with preserve-3d or perspective only needs to be composited if there are descendant layers that
        // will be affected by the preserve-3d or perspective.
        if has3DTransformedDescendants {
            if renderer[.Style].usedTransformStyle3D() == .Preserve3D {
                return .Preserve3D
            }

            if !renderer[.Style].perspectiveIsNone() {
                return .Perspective
            }
        }

        // If this layer scrolls independently from the layer that it would paint into, it needs to get composited.
        if !paintsIntoProvidedBacking && layer.hasCompositedScrollingAncestor() {
            if let paintDestination = layer.paintOrderParent(),
                WebCore.RenderLayerCompositor.layerScrollBehaviorRelativeToCompositedAncestor(layer, paintDestination) != .None
            {
                return .OverflowScrollPositioning
            }
        }

        // Check for clipping last; if compositing just for clipping, the layer doesn't need its own backing store.
        if hasCompositedDescendants && WebCore.RenderLayerCompositor.clipsCompositingDescendants(layer) {
            return .Clipping
        }

        return .None
    }

    @cxx
    @implementation
    public func layerHas3DContent(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        let layer = copy layer
        let renderer = layer.renderer()

        if renderer[.Style].usedTransformStyle3D() == .Preserve3D || !renderer[.Style].perspectiveIsNone()
            || renderer[.Style].has3DTransformOperation()
        {
            return true
        }

        layer.updateLayerListsIfNeeded()

        func listHas3DContent(_ which: WebCore.PaintOrderList) -> Bool {
            var index = 0
            while index < layer.paintOrderListCount(which) {
                if layerHas3DContent(layer.paintOrderListLayer(which, index)) {
                    return true
                }
                index += 1
            }
            return false
        }

        return layer.withLayerListMutationForbidden {
            listHas3DContent(.Negative) || listHas3DContent(.Positive) || listHas3DContent(.NormalFlow)
        }
    }

    @cxx
    @implementation
    public func updateEventRegionsRecursive(_ layer: WebCore.RenderLayer) {
        #if ENABLE_ASYNC_SCROLLING // ENABLE(ASYNC_SCROLLING)
        if layer.isComposited() {
            layer.backing()!.updateEventRegion()
        }

        if !layer.hasDescendantNeedingEventRegionUpdate() {
            return
        }

        var childLayer = layer.firstChild()
        while let child = childLayer {
            updateEventRegionsRecursive(child)
            childLayer = child.nextSibling()
        }

        layer.clearHasDescendantNeedingEventRegionUpdate()
        #endif
    }
}

// MARK: - Overlap map

// A layer that encloses others in the overlap map, and its bounds; a clipping scope when the layer has composited scrolling.
private struct OverlapMapScope {
    var layer: WebCore.LayerRef
    var bounds: WebCore.LayoutRect
}

private struct OverlapRectList {
    var rects: [WebCore.LayoutRect] = []
    var boundingRect = WebCore.LayoutRect()

    static let recentRectsToTestForContainment = 4

    func isAlreadyCovered(_ rect: WebCore.LayoutRect) -> Bool {
        let recentCount = min(Self.recentRectsToTestForContainment, rects.count)
        var index = rects.count
        while index > rects.count - recentCount {
            index -= 1
            if rects[index].contains(rect) {
                return true
            }
        }
        return false
    }

    mutating func removeRecentRectsCoveredBy(_ rect: WebCore.LayoutRect) {
        let recentCount = min(Self.recentRectsToTestForContainment, rects.count)
        let start = rects.count - recentCount
        var index = start
        while index < rects.count {
            if rect.contains(rects[index]) {
                rects.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    mutating func append(_ rect: WebCore.LayoutRect) {
        if isAlreadyCovered(rect) {
            return
        }

        removeRecentRectsCoveredBy(rect)

        rects.append(rect)
        boundingRect.unite(rect)
    }

    mutating func append(_ rectList: OverlapRectList) {
        for rect in rectList.rects {
            append(rect)
        }
    }

    func intersects(_ rect: WebCore.LayoutRect) -> Bool {
        if rects.isEmpty || !rect.intersects(boundingRect) {
            return false
        }

        for currentRect in rects {
            if currentRect.intersects(rect) {
                return true
            }
        }
        return false
    }
}

// A node of an overlap container's tree of layers with composited scrolling.
private struct OverlapClippingScope {
    var layer: WebCore.LayerRef
    var bounds = WebCore.LayoutRect() // Bounds of the composited clip.
    var children: [OverlapClippingScope] = []
    var rectList = OverlapRectList()

    init(_ layer: WebCore.LayerRef, _ bounds: WebCore.LayoutRect = WebCore.LayoutRect()) {
        self.layer = layer
        self.bounds = bounds
    }

    func childIndex(_ layer: WebCore.LayerRef) -> Int? {
        children.firstIndex(where: { $0.layer == layer })
    }
}

// Used to store overlap rects in a way that takes overflow into account.
// It stores a tree whose nodes are layers with composited scrolling. The tree is built lazily as layers are added whose containing block
// chains contain composited scrollers. The tree always starts at the root layer.
// Checking for overlap involves finding the node for the clipping layer enclosing the given layer (or the root),
// and comparing against the bounds of earlier siblings.
private struct OverlapMapContainer {
    var rootScope: OverlapClippingScope
    let scopeLayer: WebCore.LayerRef

    init(_ rootLayer: WebCore.LayerRef, _ scopeLayer: WebCore.LayerRef) {
        rootScope = OverlapClippingScope(rootLayer)
        self.scopeLayer = scopeLayer
    }

    var isEmpty: Bool { rootScope.rectList.rects.isEmpty && rootScope.children.isEmpty }

    // Layers are added in z-order, lazily creating clipping scopes as necessary.
    mutating func add(_ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) {
        assert(!enclosingClippingLayers.isEmpty)
        Self.appendRect(&rootScope, enclosingClippingLayers, 1, bounds)
    }

    // Finds or makes the scope for the clipping layers from the given index, and adds the rect there.
    private static func appendRect(
        _ scope: inout OverlapClippingScope,
        _ enclosingClippingLayers: borrowing [OverlapMapScope],
        _ index: Int,
        _ bounds: WebCore.LayoutRect
    ) {
        if index == enclosingClippingLayers.count {
            scope.rectList.append(bounds)
            return
        }
        let scopeLayerAndBounds = enclosingClippingLayers[index]
        if let childIndex = scope.childIndex(scopeLayerAndBounds.layer) {
            appendRect(&scope.children[childIndex], enclosingClippingLayers, index + 1, bounds)
            return
        }
        scope.children.append(OverlapClippingScope(scopeLayerAndBounds.layer, scopeLayerAndBounds.bounds))
        appendRect(&scope.children[scope.children.count - 1], enclosingClippingLayers, index + 1, bounds)
    }

    // The rects of the scope for the clipping layers, if it exists.
    private func rectListForLayers(
        _ enclosingClippingLayers: borrowing [OverlapMapScope],
        _ body: (borrowing OverlapRectList) -> Bool
    ) -> Bool? {
        assert(!enclosingClippingLayers.isEmpty)
        return Self.rectListForLayers(rootScope, enclosingClippingLayers, 1, body)
    }

    private static func rectListForLayers(
        _ scope: borrowing OverlapClippingScope,
        _ enclosingClippingLayers: borrowing [OverlapMapScope],
        _ index: Int,
        _ body: (borrowing OverlapRectList) -> Bool
    ) -> Bool? {
        if index == enclosingClippingLayers.count {
            return body(scope.rectList)
        }
        guard let childIndex = scope.childIndex(enclosingClippingLayers[index].layer) else {
            return nil
        }
        return rectListForLayers(scope.children[childIndex], enclosingClippingLayers, index + 1, body)
    }

    func overlapsLayers(_ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) -> Bool {
        if rootScope.rectList.intersects(bounds) {
            return true
        }

        if rootScope.children.isEmpty {
            return false
        }

        // Find the ClippingScope for which this layer is a child.
        // FIXME: In some cases do we have to walk up the ancestor clipping scope chain?
        return rectListForLayers(enclosingClippingLayers, { $0.intersects(bounds) }) ?? false
    }

    func isCoveredByRecentRects(_ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) -> Bool {
        rectListForLayers(enclosingClippingLayers, { $0.isAlreadyCovered(bounds) }) ?? false
    }

    mutating func append(_ otherContainer: borrowing OverlapMapContainer) {
        Self.mergeClippingScopesRecursive(otherContainer.rootScope, &rootScope)
    }

    private static func mergeClippingScopesRecursive(_ sourceScope: borrowing OverlapClippingScope, _ destScope: inout OverlapClippingScope)
    {
        assert(sourceScope.layer == destScope.layer)
        destScope.rectList.append(sourceScope.rectList)

        for sourceChildScope in sourceScope.children {
            if let destChildIndex = destScope.childIndex(sourceChildScope.layer) {
                mergeClippingScopesRecursive(sourceChildScope, &destScope.children[destChildIndex])
            } else {
                // New child, just copy the whole subtree.
                destScope.children.append(sourceChildScope)
            }
        }
    }
}

// The overlap map of one compositing update: the rects of layers that later layers must not overlap without compositing,
// by compositing container.
private final class CompositingOverlapMap {
    private var overlapStack: [OverlapMapContainer] = []
    private var speculativeOverlapStack: [OverlapMapContainer] = []
    private let rootLayer: WebCore.LayerRef
    private(set) var isEmpty = true

    init(_ rootLayer: WebCore.RenderLayer) {
        self.rootLayer = WebCore.LayerRef(rootLayer)
        // Begin assuming the root layer will be composited so that there is
        // something on the stack. The root layer should also never get an
        // popCompositingContainer call.
        pushCompositingContainer(rootLayer)
    }

    func isCoveredByRecentRects(_ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) -> Bool {
        if overlapStack.count < 2 {
            return false
        }

        if !overlapStack[overlapStack.count - 2].isCoveredByRecentRects(bounds, enclosingClippingLayers) {
            return false
        }

        if speculativeOverlapStack.count >= 2
            && !speculativeOverlapStack[speculativeOverlapStack.count - 2].isCoveredByRecentRects(bounds, enclosingClippingLayers)
        {
            return false
        }

        return true
    }

    func add(_ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) {
        // Layers do not contribute to overlap immediately--instead, they will
        // contribute to overlap as soon as their composited ancestor has been
        // recursively processed and popped off the stack.
        assert(overlapStack.count >= 2)
        overlapStack[overlapStack.count - 2].add(bounds, enclosingClippingLayers)
        if !speculativeOverlapStack.isEmpty {
            assert(speculativeOverlapStack.count >= 2)
            speculativeOverlapStack[speculativeOverlapStack.count - 2].add(bounds, enclosingClippingLayers)
        }

        isEmpty = false
    }

    func overlapsLayers(_ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) -> Bool {
        // Negative z-order children are traversed with a speculative compositing container live, but they
        // still have to be tested against layers that were already composited earlier in paint order,
        // otherwise they never composite for overlap and paint behind those layers' GraphicsLayers. The
        // top of overlapStack is untouched for the lifetime of the speculative container, so it is the
        // overlap state as of the speculative push: it has the already-composited layers, but nothing the
        // negative z-order children contribute, so they still don't force each other to composite.
        assert(speculativeOverlapStack.isEmpty || speculativeOverlapStack[speculativeOverlapStack.count - 1].isEmpty)
        return overlapStack[overlapStack.count - 1].overlapsLayers(bounds, enclosingClippingLayers)
    }

    func pushCompositingContainer(_ layer: WebCore.RenderLayer) {
        confirmSpeculativeCompositingContainer()
        overlapStack.append(OverlapMapContainer(rootLayer, WebCore.LayerRef(layer)))
    }

    func popCompositingContainer(_ layer: WebCore.RenderLayer) {
        assert(overlapStack[overlapStack.count - 1].scopeLayer == WebCore.LayerRef(layer))
        let container = overlapStack.removeLast()
        overlapStack[overlapStack.count - 1].append(container)
    }

    func pushSpeculativeCompositingContainer(_ layer: WebCore.RenderLayer) {
        // Create a duplicate copy of the overlap stack, push the container to one,
        // and make all future add calls apply to both stacks.
        // If we end up needing the compositing container, then we copy across the speculative
        // stack to replace the main, otherwise we throw the speculative stack away.
        // If we already have a speculative stack (and we've recursed into this), then just force
        // a real compositing container on the outer, since otherwise we'd have to start
        // tracking four possible outcomes.
        confirmSpeculativeCompositingContainer()
        speculativeOverlapStack.append(contentsOf: overlapStack)
        speculativeOverlapStack.append(OverlapMapContainer(rootLayer, WebCore.LayerRef(layer)))
    }

    func confirmSpeculativeCompositingContainer() {
        if !speculativeOverlapStack.isEmpty {
            overlapStack = speculativeOverlapStack
            speculativeOverlapStack = []
        }
    }

    func maybePopSpeculativeCompositingContainer() -> Bool {
        if !speculativeOverlapStack.isEmpty {
            speculativeOverlapStack = []
            return true
        }
        return false
    }
}

// The overlap map and the geometry map a compositing update walks with.
private struct OverlapMapContext: ~Escapable {
    let geometryMap: WebCore.RenderGeometryMapView
    let map: CompositingOverlapMap

    @_lifetime(copy geometryMap)
    init(_ geometryMap: WebCore.RenderGeometryMapView, _ map: CompositingOverlapMap) {
        self.geometryMap = geometryMap
        self.map = map
    }

    func isEmpty() -> Bool { map.isEmpty }
    func add(_ layer: WebCore.RenderLayer, _ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) {
        map.add(bounds, enclosingClippingLayers)
    }
    func overlapsLayers(
        _ layer: WebCore.RenderLayer,
        _ bounds: WebCore.LayoutRect,
        _ enclosingClippingLayers: borrowing [OverlapMapScope]
    ) -> Bool { map.overlapsLayers(bounds, enclosingClippingLayers) }
    func isCoveredByRecentRects(_ bounds: WebCore.LayoutRect, _ enclosingClippingLayers: borrowing [OverlapMapScope]) -> Bool {
        map.isCoveredByRecentRects(bounds, enclosingClippingLayers)
    }

    func pushCompositingContainer(_ layer: WebCore.RenderLayer) { map.pushCompositingContainer(layer) }
    func popCompositingContainer(_ layer: WebCore.RenderLayer) { map.popCompositingContainer(layer) }
    func pushSpeculativeCompositingContainer(_ layer: WebCore.RenderLayer) { map.pushSpeculativeCompositingContainer(layer) }
    func confirmSpeculativeCompositingContainer() { map.confirmSpeculativeCompositingContainer() }
    func maybePopSpeculativeCompositingContainer() -> Bool { map.maybePopSpeculativeCompositingContainer() }

    func pushMappingsToAncestor(_ layer: WebCore.RenderLayer, _ ancestorLayer: WebCore.RenderLayer?, _ respectTransforms: Bool) {
        geometryMap.pushMappingsToAncestor(layer, ancestorLayer, respectTransforms)
    }
    func popMappingsToAncestor(_ ancestorLayer: WebCore.RenderLayer?) { geometryMap.popMappingsToAncestor(ancestorLayer) }
    func absoluteRect(_ rect: WebCore.FloatRect) -> WebCore.FloatRect { geometryMap.absoluteRect(rect) }
}

// MARK: - Compositing requirements

// The extent of a layer in the overlap map, computed lazily.
private struct OverlapExtent {
    var bounds = WebCore.LayoutRect()
    // Roots to leaves; the last is the layer of the innermost scope.
    var clippingScopes: [OverlapMapScope] = []
    var clippingScopeLayer: WebCore.RenderLayer? = nil

    var extentComputed = false
    var hasTransformAnimation = false
    var animationCausesExtentUncertainty = false
    var clippingScopesComputed = false

    var knownToBeHaveExtentUncertainty: Bool { extentComputed && animationCausesExtentUncertainty }
}

private struct CompositingState {
    var compositingAncestor: WebCore.RenderLayer?
    var backingSharingAncestor: WebCore.RenderLayer? = nil
    var stackingContextAncestor: WebCore.RenderLayer? = nil
    var subtreeIsCompositing = false
    var testingOverlap = true
    var fullPaintOrderTraversalRequired = false
    var descendantsRequireCompositingUpdate = false
    var ancestorHasTransformAnimation = false
    var ancestorAllowsBackingStoreDetachingForFixed = false
    var hasCompositedNonContainedDescendants = false
    var hasNotIsolatedCompositedBlendingDescendants = false
    var hasBackdropFilterDescendantsWithoutRoot = false

    init(_ compositingAncestor: WebCore.RenderLayer?) {
        self.compositingAncestor = compositingAncestor
    }

    func stateForPaintOrderChildren(_ layer: WebCore.RenderLayer) -> CompositingState {
        var childState = CompositingState(compositingAncestor)
        if layer.isStackingContext() {
            childState.stackingContextAncestor = layer
        } else {
            childState.stackingContextAncestor = stackingContextAncestor
        }

        childState.backingSharingAncestor = backingSharingAncestor
        childState.subtreeIsCompositing = false
        childState.testingOverlap = testingOverlap
        childState.fullPaintOrderTraversalRequired = fullPaintOrderTraversalRequired
        childState.descendantsRequireCompositingUpdate = descendantsRequireCompositingUpdate
        childState.ancestorHasTransformAnimation = ancestorHasTransformAnimation
        childState.ancestorAllowsBackingStoreDetachingForFixed = ancestorAllowsBackingStoreDetachingForFixed
        childState.hasCompositedNonContainedDescendants = false
        childState.hasNotIsolatedCompositedBlendingDescendants = false // FIXME: should this only be reset for stacking contexts?
        childState.hasBackdropFilterDescendantsWithoutRoot = false
        return childState
    }

    mutating func updateWithDescendantStateAndLayer(
        _ childState: borrowing CompositingState,
        _ layer: WebCore.RenderLayer,
        _ ancestorLayer: WebCore.RenderLayer?,
        _ layerExtent: borrowing OverlapExtent,
        isUnchangedSubtree: Bool = false
    ) {
        // Subsequent layers in the parent stacking context also need to composite.
        subtreeIsCompositing = subtreeIsCompositing || childState.subtreeIsCompositing || layer.isComposited()
        if !isUnchangedSubtree {
            fullPaintOrderTraversalRequired = fullPaintOrderTraversalRequired || childState.fullPaintOrderTraversalRequired
        }

        // Turn overlap testing off for later layers if it's already off, or if we have an animating transform.
        // Note that if the layer clips its descendants, there's no reason to propagate the child animation to the parent layers. That's
        // because
        // we know for sure the animation is contained inside the clipping rectangle, which is already added to the overlap map.
        let canReenableOverlapTesting = { layer.isComposited() && WebCore.RenderLayerCompositor.clipsCompositingDescendants(layer) }
        if (!childState.testingOverlap && !canReenableOverlapTesting()) || layerExtent.knownToBeHaveExtentUncertainty {
            testingOverlap = false
        }

        hasCompositedNonContainedDescendants = { () -> Bool in
            if hasCompositedNonContainedDescendants {
                return true
            }
            guard let ancestorLayer else {
                return false
            }
            if !layer.isComposited() {
                return false
            }
            let renderer: WebCore.RenderObject = layer.renderer()
            if !renderer.isOutOfFlowPositioned() {
                return false
            }
            if layer.ancestorLayerIsInContainingBlockChain(ancestorLayer, nil) {
                return false
            }
            return true
        }()

        if (layer.isComposited() && layer.hasBlendMode())
            || (layer.hasNotIsolatedCompositedBlendingDescendants() && !layer.isolatesCompositedBlending())
        {
            hasNotIsolatedCompositedBlendingDescendants = true
        }

        if (layer.isComposited() && layer.hasBackdropFilter())
            || (layer.hasBackdropFilterDescendantsWithoutRoot() && !layer.isBackdropRoot())
        {
            hasBackdropFilterDescendantsWithoutRoot = true
        }

        #if canImport(Darwin) // HAVE(CORE_MATERIAL)
        if layer.isComposited() && layer.hasAppleVisualEffectRequiringBackdropFilter() {
            hasBackdropFilterDescendantsWithoutRoot = true
        }
        #endif
    }

    var hasNonRootCompositedAncestor: Bool {
        guard let compositingAncestor else {
            return false
        }
        return !compositingAncestor.isRenderViewLayer()
    }
}

// Backing sharing is used to reduce memory use by allowing multiple RenderLayers (normally siblings) which share the same
// stacking context ancestor to render into the same compositing layer. This has to be done in a way that preserves back-to-front
// paint order. The common case where this kicks in is a non-stacking context overflow:scroll with position:relative descendants.
//
// When we've determined that a layer can be composited, it becomes a candidate for backing sharing (i.e. layers later
// in paint order, with the same stacking context ancestor, might be able to paint into it).
//
// We maintain multiple backing provider candidates in order to have backing sharing work with sibling or nested
// overflow scrollers. When traversing layers that might be able to share with these providers, this is essentially
// a bucketing process. There are three cases to consider here:
//
// 1. Sibling scrollers that don't overlap:
//    In this case we can simply add later layers to the appropriate scroller (using scrolling scope to find the right one),
//    since we know that we're traversing those layers in paint order and the scrollers don't overlap. Aswe assign layers to
//    one or other candidate, paint order will be preserved. This is supported.
//
// 2. Sibling scrollers that overlap:
//    Here we can have layers share with the on-top scroller, but have to ensure that layers scrolled by the below scroller
//    correctly overlap the border/background of the on-top scroller (i.e. they can't use sharing). So we can only do sharing
//    with the last scroller. This is not currently supported.
//
// 3. Nested scrollers:
//    Similar to overlapping scrollers, we have to ensure that we add to the right provider (looking a scrolling scope),
//    and don't break overlap with the nested scroller. This is not currently supported.
//
// We also track additional backing sharing providers that aren't clipped scrollers. These cannot be added to, since that could expand the
// bounds of the resulting layer.
// They are tracked so we can check them for overlap, and continue to add to the scroller backing sharing providers if the new content
// doesn't overlap.
//
// To debug sharing behavior, enable the "Compositing" log channel and look for the P/p in the hierarchy output.

private struct BackingSharingProvider {
    var providerLayer: WebCore.RenderLayer
    // In paint order; a layer is added at most once in a compositing update.
    var sharingLayers: [WebCore.RenderLayer] = []
    var absoluteBounds: WebCore.LayoutRect
}

private struct BackingSharingSnapshot {
    var sequenceIdentifier: UInt64
    var providerCount: Int
}

private struct BackingSharingState {
    var backingProviderCandidates: [BackingSharingProvider] = []
    var backingSharingStackingContext: WebCore.RenderLayer? = nil
    // Identifies a sharing sequence within one compositing update; snapshots compare it.
    var sequenceIdentifier: UInt64 = 1
    // Layers that would repaint into a layer in a provider's sharing layers.
    // That repaint has to wait until we've set the provider's backing-sharing layers.
    var layersPendingRepaint: [WebCore.RenderLayer] = []

    mutating func addLayerNeedingRepaint(_ layer: WebCore.RenderLayer) {
        if !layersPendingRepaint.contains(where: { isSameRenderLayer($0, layer) }) {
            layersPendingRepaint.append(layer)
        }
    }

    mutating func startBackingSharingSequence(
        _ candidateLayer: WebCore.RenderLayer,
        _ candidateAbsoluteBounds: WebCore.LayoutRect,
        _ candidateStackingContext: WebCore.RenderLayer
    ) {
        assert(backingSharingStackingContext == nil)
        assert(backingProviderCandidates.isEmpty)
        backingProviderCandidates.append(BackingSharingProvider(providerLayer: candidateLayer, absoluteBounds: candidateAbsoluteBounds))
        backingSharingStackingContext = candidateStackingContext
    }

    mutating func addBackingSharingCandidate(
        _ candidateLayer: WebCore.RenderLayer,
        _ candidateAbsoluteBounds: WebCore.LayoutRect,
        _ candidateStackingContext: WebCore.RenderLayer,
        _ backingSharingSnapshot: BackingSharingSnapshot?
    ) {
        assert(isSameRenderLayer(backingSharingStackingContext, candidateStackingContext))
        assert(!backingProviderCandidates.contains(where: { isSameRenderLayer($0.providerLayer, candidateLayer) }))

        // Inserts candidateLayer into the provider list in z-order, using the state snapshot that
        // was taken before any descendant layers were traversed.
        let candidate = BackingSharingProvider(providerLayer: candidateLayer, absoluteBounds: candidateAbsoluteBounds)
        if let backingSharingSnapshot, sequenceIdentifier == backingSharingSnapshot.sequenceIdentifier {
            // Otherwise insert it at the position captured in the snapshot
            backingProviderCandidates.insert(candidate, at: backingSharingSnapshot.providerCount)
        } else {
            // If a new sharing sequence has been started since the snapshot was taken, then this candidate
            // will be before any of the current ones in z-order (which must have been added by descendants of this layer).
            backingProviderCandidates.insert(candidate, at: 0)
        }
    }

    mutating func endBackingSharingSequence(_ endLayer: WebCore.RenderLayer) {
        assert(backingSharingStackingContext != nil)

        let candidates = backingProviderCandidates
        backingProviderCandidates = []

        for candidate in candidates {
            var sharingLayers = WebCore.RenderLayerWeakList()
            for layer in candidate.sharingLayers where !isSameRenderLayer(layer, endLayer) {
                sharingLayers.append(layer)
            }
            candidate.providerLayer.backing()!.setBackingSharingLayersForSwift(sharingLayers)
        }
        backingSharingStackingContext = nil
        // An unsigned identifier, which wraps.
        sequenceIdentifier &+= 1

        issuePendingRepaints()
    }

    func backingProviderCandidateForLayer(
        _ layer: WebCore.RenderLayer,
        _ compositor: WebCore.RenderLayerCompositor,
        _ overlapMap: OverlapMapContext,
        _ overlap: inout OverlapExtent
    ) -> Int? {
        if layer.hasReflection() {
            return nil
        }

        if backingProviderCandidates.isEmpty {
            return nil
        }

        // First, find the frontmost provider that is an ancestor in the containing block chain.
        guard
            let candidateIndex = backingProviderCandidates.lastIndex(where: { provider in
                let providerLayer = provider.providerLayer
                if isSameRenderLayer(layer, providerLayer) {
                    return false
                }
                return layer.ancestorLayerIsInContainingBlockChain(providerLayer, nil)
            })
        else {
            return nil
        }

        let candidate = backingProviderCandidates[candidateIndex]

        // Only allow adding to providers that clip their descendants, unless there's only a single provider.
        // Unclipped providers in-front are tracked for overlap testing only.
        // FIXME: We could accumulate the union of the overlap bounds for a provider and its sharing layers to avoid this restriction.
        if backingProviderCandidates.count > 1 && !candidate.providerLayer.canUseCompositedScrolling() {
            return nil
        }

        if candidateIndex == backingProviderCandidates.count - 1 {
            // No other provider is in front of the candidate, so no need to check for overlap.
            return candidateIndex
        }

        let providerLayer = candidate.providerLayer
        var overlapBounds = candidate.absoluteBounds
        if let scrollableArea = providerLayer.scrollableArea(), providerLayer.canUseCompositedScrolling(),
            scrollableArea.hasScrollableHorizontalOverflow() != scrollableArea.hasScrollableVerticalOverflow()
        {
            // If the provider uses composited scrolling but only supports scrolling
            // in one axis, we can use the clipped overlap bounds in the other axis,
            // when checking for overlap.
            let clippedOverlapBounds = compositor.computeClippedOverlapBounds(overlapMap, layer, &overlap)
            if scrollableArea.hasScrollableHorizontalOverflow() {
                overlapBounds.setY(clippedOverlapBounds.y())
                overlapBounds.setHeight(clippedOverlapBounds.height())
            } else {
                overlapBounds.setX(clippedOverlapBounds.x())
                overlapBounds.setWidth(clippedOverlapBounds.width())
            }
        }

        // Check if any of the other candidates that are in front of the selected provider will
        // overlap the bounds of the layer to be added.
        for provider in backingProviderCandidates[(candidateIndex + 1)...] {
            if overlapBounds.intersects(provider.absoluteBounds) {
                return nil
            }
        }

        return candidateIndex
    }

    func existingBackingProviderCandidateForLayer(_ layer: WebCore.RenderLayer) -> Int? {
        assert(layer.paintsIntoProvidedBacking())
        let backingProviderLayer = layer.backingProviderLayer()
        return backingProviderCandidates.firstIndex(where: { isSameRenderLayer(backingProviderLayer, $0.providerLayer) })
    }

    func hasBackingProviderForLayer(_ layer: WebCore.RenderLayer) -> Bool {
        backingProviderCandidates.contains(where: { provider in provider.sharingLayers.contains(where: { isSameRenderLayer($0, layer) }) })
    }

    func isAdditionalProviderCandidate(_ stackingContextAncestor: WebCore.RenderLayer?) -> Bool {
        assert(!backingProviderCandidates.isEmpty)
        guard let stackingContextAncestor, isSameRenderLayer(stackingContextAncestor, backingSharingStackingContext) else {
            return false
        }

        if !backingProviderCandidates[0].providerLayer.canUseCompositedScrolling() {
            return false
        }

        if backingProviderCandidates.count >= 10 {
            return false
        }
        return true
    }

    func snapshot() -> BackingSharingSnapshot? {
        if backingSharingStackingContext == nil {
            return nil
        }
        return BackingSharingSnapshot(sequenceIdentifier: sequenceIdentifier, providerCount: backingProviderCandidates.count)
    }

    private mutating func issuePendingRepaints() {
        let layers = layersPendingRepaint
        layersPendingRepaint = []
        for layer in layers {
            layer.compositingStatusChangedForCompositor(.Yes)
            layer.compositor().repaintOnCompositingChange(layer, layer.repaintContainer())
        }
    }
}

// Unchanged leaf compositing layers that clip their descendants can skip descendant
// traversal, since their descendants can't contribute any new overlap to the map.
private func canSkipComputeCompositingRequirementsForSubtree(_ layer: WebCore.RenderLayer, _ willBeComposited: Bool) -> Bool {
    if layer.needsCompositingRequirementsTraversal() || layer.hasDescendantNeedingCompositingRequirementsTraversal() {
        return false
    }

    if !layer.isComposited() || !willBeComposited || layer.hasCompositingDescendant() || !layer.isStackingContext() {
        return false
    }

    return layer.renderer().hasNonVisibleOverflow()
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func computeCompositingRequirements(
        _ rootLayer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer,
        _ geometryMap: WebCore.RenderGeometryMapView
    ) {
        computeCompositingRequirementsFromRoot(rootLayer, compositingAncestor, geometryMap)
    }

    private func computeCompositingRequirementsFromRoot(
        _ rootLayer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer,
        _ geometryMap: WebCore.RenderGeometryMapView
    ) {
        let overlapMap = OverlapMapContext(geometryMap, CompositingOverlapMap(rootLayer))
        var compositingState = CompositingState(compositingAncestor)
        var backingSharingState = BackingSharingState()
        computeCompositingRequirements(nil, rootLayer, overlapMap, &compositingState, &backingSharingState)
    }

    private func updateRepaintRectsAfterCompositingChange(
        _ layer: WebCore.RenderLayer,
        _ wasComposited: Bool,
        _ backingSharingState: inout BackingSharingState
    ) {
        // Repaint rects (and the repaint container) are cached relative to the repaint container, so they
        // must be recomputed when compositing status changes.

        // Repaint in the old container before we recompute the repaint container.
        if !wasComposited, let repaintContainer = layer.repaintContainer(), repaintContainer.isComposited() {
            repaintOnCompositingChange(layer, repaintContainer)
        }

        // Compute the new repaint container and repaint in it, unless newly compositing (a new
        // compositing layer fully repaints anyway).
        if !layer.isComposited() {
            // Defer until backing sharing completes, since repaint container computation needs all that
            // state in place.
            if layerRepaintTargetsBackingSharingLayer(layer, backingSharingState) {
                backingSharingState.addLayerNeedingRepaint(layer)
            } else {
                layer.compositingStatusChangedForCompositor(.Yes)
                repaintOnCompositingChange(layer, layer.repaintContainer())
            }
        } else {
            layer.compositingStatusChangedForCompositor(.Yes)
        }
    }

    private func layerRepaintTargetsBackingSharingLayer(_ layer: WebCore.RenderLayer, _ sharingState: borrowing BackingSharingState) -> Bool
    {
        if sharingState.backingProviderCandidates.isEmpty {
            return false
        }

        var currLayer: WebCore.RenderLayer? = layer
        while let current = currLayer {
            if WebCore.compositedWithOwnBackingStore(current) {
                return false
            }

            if current.paintsIntoProvidedBacking() {
                return false
            }

            if sharingState.hasBackingProviderForLayer(current) {
                return true
            }
            currLayer = current.paintOrderParent()
        }

        return false
    }

    private func computeCompositingRequirements(
        _ ancestorLayer: WebCore.RenderLayer?,
        _ layer: WebCore.RenderLayer,
        _ overlapMap: OverlapMapContext,
        _ compositingState: inout CompositingState,
        _ backingSharingState: inout BackingSharingState
    ) {
        layer.updateDescendantDependentFlags()
        layer.updateLayerListsIfNeeded()

        if !layer.hasDescendantNeedingCompositingRequirementsTraversal()
            && !layer.needsCompositingRequirementsTraversal()
            && !compositingState.fullPaintOrderTraversalRequired
            && !compositingState.descendantsRequireCompositingUpdate
        {
            traverseUnchangedSubtree(ancestorLayer, layer, overlapMap, &compositingState, &backingSharingState)
            return
        }

        // FIXME: maybe we can avoid updating all remaining layers in paint order.
        compositingState.fullPaintOrderTraversalRequired =
            compositingState.fullPaintOrderTraversalRequired || layer.needsCompositingRequirementsTraversal()
        compositingState.descendantsRequireCompositingUpdate =
            compositingState.descendantsRequireCompositingUpdate || layer.descendantsNeedCompositingRequirementsTraversal()

        // We updated compositing for direct reasons in layerStyleChanged(). Here, check for compositing that can only be evaluated after
        // layout.
        var queryData = WebCore.RenderLayerCompositor.RequiresCompositingData()
        let wasComposited = layer.isComposited()
        var willBeComposited = wasComposited
        var becameCompositedAfterDescendantTraversal = false
        var compositingReason: WebCore.IndirectCompositingReason = compositingState.subtreeIsCompositing ? .Stacking : .None

        if layer.needsPostLayoutCompositingUpdate() || compositingState.fullPaintOrderTraversalRequired
            || compositingState.descendantsRequireCompositingUpdate
        {
            layer.setIndirectCompositingReasonForCompositor(.None)
            willBeComposited = needsToBeComposited(layer, &queryData)
        }

        compositingState.fullPaintOrderTraversalRequired =
            compositingState.fullPaintOrderTraversalRequired || layer.subsequentLayersNeedCompositingRequirementsTraversal()

        var layerExtent = OverlapExtent()

        // Use the fact that we're composited as a hint to check for an animating transform.
        // FIXME: Maybe needsToBeComposited() should return a bitmask of reasons, to avoid the need to recompute things.
        if willBeComposited && !layer.isRenderViewLayer() {
            layerExtent.hasTransformAnimation = isRunningTransformAnimation(layer.renderer())
        }

        let respectTransforms = !layerExtent.hasTransformAnimation
        overlapMap.pushMappingsToAncestor(layer, ancestorLayer, respectTransforms)

        var providedBackingLayer: WebCore.RenderLayer? = nil
        if !willBeComposited && compositingState.subtreeIsCompositing && canBeComposited(layer) {
            if let providerIndex = backingSharingState.backingProviderCandidateForLayer(layer, self, overlapMap, &layerExtent) {
                backingSharingState.backingProviderCandidates[providerIndex].sharingLayers.append(layer)
                compositingReason = .None
                providedBackingLayer = backingSharingState.backingProviderCandidates[providerIndex].providerLayer
            }
        }

        // If we know for sure the layer is going to be composited, don't bother looking it up in the overlap map
        if !willBeComposited && providedBackingLayer == nil && !overlapMap.isEmpty() && compositingState.testingOverlap {
            // If we're testing for overlap, we only need to composite if we overlap something that is already composited.
            if layerOverlaps(overlapMap, layer, &layerExtent) {
                compositingReason = .Overlap
            } else {
                compositingReason = .None
            }
        }

        // Video is special. It's the only RenderLayer type that can both have
        // RenderLayer children and whose children can't use its backing to render
        // into. These children (the controls) always need to be promoted into their
        // own layers to draw on top of the accelerated video.
        if let compositingAncestor = compositingState.compositingAncestor, compositingAncestor.renderer().isRenderVideo() {
            compositingReason = .Overlap
        }

        if compositingReason != .None {
            layer.setIndirectCompositingReasonForCompositor(compositingReason)
        }

        // Check if the computed indirect reason will force the layer to become composited.
        if !willBeComposited && layer.mustCompositeForIndirectReasonsForCompositor() && canBeComposited(layer) {
            willBeComposited = true
            providedBackingLayer = nil
        }

        // The children of this layer don't need to composite, unless there is
        // a compositing layer among them, so start by inheriting the compositing
        // ancestor with subtreeIsCompositing set to false.
        var currentState = compositingState.stateForPaintOrderChildren(layer)
        var didPushOverlapContainer = false

        func layerWillComposite() {
            // This layer is going to be composited, so children can safely ignore the fact that there's an
            // animation running behind this layer, meaning they can rely on the overlap map testing again.
            currentState.testingOverlap = true
            // This layer now acts as the ancestor for kids.
            currentState.compositingAncestor = layer
            // Compositing turns off backing sharing.
            currentState.backingSharingAncestor = nil

            if providedBackingLayer != nil {
                providedBackingLayer = nil
                // providedBackingLayer was only valid for layers that would otherwise composite because of overlap. If we can
                // no longer share, put this this indirect reason back on the layer so that requiresOwnBackingStore() sees it.
                layer.setIndirectCompositingReasonForCompositor(.Overlap)
            } else {
                if !didPushOverlapContainer {
                    overlapMap.pushCompositingContainer(layer)
                    didPushOverlapContainer = true
                }
            }

            willBeComposited = true
        }

        // Unless we leave the containing block chain, or have an animated transform,
        // then we can continue to use the inherited backing store attachment.
        var allowsBackingStoreDetachingForFixed = false
        if currentState.ancestorAllowsBackingStoreDetachingForFixed, let ancestorLayer,
            layer.ancestorLayerIsInContainingBlockChain(ancestorLayer, nil), !layerExtent.hasTransformAnimation
        {
            allowsBackingStoreDetachingForFixed = true
        }

        func layerWillCompositePostDescendants() {
            layerWillComposite()
            currentState.subtreeIsCompositing = true
            becameCompositedAfterDescendantTraversal = true
            if layer.behavesAsFixed() {
                allowsBackingStoreDetachingForFixed = allowBackingStoreDetachingForFixedPosition(layer, layerExtent.bounds)
            }
        }

        if willBeComposited {
            layerWillComposite()

            computeExtent(overlapMap, layer, &layerExtent)
            currentState.ancestorHasTransformAnimation = currentState.ancestorHasTransformAnimation || layerExtent.hasTransformAnimation

            if !allowsBackingStoreDetachingForFixed && layer.behavesAsFixed() {
                allowsBackingStoreDetachingForFixed = allowBackingStoreDetachingForFixedPosition(layer, layerExtent.bounds)
                currentState.ancestorAllowsBackingStoreDetachingForFixed = allowsBackingStoreDetachingForFixed
            }

            // Too hard to compute animated bounds if both us and some ancestor is animating transform.
            layerExtent.animationCausesExtentUncertainty =
                layerExtent.animationCausesExtentUncertainty
                || (layerExtent.hasTransformAnimation && compositingState.ancestorHasTransformAnimation)
        } else if providedBackingLayer != nil {
            currentState.backingSharingAncestor = layer
            overlapMap.pushCompositingContainer(layer)
            didPushOverlapContainer = true
        }

        let backingSharingSnapshot = updateBackingSharingBeforeDescendantTraversal(
            &backingSharingState,
            overlapMap,
            layer,
            &layerExtent,
            willBeComposited,
            compositingState.stackingContextAncestor
        )

        layer.withLayerListMutationForbidden {
            let descendantsAddedToOverlap = currentState.hasNonRootCompositedAncestor

            if !canSkipComputeCompositingRequirementsForSubtree(layer, willBeComposited) {
                if layer.paintOrderListCount(.Negative) > 0 {
                    // Speculatively push this layer onto the overlap map.
                    var didSpeculativelyPushOverlapContainer = false
                    if !didPushOverlapContainer {
                        overlapMap.pushSpeculativeCompositingContainer(layer)
                        didPushOverlapContainer = true
                        didSpeculativelyPushOverlapContainer = true
                    }

                    var index = 0
                    while index < layer.paintOrderListCount(.Negative) {
                        let childLayer = layer.paintOrderListLayer(.Negative, index)
                        computeCompositingRequirements(layer, childLayer, overlapMap, &currentState, &backingSharingState)

                        // If we have to make a layer for this child, make one now so we can have a contents layer
                        // (since we need to ensure that the -ve z-order child renders underneath our contents).
                        if !willBeComposited && currentState.subtreeIsCompositing {
                            layer.setIndirectCompositingReasonForCompositor(.BackgroundLayer)
                            layerWillComposite()
                            overlapMap.confirmSpeculativeCompositingContainer()
                        }
                        index += 1
                    }

                    if didSpeculativelyPushOverlapContainer {
                        if overlapMap.maybePopSpeculativeCompositingContainer() {
                            didPushOverlapContainer = false
                        } else if !willBeComposited {
                            layer.setIndirectCompositingReasonForCompositor(.BackgroundLayer)
                            layerWillComposite()
                        }
                    }
                }

                var index = 0
                while index < layer.paintOrderListCount(.NormalFlow) {
                    computeCompositingRequirements(
                        layer,
                        layer.paintOrderListLayer(.NormalFlow, index),
                        overlapMap,
                        &currentState,
                        &backingSharingState
                    )
                    index += 1
                }

                index = 0
                while index < layer.paintOrderListCount(.Positive) {
                    computeCompositingRequirements(
                        layer,
                        layer.paintOrderListLayer(.Positive, index),
                        overlapMap,
                        &currentState,
                        &backingSharingState
                    )
                    index += 1
                }

                // Set the flag to say that this layer has compositing children.
                layer.setHasCompositingDescendantForCompositor(currentState.subtreeIsCompositing)
                layer.setHasCompositedNonContainedDescendantsForCompositor(currentState.hasCompositedNonContainedDescendants)
            }

            // If we just entered compositing mode, the root will have become composited (as long as accelerated compositing is enabled).
            if layer.isRenderViewLayer() {
                if usesCompositing() && m_hasAcceleratedCompositing {
                    willBeComposited = true
                }
            }

            let isolatedCompositedBlending = layer.isolatesCompositedBlending()
            layer.setHasNotIsolatedCompositedBlendingDescendants(currentState.hasNotIsolatedCompositedBlendingDescendants)
            if layer.isolatesCompositedBlending() != isolatedCompositedBlending {
                // isolatedCompositedBlending affects the result of clippedByAncestor().
                layer.setChildrenNeedCompositingGeometryUpdate()
            }

            assert(!layer.hasNotIsolatedCompositedBlendingDescendants() || layer.hasNotIsolatedBlendingDescendants())

            let isBackdropRoot = layer.isBackdropRoot()
            layer.setHasBackdropFilterDescendantsWithoutRoot(currentState.hasBackdropFilterDescendantsWithoutRoot)
            if layer.isBackdropRoot() != isBackdropRoot {
                layer.setNeedsCompositingConfigurationUpdate()
            }

            // Now check for reasons to become composited that depend on the state of descendant layers.
            if !willBeComposited && canBeComposited(layer) {
                layer.update3DTransformedDescendantStatusForCompositor()
                let indirectReason = computeIndirectCompositingReason(
                    layer,
                    currentState.subtreeIsCompositing,
                    layer.has3DTransformedDescendantForCompositor(),
                    providedBackingLayer != nil
                )
                if indirectReason != .None {
                    layer.setIndirectCompositingReasonForCompositor(indirectReason)
                    layerWillCompositePostDescendants()
                }
            }

            if let reflectionLayer = layer.reflectionLayer() {
                // FIXME: Shouldn't we call computeCompositingRequirements to handle a reflection overlapping with another renderer?
                reflectionLayer.setIndirectCompositingReasonForCompositor(willBeComposited ? .Stacking : .None)
            }

            // If we're back at the root, and no other layers need to be composited, and the root layer itself doesn't need
            // to be composited, then we can drop out of compositing mode altogether. However, don't drop out of compositing mode
            // if there are composited layers that we didn't hit in our traversal (e.g. because of visibility:hidden).
            var rootLayerQueryData = WebCore.RenderLayerCompositor.RequiresCompositingData()
            if layer.isRenderViewLayer() && !currentState.subtreeIsCompositing && !requiresCompositingLayer(layer, &rootLayerQueryData)
                && !m_forceCompositingMode && !needsCompositingForContentOrOverlays()
            {
                // Don't drop out of compositing on iOS, because we may flash. See <rdar://problem/8348337>.
                #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) // !PLATFORM(IOS_FAMILY)
                enableCompositingMode(false)
                willBeComposited = false
                #endif
            }

            assert(willBeComposited == needsToBeComposited(layer, &queryData))

            if willBeComposited {
                addToWillChangeAreaEstimate(overlapMap, layer)
            }

            // Create or destroy backing here. However, we can't update geometry because layers above us may become composited
            // during post-order traversal (e.g. for clipping).
            var needsCompositingStatusUpdate = false
            if updateBacking(
                layer,
                &queryData,
                WebCore.UpdateBackingSharingFlagSet(.DuringCompositingUpdate),
                willBeComposited ? .yes : .no
            ) {
                // This layer and all of its descendants have cached repaints rects that are relative to
                // the repaint container, so change when compositing changes; we need to update them here,
                // as long as shared backing isn't going to change our repaint container.
                needsCompositingStatusUpdate = true
            }

            // Update layer state bits.
            if let reflectionLayer = layer.reflectionLayer(), updateReflectionCompositingState(reflectionLayer, layer, &queryData) {
                layer.setNeedsCompositingLayerConnection()
            }

            // FIXME: clarify needsCompositingPaintOrderChildrenUpdate. If a composited layer gets a new ancestor, it needs geometry
            // computations.
            if layer.needsCompositingPaintOrderChildrenUpdate() {
                layer.setChildrenNeedCompositingGeometryUpdate()
                layer.setNeedsCompositingLayerConnection()
            }

            layer.clearCompositingRequirementsTraversalState()

            // Compute state passed to the caller.
            compositingState.updateWithDescendantStateAndLayer(currentState, layer, ancestorLayer, layerExtent)
            updateBackingSharingAfterDescendantTraversal(
                &backingSharingState,
                overlapMap,
                layer,
                &layerExtent,
                compositingState.stackingContextAncestor,
                backingSharingSnapshot
            )

            if !isSameRenderLayer(layer.backingProviderLayerAtEndOfCompositingUpdate(), providedBackingLayer) {
                needsCompositingStatusUpdate = true
            }

            // Update the cached repaint rects now that we've finished updating backing
            // sharing state on descendants
            if needsCompositingStatusUpdate {
                updateRepaintRectsAfterCompositingChange(layer, wasComposited, &backingSharingState)
            }

            layer.setBackingProviderLayerAtEndOfCompositingUpdate(providedBackingLayer)

            let layerContributesToOverlap = currentState.hasNonRootCompositedAncestor || currentState.backingSharingAncestor != nil
            updateOverlapMap(
                overlapMap,
                layer,
                &layerExtent,
                didPushOverlapContainer,
                layerContributesToOverlap,
                becameCompositedAfterDescendantTraversal && !descendantsAddedToOverlap
            )

            if layer.isComposited() {
                layer.backing()!.updateAllowsBackingStoreDetaching(allowsBackingStoreDetachingForFixed)
            }

            overlapMap.popMappingsToAncestor(ancestorLayer)
        }
    }

    // We have to traverse unchanged layers to fill in the overlap map.
    private func traverseUnchangedSubtree(
        _ ancestorLayer: WebCore.RenderLayer?,
        _ layer: WebCore.RenderLayer,
        _ overlapMap: OverlapMapContext,
        _ compositingState: inout CompositingState,
        _ backingSharingState: inout BackingSharingState
    ) {
        layer.updateDescendantDependentFlags()
        layer.updateLayerListsIfNeeded()

        assert(!compositingState.fullPaintOrderTraversalRequired)
        assert(!layer.hasDescendantNeedingCompositingRequirementsTraversal())
        assert(!layer.needsCompositingRequirementsTraversal())

        let layerIsComposited = layer.isComposited()
        var layerPaintsIntoProvidedBacking = false
        var didPushOverlapContainer = false

        var layerExtent = OverlapExtent()
        if layerIsComposited && !layer.isRenderViewLayer() {
            layerExtent.hasTransformAnimation = isRunningTransformAnimation(layer.renderer())
        }

        let respectTransforms = !layerExtent.hasTransformAnimation
        overlapMap.pushMappingsToAncestor(layer, ancestorLayer, respectTransforms)

        // If we know for sure the layer is going to be composited, don't bother looking it up in the overlap map
        if !layerIsComposited && !overlapMap.isEmpty() && compositingState.testingOverlap {
            computeExtent(overlapMap, layer, &layerExtent)
        }

        if layer.paintsIntoProvidedBacking() {
            // A layer that paints into provided backing has its provider among the candidates.
            guard let providerIndex = backingSharingState.existingBackingProviderCandidateForLayer(layer) else {
                preconditionFailure()
            }
            if WebCore.RenderLayerCompositor.securityAssertionsEnabled() {
                precondition(providerIndex == backingSharingState.backingProviderCandidateForLayer(layer, self, overlapMap, &layerExtent))
            }
            backingSharingState.backingProviderCandidates[providerIndex].sharingLayers.append(layer)
            layerPaintsIntoProvidedBacking = true
        }

        var currentState = compositingState.stateForPaintOrderChildren(layer)

        if layerIsComposited {
            // This layer is going to be composited, so children can safely ignore the fact that there's an
            // animation running behind this layer, meaning they can rely on the overlap map testing again.
            currentState.testingOverlap = true
            // This layer now acts as the ancestor for kids.
            currentState.compositingAncestor = layer
            currentState.backingSharingAncestor = nil
            overlapMap.pushCompositingContainer(layer)
            didPushOverlapContainer = true

            computeExtent(overlapMap, layer, &layerExtent)
            addToWillChangeAreaEstimate(overlapMap, layer)
            currentState.ancestorHasTransformAnimation = currentState.ancestorHasTransformAnimation || layerExtent.hasTransformAnimation
            // Too hard to compute animated bounds if both us and some ancestor is animating transform.
            layerExtent.animationCausesExtentUncertainty =
                layerExtent.animationCausesExtentUncertainty
                || (layerExtent.hasTransformAnimation && compositingState.ancestorHasTransformAnimation)
        } else if layerPaintsIntoProvidedBacking {
            overlapMap.pushCompositingContainer(layer)
            currentState.backingSharingAncestor = layer
            didPushOverlapContainer = true
        }

        let backingSharingSnapshot = updateBackingSharingBeforeDescendantTraversal(
            &backingSharingState,
            overlapMap,
            layer,
            &layerExtent,
            layerIsComposited,
            compositingState.stackingContextAncestor
        )

        layer.withLayerListMutationForbidden {
            if !canSkipComputeCompositingRequirementsForSubtree(layer, layerIsComposited) {
                var index = 0
                while index < layer.paintOrderListCount(.Negative) {
                    traverseUnchangedSubtree(
                        layer,
                        layer.paintOrderListLayer(.Negative, index),
                        overlapMap,
                        &currentState,
                        &backingSharingState
                    )
                    assert(!currentState.subtreeIsCompositing || layerIsComposited)
                    index += 1
                }

                index = 0
                while index < layer.paintOrderListCount(.NormalFlow) {
                    traverseUnchangedSubtree(
                        layer,
                        layer.paintOrderListLayer(.NormalFlow, index),
                        overlapMap,
                        &currentState,
                        &backingSharingState
                    )
                    index += 1
                }

                index = 0
                while index < layer.paintOrderListCount(.Positive) {
                    traverseUnchangedSubtree(
                        layer,
                        layer.paintOrderListLayer(.Positive, index),
                        overlapMap,
                        &currentState,
                        &backingSharingState
                    )
                    index += 1
                }

                // Set the flag to say that this layer has compositing children.
                assert(layer.hasCompositingDescendant() == currentState.subtreeIsCompositing)
                assert(!(canBeComposited(layer) && WebCore.RenderLayerCompositor.clipsCompositingDescendants(layer)) || layerIsComposited)
            }

            assert(!currentState.fullPaintOrderTraversalRequired)
            compositingState.updateWithDescendantStateAndLayer(currentState, layer, ancestorLayer, layerExtent, isUnchangedSubtree: true)
            updateBackingSharingAfterDescendantTraversal(
                &backingSharingState,
                overlapMap,
                layer,
                &layerExtent,
                compositingState.stackingContextAncestor,
                backingSharingSnapshot
            )

            let layerContributesToOverlap = currentState.hasNonRootCompositedAncestor || currentState.backingSharingAncestor != nil
            updateOverlapMap(overlapMap, layer, &layerExtent, didPushOverlapContainer, layerContributesToOverlap)

            overlapMap.popMappingsToAncestor(ancestorLayer)

            assert(!layer.needsCompositingRequirementsTraversal())
        }
    }

    private func updateBackingSharingBeforeDescendantTraversal(
        _ sharingState: inout BackingSharingState,
        _ overlapMap: OverlapMapContext,
        _ layer: WebCore.RenderLayer,
        _ layerExtent: inout OverlapExtent,
        _ willBeComposited: Bool,
        _ stackingContextAncestor: WebCore.RenderLayer?
    ) -> BackingSharingSnapshot? {
        layer.setBackingProviderLayer(nil, WebCore.UpdateBackingSharingFlagSet(.DuringCompositingUpdate))

        let shouldEndSharingSequence = { () -> Bool in
            if sharingState.backingSharingStackingContext == nil {
                return false
            }

            if !willBeComposited {
                return false
            }

            // If this layer is composited, we can only continue the sequence if it's a new provider candidate.
            // FIXME: Can this computeExtent() call be removed?
            computeExtent(overlapMap, layer, &layerExtent)
            return !sharingState.isAdditionalProviderCandidate(stackingContextAncestor)
        }()

        // A layer that composites resets backing-sharing, since subsequent layers need to composite to overlap it.
        if shouldEndSharingSequence {
            sharingState.endBackingSharingSequence(layer)
        }

        return sharingState.snapshot()
    }

    private func updateBackingSharingAfterDescendantTraversal(
        _ sharingState: inout BackingSharingState,
        _ overlapMap: OverlapMapContext,
        _ layer: WebCore.RenderLayer,
        _ layerExtent: inout OverlapExtent,
        _ stackingContextAncestor: WebCore.RenderLayer?,
        _ backingSharingSnapshot: BackingSharingSnapshot?
    ) {
        if layer.isComposited() {
            // If this layer is being composited, clean up sharing-related state.
            layer.disconnectFromBackingProviderLayer(WebCore.UpdateBackingSharingFlagSet(.DuringCompositingUpdate))
            for index in sharingState.backingProviderCandidates.indices {
                sharingState.backingProviderCandidates[index].sharingLayers.removeAll(where: { isSameRenderLayer($0, layer) })
            }
        }

        // Backing sharing is constrained to layers in the same stacking context.
        if isSameRenderLayer(layer, sharingState.backingSharingStackingContext) {
            assert(!sharingState.backingProviderCandidates.contains(where: { isSameRenderLayer($0.providerLayer, layer) }))
            sharingState.endBackingSharingSequence(layer)

            if layer.isComposited() {
                layer.backing()!.clearBackingSharingLayers(WebCore.UpdateBackingSharingFlagSet(.DuringCompositingUpdate))
            }

            return
        }

        if !layer.isComposited() {
            return
        }

        guard let stackingContextAncestor else {
            return
        }

        let canBeBackingProvider = !layer.hasCompositingDescendant()
        if canBeBackingProvider {
            if sharingState.backingSharingStackingContext == nil {
                computeExtent(overlapMap, layer, &layerExtent)
                sharingState.startBackingSharingSequence(layer, layerExtent.bounds, stackingContextAncestor)
                return
            }

            computeExtent(overlapMap, layer, &layerExtent)
            if sharingState.isAdditionalProviderCandidate(stackingContextAncestor) {
                sharingState.addBackingSharingCandidate(layer, layerExtent.bounds, stackingContextAncestor, backingSharingSnapshot)
                return
            }
        }

        layer.backing()!.clearBackingSharingLayers(WebCore.UpdateBackingSharingFlagSet(.DuringCompositingUpdate))

        // A layer that composites resets backing-sharing, since subsequent layers need to composite to overlap it. If a descendant didn't
        // already end the sharing sequence that was current when processing of this layer started, end it now.
        if let backingSharingSnapshot, backingSharingSnapshot.sequenceIdentifier == sharingState.sequenceIdentifier {
            sharingState.endBackingSharingSequence(layer)
        }
    }

    // MARK: Overlap

    private func computeExtent(_ overlapMap: OverlapMapContext, _ layer: WebCore.RenderLayer, _ extent: inout OverlapExtent) {
        if extent.extentComputed {
            return
        }

        defer { extent.extentComputed = true }

        var layerBounds = WebCore.LayoutRect()
        if extent.hasTransformAnimation {
            extent.animationCausesExtentUncertainty = !layer.getOverlapBoundsIncludingChildrenAccountingForTransformAnimations(
                &layerBounds,
                WebCore.RenderLayer.CalculateLayerBoundsFlags()
            )
        } else {
            layerBounds = layer.overlapBounds()
        }

        // In the animating transform case, we avoid double-accounting for the transform because
        // we told pushMappingsToAncestor() to ignore transforms earlier.
        extent.bounds = WebCore.enclosingLayoutRect(
            overlapMap.absoluteRect(
                WebCore.FloatRect(
                    layerBounds.x().toFloat(),
                    layerBounds.y().toFloat(),
                    layerBounds.width().toFloat(),
                    layerBounds.height().toFloat()
                )
            )
        )

        // Empty rects never intersect, but we need them to for the purposes of overlap testing.
        if extent.bounds.isEmpty() {
            extent.bounds.setSize(WebCore.LayoutSize(WebCore.LayoutUnit(Int32(1)), WebCore.LayoutUnit(Int32(1))))
        }

        extent.bounds = overlapExtentForPositionedRenderer(layer, extent.bounds)
    }

    private func computeClippingScopes(_ layer: WebCore.RenderLayer, _ extent: inout OverlapExtent) {
        if extent.clippingScopesComputed {
            return
        }

        // FIXME: constrain the scopes (by composited stacking context ancestor I think).
        let rootLayer = rootRenderLayer()
        var enclosingScopes: [OverlapMapScope] = []
        var innermostScopeLayer: WebCore.RenderLayer? = nil

        if layer.hasCompositedScrollingAncestor() {
            // The ancestors in the containing block chain that have composited scrolling, leaves first, as traverseRenderLayerAncestors()
            // visits them.
            var positioningBehavior = layer.renderer()[.Style].position()
            var ancestor = layer.parent()
            while let ancestorLayer = ancestor {
                var inContainingBlockChain = true
                switch positioningBehavior {
                case .Absolute:
                    inContainingBlockChain = ancestorLayer.renderer().canContainAbsolutelyPositionedObjectsForSwift()
                case .Fixed:
                    inContainingBlockChain = ancestorLayer.renderer().canContainFixedPositionObjectsForSwift()
                default:
                    break
                }

                if inContainingBlockChain && ancestorLayer.hasCompositedScrollableOverflow() {
                    var clipRect = WebCore.LayoutRect()
                    if let box = ancestorLayer.renderBox() {
                        // FIXME: This is expensive. Broken with transforms.
                        let offsetFromRoot = ancestorLayer.convertToLayerCoords(
                            rootLayer,
                            WebCore.LayoutPoint(),
                            WebCore.RenderLayer.DontAdjustForColumns
                        )
                        clipRect = box.overflowClipRect(offsetFromRoot, .IgnoreOverlayScrollbarSize, .BlockBackground)
                    }
                    enclosingScopes.append(OverlapMapScope(layer: WebCore.LayerRef(ancestorLayer), bounds: clipRect))
                    if innermostScopeLayer == nil {
                        innermostScopeLayer = ancestorLayer
                    }
                }

                if inContainingBlockChain {
                    positioningBehavior = ancestorLayer.renderer()[.Style].position()
                }
                ancestor = ancestorLayer.parent()
            }
        }

        // Order is roots to leaves.
        extent.clippingScopes.reserveCapacity(enclosingScopes.count + 1)
        extent.clippingScopes.append(OverlapMapScope(layer: WebCore.LayerRef(rootLayer), bounds: WebCore.LayoutRect()))
        extent.clippingScopes.append(contentsOf: enclosingScopes.reversed())
        extent.clippingScopeLayer = innermostScopeLayer ?? rootLayer
        extent.clippingScopesComputed = true
    }

    fileprivate func computeClippedOverlapBounds(
        _ overlapMap: OverlapMapContext,
        _ layer: WebCore.RenderLayer,
        _ extent: inout OverlapExtent
    ) -> WebCore.LayoutRect {
        computeExtent(overlapMap, layer, &extent)
        computeClippingScopes(layer, &extent)

        var clipRect: WebCore.LayoutRect
        if layer.hasCompositedScrollingAncestor() {
            // Compute a clip up to the composited scrolling ancestor, then convert it to absolute coordinates.
            let scopeLayer = extent.clippingScopeLayer!
            clipRect =
                layer.backgroundClipRect(
                    RenderLayerClipRectsContext(
                        passed: scopeLayer,
                        WebCore.PaintingClipRects,
                        WebCore.RenderLayer.ClipRectsOptions(.Temporary)
                    )
                )
                .rectValue()
            if !clipRect.isInfinite() {
                clipRect.setLocation(
                    scopeLayer.convertToLayerCoords(rootRenderLayer(), clipRect.location(), WebCore.RenderLayer.DontAdjustForColumns)
                )
            }
        } else {
            // FIXME: Incorrect for CSS regions.
            clipRect = layer.backgroundClipRect(RenderLayerClipRectsContext(rootRenderLayer(), WebCore.AbsoluteClipRects)).rectValue()
        }

        var clippedBounds = extent.bounds
        if !clipRect.isInfinite() {
            // With delegated page scaling, pageScaleFactor() is not applied by RenderView, so we should not scale here.
            if !delegatesScaling() {
                clipRect.scale(pageScaleFactor())
            }

            clippedBounds.intersect(clipRect)
        }

        return clippedBounds
    }

    private func addToOverlapMap(_ overlapMap: OverlapMapContext, _ layer: WebCore.RenderLayer, _ extent: inout OverlapExtent) {
        if layer.isRenderViewLayer() {
            return
        }

        computeExtent(overlapMap, layer, &extent)
        computeClippingScopes(layer, &extent)

        if overlapMap.isCoveredByRecentRects(extent.bounds, extent.clippingScopes) {
            return
        }

        let clippedBounds = computeClippedOverlapBounds(overlapMap, layer, &extent)
        overlapMap.add(layer, clippedBounds, extent.clippingScopes)
    }

    // A null ancestorLayer is an indication that 'layer' has already been pushed.
    private func addDescendantsToOverlapMapRecursive(
        _ overlapMap: OverlapMapContext,
        _ layer: WebCore.RenderLayer,
        _ ancestorLayer: WebCore.RenderLayer? = nil
    ) {
        if !canBeComposited(layer) {
            return
        }

        if let ancestorLayer {
            overlapMap.pushMappingsToAncestor(layer, ancestorLayer, true)

            var layerExtent = OverlapExtent()
            addToOverlapMap(overlapMap, layer, &layerExtent)
        }

        layer.withLayerListMutationForbidden {
            var index = 0
            while index < layer.paintOrderListCount(.Negative) {
                addDescendantsToOverlapMapRecursive(overlapMap, layer.paintOrderListLayer(.Negative, index), layer)
                index += 1
            }

            index = 0
            while index < layer.paintOrderListCount(.NormalFlow) {
                addDescendantsToOverlapMapRecursive(overlapMap, layer.paintOrderListLayer(.NormalFlow, index), layer)
                index += 1
            }

            index = 0
            while index < layer.paintOrderListCount(.Positive) {
                addDescendantsToOverlapMapRecursive(overlapMap, layer.paintOrderListLayer(.Positive, index), layer)
                index += 1
            }

            if let ancestorLayer {
                overlapMap.popMappingsToAncestor(ancestorLayer)
            }
        }
    }

    private func updateOverlapMap(
        _ overlapMap: OverlapMapContext,
        _ layer: WebCore.RenderLayer,
        _ layerExtent: inout OverlapExtent,
        _ didPushContainer: Bool,
        _ addLayerToOverlap: Bool,
        _ addDescendantsToOverlap: Bool = false
    ) {
        if addLayerToOverlap {
            addToOverlapMap(overlapMap, layer, &layerExtent)
        }

        if addDescendantsToOverlap {
            // If this is the first non-root layer to composite, we need to add all the descendants we already traversed to the overlap map.
            addDescendantsToOverlapMapRecursive(overlapMap, layer)
        }

        if didPushContainer {
            overlapMap.popCompositingContainer(layer)
        }
    }

    private func layerOverlaps(_ overlapMap: OverlapMapContext, _ layer: WebCore.RenderLayer, _ layerExtent: inout OverlapExtent) -> Bool {
        computeExtent(overlapMap, layer, &layerExtent)
        computeClippingScopes(layer, &layerExtent)

        return overlapMap.overlapsLayers(layer, layerExtent.bounds, layerExtent.clippingScopes)
    }
}

// Whether a composited descendant of a sticky layer keeps its geometry relative to that layer, and any
// scrolling tree state it owns, when only the sticky offset changes. If so, it needs no update for the move.
private func compositedDescendantFollowsStickyOffset(_ descendant: WebCore.RenderLayer) -> Bool {
    // Positioned against the viewport or a scrolling ancestor rather than the sticky element, with
    // scrolling tree constraints computed against the old offset.
    if descendant.renderer().isFixedPositioned() || descendant.renderer().isStickilyPositioned() {
        return false
    }

    // A composited scroller owns an overflow scrolling node, and layers inside it may own proxy or positioning
    // nodes for it, so be conservative and don't skip.
    if descendant.hasCompositedScrollableOverflow() {
        return false
    }

    return true
}

private func allCompositedDescendantsFollowStickyOffset(_ stickyLayer: WebCore.RenderLayer) -> Bool {
    // The sticky layer is a stacking context, so its paint-order lists reach every descendant layer, and
    // hasCompositingDescendant() (computed in paint order) lets the walk skip subtrees with nothing composited.
    var stack: [WebCore.RenderLayer] = [stickyLayer]
    while let layer = stack.popLast() {
        // The lists are rebuilt by the next compositing update; if they're dirty, don't skip.
        if layer.zOrderListsDirty() || layer.normalFlowListDirty() {
            return false
        }
        for list in [WebCore.PaintOrderList.Negative, .NormalFlow, .Positive] {
            var index = 0
            while index < layer.paintOrderListCount(list) {
                let child = layer.paintOrderListLayer(list, index)
                if child.isComposited() && !compositedDescendantFollowsStickyOffset(child) {
                    return false
                }
                if child.hasCompositingDescendant() {
                    stack.append(child)
                }
                index += 1
            }
        }
    }
    return true
}

extension WebCore.RenderLayerCompositor {
    func canSkipRequirementsTraversalForStickyOffsetChange(_ layer: WebCore.RenderLayer) -> Bool {
        if !layer.renderer().isStickilyPositioned() || !layer.isComposited() {
            return false
        }

        // This layer's own ancestor clip: a clip from above stays put while this layer moves, and its clipping
        // layers are recomputed by the configuration update that skipping would drop.
        if layer.backing()!.hasAncestorClippingLayers() {
            return false
        }

        // Skipping also drops the backing and hierarchy update of the enclosing stacking context, so only
        // this layer's own geometry is refreshed. That is enough for composited descendants that simply move
        // with it, but not for ones positioned or constrained against something that does not (the viewport
        // for a fixed descendant, the scrolling ancestor for a nested sticky one), or that own scrolling tree
        // nodes: those would be left stale.
        if layer.hasCompositingDescendant() && !allCompositedDescendantsFollowStickyOffset(layer) {
            return false
        }

        // computeExtent() covers all sticky positions, so a sticky offset change cannot affect overlap.
        if !isAsyncScrollableStickyLayerForSwift(layer) {
            return false
        }

        // Not when it sticks in a composited scroller (isAsyncScrollableStickyLayer's enclosing accelerated overflow layer).
        if let enclosingOverflowLayer = layer.enclosingOverflowClipLayer(WebCore.ExcludeSelf),
            enclosingOverflowLayer.hasCompositedScrollableOverflow()
        {
            return false
        }

        return true
    }
}

// Whether a layer needs backing, when the caller has decided it.
private enum BackingRequired {
    case no
    case yes
    case unknown
}

extension WebCore.RenderLayerCompositor {
    func layerGainedCompositedScrollableOverflow(_ layer: WebCore.RenderLayer) {
        var queryData = WebCore.RenderLayerCompositor.RequiresCompositingData()
        queryData.layoutUpToDate = .No

        updateExplicitBacking(layer, &queryData, .yes)

        guard let backing = layer.backing() else {
            return
        }

        backing.updateConfigurationAfterStyleChange()
    }

    // Make or destroy the backing for this layer; returns true if backing changed.
    @discardableResult
    private func updateExplicitBacking(
        _ layer: WebCore.RenderLayer,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData,
        _ backingRequiredArg: BackingRequired = .unknown
    ) -> Bool {
        var backingRequired = backingRequiredArg
        if backingRequired == .unknown {
            backingRequired = needsToBeComposited(layer, &queryData) ? .yes : .no
        } else {
            // Need to fetch viewportConstrainedNotCompositedReason, but without doing all the work that needsToBeComposited does.
            _ = requiresCompositingForPosition(rendererForCompositingTests(layer), layer, &queryData)
        }

        let hadBacking = layer.isComposited()
        if backingRequired == .yes {
            // If we need to repaint, do so before making backing and disconnecting from the backing provider layer.
            if layer.backing() == nil {
                repaintOnCompositingChange(layer, layer.repaintContainer())
            }
        }

        _ = updateBacking(layer, &queryData, WebCore.UpdateBackingSharingFlagSet(), backingRequired)

        if hadBacking != layer.isComposited() {
            layer.compositingStatusChangedForCompositor(queryData.layoutUpToDate)
        }

        if backingRequired == .no && hadBacking {
            repaintOnCompositingChange(layer, layer.repaintContainer())
        }

        return hadBacking != layer.isComposited()
    }

    private func updateBacking(
        _ layer: WebCore.RenderLayer,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData,
        _ updateBackingSharingFlags: WebCore.UpdateBackingSharingFlagSet,
        _ backingRequiredArg: BackingRequired
    ) -> Bool {
        var layerChanged = false
        var repaintRequired = false
        var backingRequired = backingRequiredArg
        if backingRequired == .unknown {
            backingRequired = needsToBeComposited(layer, &queryData) ? .yes : .no
        } else {
            // Need to fetch viewportConstrainedNotCompositedReason, but without doing all the work that needsToBeComposited does.
            _ = requiresCompositingForPosition(rendererForCompositingTests(layer), layer, &queryData)
        }

        if backingRequired == .yes {
            // If we need to repaint, do so before making backing and disconnecting from the backing provider layer.
            if layer.backing() == nil {
                repaintRequired = true
            }

            layer.disconnectFromBackingProviderLayer(updateBackingSharingFlags)

            enableCompositingMode(true)

            if layer.backing() == nil {
                createBacking(layer)

                layer.setNeedsCompositingGeometryUpdate()
                layer.setNeedsCompositingConfigurationUpdate()
                layer.setNeedsCompositingPaintOrderChildrenUpdate()

                layerChanged = true
            }
        } else {
            if layer.backing() != nil {
                // If we're removing backing on a reflection, clear the source GraphicsLayer's pointer to
                // its replica GraphicsLayer. In practice this should never happen because reflectee and reflection
                // are both either composited, or not composited.
                if layer.isReflection() {
                    clearReplicaLayerOfReflectionSource(layer)
                }

                layer.clearBacking(updateBackingSharingFlags, false)
                layerChanged = true

                // If we need to repaint, do so now that we've removed the backing.
                repaintRequired = true
            }
        }

        if layerChanged {
            rendererCompositingBackingChanged(layer)
            layer.clearClipRectsIncludingDescendants(WebCore.PaintingClipRects)
        }

        // If a fixed position layer gained/lost a backing or the reason not compositing it changed,
        // the scrolling coordinator needs to recalculate whether it can do fast scrolling.
        if layer.renderer().isFixedPositioned() {
            if layer.viewportConstrainedNotCompositedReason() != queryData.nonCompositedForPositionReason
                && !queryData.reevaluateAfterLayout
            {
                layer.setViewportConstrainedNotCompositedReason(queryData.nonCompositedForPositionReason)
                layerChanged = true
            }
            if layerChanged {
                frameViewFixedObjectsDidChange()
            }
        } else {
            layer.setViewportConstrainedNotCompositedReason(WebCore.RenderLayer.NoNotCompositedReason)
        }

        if let backing = layer.backing() {
            backing.updateDebugIndicators(m_showDebugBorders, m_showRepaintCounter)
        }

        if layerChanged {
            layer.setChildrenNeedCompositingGeometryUpdate()
            layer.setNeedsCompositingLayerConnection()
            layer.setSubsequentLayersNeedCompositingRequirementsTraversal()
            // Ancestor layers that composited for indirect reasons (things listed in styleChangeMayAffectIndirectCompositingReasons()) need
            // to get updated.
            // This could be optimized by only setting this flag on layers with the relevant styles.
            layer.setNeedsPostLayoutCompositingUpdateOnAncestors()

            // This change can make the layer start or stop being a composited child that splits its enclosing
            // SVG container, so re-run that container's segmentation.
            layer.invalidateEnclosingSVGContainerSegmentation()
        }

        return repaintRequired
    }

    private func updateReflectionCompositingState(
        _ layer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer?,
        _ queryData: inout WebCore.RenderLayerCompositor.RequiresCompositingData
    ) -> Bool {
        var layerChanged = updateExplicitBacking(layer, &queryData)

        // See if we need content or clipping layers. Methods called here should assume
        // that the compositing state of descendant layers has not been updated yet.
        if let backing = layer.backing(), backing.updateConfiguration(compositingAncestor) {
            layerChanged = true
        }

        return layerChanged
    }
}

private func styleDifference(_ diff: WebCore.Style.Difference, isAtLeast result: WebCore.Style.DifferenceResult) -> Bool {
    diff.result.rawValue >= result.rawValue
}

extension WebCore.RenderLayerCompositor {
    // The old style, when there is one, is the renderer's old style during its style change.
    func layerStyleChanged(_ diff: WebCore.Style.Difference, _ layer: WebCore.RenderLayer, _ hasOldStyle: Bool) {
        if diff.result == .Equal {
            return
        }

        // Create or destroy backing here so that code that runs during layout can reliably use isComposited() (though this
        // is only true for layers composited for direct reasons).
        // Also, it allows us to avoid a tree walk in updateCompositingLayers() when no layer changed its compositing state.
        var queryData = WebCore.RenderLayerCompositor.RequiresCompositingData()
        queryData.layoutUpToDate = .No

        updateExplicitBacking(layer, &queryData)
        layer.setIntrinsicallyCompositedForCompositor(queryData.intrinsic)

        if queryData.reevaluateAfterLayout {
            layer.setNeedsPostLayoutCompositingUpdate()
        }

        let renderer = layer.renderer()

        if hasContentCompositingLayers() {
            if styleDifference(diff, isAtLeast: .LayoutOutOfFlowMovementOnly) {
                layer.setNeedsPostLayoutCompositingUpdate()
                layer.setNeedsCompositingGeometryUpdate()
            }

            // The composited bounds of all descendents cover the region a pixel-moving filter samples, not just the nearest composted ones.
            if styleDifference(diff, isAtLeast: .Overflow) && hasOldStyle
                && WebCore.RenderLayerCompositor.filterOutsetsChanged(renderer[.OldStyle], renderer[.Style])
            {
                layer.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
            }

            if styleDifference(diff, isAtLeast: .Layout) {
                // FIXME: only set flags here if we know we have a composited descendant, but we might not know at this point.
                if hasOldStyle && WebCore.RenderLayerCompositor.clippingChanged(renderer[.OldStyle], renderer[.Style]) {
                    if layer.isStackingContext() {
                        layer.setNeedsPostLayoutCompositingUpdate() // Layer needs to become composited if it has composited descendants.
                        // If already composited, layer needs to create/destroy clipping layer.
                        layer.setNeedsCompositingConfigurationUpdate()
                        layer.setChildrenNeedCompositingGeometryUpdate() // Clipping layers on this layer affect descendant layer geometry.
                    } else {
                        // Descendant (in containing block order) compositing layers need to re-evaluate their clipping,
                        // but they might be siblings in z-order so go up to our stacking context.
                        if let stackingContext = layer.stackingContext() {
                            stackingContext.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
                        }
                    }
                }

                // This ensures that the viewport anchor layer will be updated when updating compositing layers upon style change
                if hasOldStyle && WebCore.RenderLayerCompositor.styleChangeAffectsAnchorLayer(renderer[.OldStyle], renderer[.Style]) {
                    layer.setNeedsCompositingConfigurationUpdate()
                }

                // These properties trigger compositing if some descendant is composited.
                if hasOldStyle
                    && WebCore.RenderLayerCompositor.styleChangeMayAffectIndirectCompositingReasons(renderer[.OldStyle], renderer[.Style])
                {
                    layer.setNeedsPostLayoutCompositingUpdate()
                }

                layer.setNeedsCompositingGeometryUpdate()
            }
        }

        if styleDifference(diff, isAtLeast: .Repaint) && hasOldStyle {
            // This ensures that we update border-radius clips on layers that are descendants in containing-block order but not paint order.
            // This is necessary even when
            // the current layer is not composited.
            let changeAffectsClippingOfNonPaintOrderDescendants =
                !layer.isStackingContext() && renderer.hasNonVisibleOverflow()
                && WebCore.RenderLayerCompositor.borderChanged(renderer[.OldStyle], renderer[.Style])
            if changeAffectsClippingOfNonPaintOrderDescendants {
                if let parent = layer.paintOrderParent() {
                    parent.setChildrenNeedCompositingGeometryUpdate()
                }
            }
        }

        guard let backing = layer.backing() else {
            return
        }

        // We need a full compositing configuration update since this also impacts the clipping strategy.
        if WebCore.RenderLayerCompositor.styleChangeAffectsSeparatedProperties(renderer) {
            layer.setNeedsCompositingConfigurationUpdate()
        }

        backing.updateConfigurationAfterStyleChange()

        if styleDifference(diff, isAtLeast: .Repaint) {
            // Visibility change may affect geometry of the enclosing composited layer.
            if hasOldStyle
                && (renderer[.OldStyle].visibility() != renderer[.Style].visibility()
                    || renderer[.OldStyle].isForceHidden() != renderer[.Style].isForceHidden())
            {
                layer.setNeedsCompositingGeometryUpdate()
            }

            // We'll get a diff of Repaint when things like clip-path change; these might affect layer or inner-layer geometry.
            if layer.isComposited() && hasOldStyle {
                if WebCore.RenderLayerCompositor.styleAffectsLayerGeometry(renderer[.OldStyle])
                    || WebCore.RenderLayerCompositor.styleAffectsLayerGeometry(renderer[.Style])
                {
                    layer.setNeedsCompositingGeometryUpdate()
                }
            }

            // image rendering mode can determine whether we use device pixel ratio for the backing store.
            if hasOldStyle && WebCore.RenderLayerCompositor.imageRenderingChanged(renderer[.OldStyle], renderer[.Style]) {
                layer.setNeedsCompositingConfigurationUpdate()
            }

            // A forced color filter has to be painted, so it decides whether an image can be composited directly.
            if hasOldStyle && WebCore.RenderLayerCompositor.appleColorFilterOverrideChanged(renderer[.OldStyle], renderer[.Style]) {
                layer.setNeedsCompositingConfigurationUpdate()
            }
        }

        if styleDifference(diff, isAtLeast: .RecompositeLayer) {
            if layer.isComposited() {
                let hitTestingStateChanged =
                    hasOldStyle && WebCore.RenderLayerCompositor.usedPointerEventsChanged(renderer[.OldStyle], renderer[.Style])
                if renderer.isRenderWidget() || hitTestingStateChanged {
                    // For RenderWidgets this is necessary to get iframe layers hooked up in response to
                    // scheduleInvalidateStyleAndLayerComposition().
                    layer.setNeedsCompositingConfigurationUpdate()
                }
                // If we're changing to/from 0 opacity, then we need to reconfigure the layer since we try to
                // skip backing store allocation for opacity:0.
                if hasOldStyle && WebCore.RenderLayerCompositor.opacityChangedToOrFromTransparent(renderer[.OldStyle], renderer[.Style]) {
                    layer.setNeedsCompositingConfigurationUpdate()
                }
            }
            if hasOldStyle && WebCore.RenderLayerCompositor.recompositeChangeRequiresGeometryUpdate(renderer[.OldStyle], renderer[.Style]) {
                // FIXME: transform changes really need to trigger layout. See RenderElement::adjustStyleDifference().
                layer.setNeedsPostLayoutCompositingUpdate()
                layer.setNeedsCompositingGeometryUpdate()
            }
            if hasOldStyle
                && WebCore.RenderLayerCompositor.recompositeChangeRequiresChildrenGeometryUpdate(renderer[.OldStyle], renderer[.Style])
            {
                layer.setChildrenNeedCompositingGeometryUpdate()
            }
        }
    }
}

// This is a recursive walk similar to the paint-order list collection (RenderLayerTree.swift).
private func clearBackingSharingWithinStackingContext(_ stackingContextRoot: WebCore.RenderLayer, _ curLayer: WebCore.RenderLayer) {
    if curLayer.establishesTopLayerBody() {
        return
    }

    if !isSameRenderLayer(curLayer, stackingContextRoot) && curLayer.isStackingContext() {
        return
    }

    var child = curLayer.firstChild()
    while let current = child {
        if current.isComposited() {
            current.backing()!.clearBackingSharingLayers(WebCore.UpdateBackingSharingFlagSet())
        }

        if !curLayer.isReflectionLayer(current) {
            clearBackingSharingWithinStackingContext(stackingContextRoot, current)
        }
        child = current.nextSibling()
    }
}

private func applyToCompositedLayerIncludingDescendants(_ layer: WebCore.RenderLayer, _ function: (WebCore.RenderLayer) -> Void) {
    if layer.isComposited() {
        function(layer)
    }
    var childLayer = layer.firstChild()
    while let child = childLayer {
        applyToCompositedLayerIncludingDescendants(child, function)
        childLayer = child.nextSibling()
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func clearBackingProviderSequencesInStackingContextOfLayer(_ layer: WebCore.RenderLayer) {
        // We can't rely on z-order lists to be up-to-date here. For fullscreen, we may already have done a style update which dirties them.
        if let stackingContextLayer = layer.stackingContext() {
            clearBackingSharingWithinStackingContext(stackingContextLayer, stackingContextLayer)
        }
    }

    @cxx
    @implementation
    public func layerWillBeRemoved(_ parent: WebCore.RenderLayer, _ child: WebCore.RenderLayer) {
        layerWillBeRemovedBody(parent, child)
    }

    @inline(always)
    func layerWillBeRemovedBody(_ parent: WebCore.RenderLayer, _ child: WebCore.RenderLayer) {
        if parent.renderer().renderTreeBeingDestroyed() {
            return
        }
        layerWillBeRemovedWhileRenderTreeLives(child)
    }

    // layerWillBeRemoved() for a parent whose render tree is not being destroyed.
    @inline(always)
    func layerWillBeRemovedWhileRenderTreeLives(_ child: WebCore.RenderLayer) {
        if child.isComposited() {
            repaintInCompositedAncestor(child, child.backing()!.compositedBounds()) // FIXME: do via dirty bits?
        } else if child.paintsIntoProvidedBacking() {
            let backingProviderLayer = child.backingProviderLayer()!
            // FIXME: Optimize this repaint.
            backingProviderLayer.setBackingNeedsRepaint(.Clip)
            backingProviderLayer.backing()!.removeBackingSharingLayer(child, WebCore.UpdateBackingSharingFlagSet())
        } else {
            return
        }

        child.setNeedsCompositingLayerConnection()
    }

    @cxx
    @implementation
    public func repaintCompositedLayers() {
        recursiveRepaintLayer(rootRenderLayer())
    }

    @cxx
    @implementation
    public func recursiveRepaintLayer(_ layer: WebCore.RenderLayer) {
        layer.updateLayerListsIfNeeded()

        // FIXME: This method does not work correctly with transforms.
        if layer.isComposited() && !layer.backing()!.paintsIntoCompositedAncestor() {
            layer.setBackingNeedsRepaint(.Clip)
        }

        layer.withLayerListMutationForbidden {
            if layer.hasCompositingDescendant() {
                var index = 0
                while index < layer.paintOrderListCount(.Negative) {
                    recursiveRepaintLayer(layer.paintOrderListLayer(.Negative, index))
                    index += 1
                }

                index = 0
                while index < layer.paintOrderListCount(.Positive) {
                    recursiveRepaintLayer(layer.paintOrderListLayer(.Positive, index))
                    index += 1
                }
            }

            var index = 0
            while index < layer.paintOrderListCount(.NormalFlow) {
                recursiveRepaintLayer(layer.paintOrderListLayer(.NormalFlow, index))
                index += 1
            }
        }
    }

    @cxx
    @implementation
    public func invalidateEventRegionForAllLayers() {
        applyToCompositedLayerIncludingDescendants(rootRenderLayer()) { layer in
            _ = layer.invalidateEventRegion(.SettingDidChange)
        }
    }

    @cxx
    @implementation
    public func clearBackingForAllLayers() {
        applyToCompositedLayerIncludingDescendants(rootRenderLayer()) { layer in
            layer.clearBacking(WebCore.UpdateBackingSharingFlagSet(), false)
        }
    }
}

// The update levels that pass down the backing and hierarchy traversal.
private struct UpdateLevel {
    var allDescendants = false
    var compositedChildren = false

    var isEmpty: Bool { !allDescendants && !compositedChildren }
}

// The state the backing and hierarchy traversal passes to a layer's descendants: the nearest composited ancestor,
// and whether the layer lists the descendants append to (layers clipped by ancestor scrollers, layers with
// composited overflow:scroll) are the ancestor's own.
private struct UpdateBackingTraversalState {
    var compositingAncestor: WebCore.RenderLayer? = nil
}

private func setChildren(_ parent: WebCore.GraphicsLayer, _ children: [WebCore.GraphicsLayer]) {
    var childList = WebCore.GraphicsLayerChildList()
    for child in children {
        childList.append(child)
    }
    childList.setAsChildrenOf(parent)
}

extension WebCore.RenderLayerCompositor {
    // The body of updateCompositingLayers(), which calls it inside a LayerFreeForbiddenScope. Returns true on a successful update.
    @cxx
    @implementation
    public func updateCompositingLayersInScope(_ updateType: WebCore.CompositingUpdateType, _ updateRootArg: WebCore.RenderLayer?) -> Bool {
        if updateType == .AfterStyleChange || updateType == .AfterLayout {
            cacheAcceleratedCompositingFlagsAfterLayout() // Some flags (e.g. forceCompositingMode) depend on layout.
        }

        cancelCompositingLayerUpdate()

        // Compositing layers will be updated in Document::setVisualUpdatesAllowed(bool) if suppressed here.
        if !visualUpdatesAllowed() {
            return false
        }

        // Avoid updating the layers with old values. Compositing layers will be updated after the layout is finished.
        // This happens when m_updateCompositingLayersTimer fires before layout is updated.
        if m_renderView.get().needsLayout() {
            return false
        }

        if !m_compositing && (m_forceCompositingMode || (isRootFrameCompositor() && pageOverlayCount() != 0)) {
            enableCompositingMode(true)
        }

        let rootLayer = rootRenderLayer()
        let isPageScroll = updateRootArg == nil || isSameRenderLayer(updateRootArg, rootLayer)
        let updateRoot = rootLayer

        if updateType == .OnScroll || updateType == .OnCompositedScroll {
            // We only get here if we didn't scroll on the scrolling thread, so this update needs to re-position viewport-constrained
            // layers.
            if m_renderView.get().settings().acceleratedCompositingForFixedPositionEnabled() && isPageScroll {
                setViewportConstrainedLayersNeedCompositingGeometryUpdate()
            }

            // Scrolling can affect overlap. FIXME: avoid for page scrolling.
            updateRoot.setDescendantsNeedCompositingRequirementsTraversal()
        }

        if updateType == .AfterLayout {
            // Ensure that post-layout updates push new scroll position and viewport rects onto the root node.
            rootLayer.setNeedsScrollingTreeUpdate()
        }

        if !updateRoot.hasDescendantNeedingCompositingRequirementsTraversal() && !m_compositing {
            return true
        }

        if !updateRoot.needsAnyCompositingTraversal() {
            return true
        }

        // An unsigned count, which wraps.
        m_compositingUpdateCount &+= 1

        // FIXME: optimize root-only update.
        if updateRoot.hasDescendantNeedingCompositingRequirementsTraversal() || updateRoot.needsCompositingRequirementsTraversal() {
            beginWillChangeAreaEstimate()
            computeCompositingRequirementsInGeometryMap(rootLayer, updateRoot)

            if willChangeAreaEstimateExceedsBudget() {
                rootLayer.setDescendantsNeedCompositingRequirementsTraversal()

                computeCompositingRequirementsInGeometryMap(rootLayer, updateRoot)
            }
        }

        updateLayerPositionsForTreeDebugging(updateRoot)

        if updateRoot.hasDescendantNeedingUpdateBackingOrHierarchyTraversal() || updateRoot.needsUpdateBackingOrHierarchyTraversal() {
            let scrollingTreeState = rootScrollingTreeState()
            let hadSubscrollers = hasSubscrollers()

            updateBackingAndHierarchy(updateRoot, scrollingTreeState)

            if hasSubscrollers() != hadSubscrollers {
                invalidateEventRegionForAllFrames()
            }

            resolveScrollingTreeRelationships()
        }

        // FIXME: Only do if dirty.
        updateRootLayerPosition()

        layerTreeDidChange()

        if m_renderView.get().needsRepaintHackAfterCompositingLayerUpdateForDebugOverlaysOnly() {
            m_renderView.get().repaintRootContents()
            m_renderView.get().setNeedsRepaintHackAfterCompositingLayerUpdateForDebugOverlaysOnly(false)
        }

        if scrolledContentsLayer() != nil {
            updateOverflowControlsLayers()
        }

        updateLayerPositionsForTreeDebugging(updateRoot)
        return true
    }

    private func updateBackingAndHierarchy(_ updateRoot: WebCore.RenderLayer, _ rootScrollingTreeState: WebCore.ScrollingTreeState) {
        var scrollingTreeState = rootScrollingTreeState
        var childList: [WebCore.GraphicsLayer] = []
        var layersClippedByScrollers: [WebCore.RenderLayer] = []
        var overflowScrollLayers: [WebCore.RenderLayer] = []
        updateBackingAndHierarchy(
            updateRoot,
            &childList,
            UpdateBackingTraversalState(),
            &layersClippedByScrollers,
            &overflowScrollLayers,
            &scrollingTreeState,
            UpdateLevel()
        )

        if scrollingTreeState.needSynchronousScrollingReasonsUpdate {
            updateSynchronousScrollingNodes()
        }

        // Host the document layer in the RenderView's root layer.
        if let overlayHost = documentOverlayHostLayer() {
            childList.append(overlayHost)
        }
        // Even when childList is empty, don't drop out of compositing mode if there are
        // composited layers that we didn't hit in our traversal (e.g. because of visibility:hidden).
        if childList.isEmpty && !needsCompositingForContentOrOverlays() {
            destroyRootLayer()
        } else if let rootContentsLayer = rootContentsLayer() {
            setChildren(rootContentsLayer, childList)
        }
    }

    // Recurses down the tree, parenting descendant compositing layers and collecting an array of child layers for the current compositing
    // layer.
    private func updateBackingAndHierarchy(
        _ layer: WebCore.RenderLayer,
        _ childLayersOfEnclosingLayer: inout [WebCore.GraphicsLayer],
        _ traversalState: UpdateBackingTraversalState,
        _ layersClippedByScrollers: inout [WebCore.RenderLayer],
        _ overflowScrollLayers: inout [WebCore.RenderLayer],
        _ scrollingTreeState: inout WebCore.ScrollingTreeState,
        _ updateLevelArg: UpdateLevel
    ) {
        layer.updateDescendantDependentFlags()
        layer.updateLayerListsIfNeeded()

        var updateLevel = updateLevelArg
        var layerNeedsUpdate = !updateLevel.isEmpty
        if layer.descendantsNeedUpdateBackingAndHierarchyTraversal() {
            updateLevel.allDescendants = true
        }

        var scrollingStateForDescendants = scrollingTreeState
        var traversalStateForDescendants = traversalState
        var descendantLayersClippedByScrollers: [WebCore.RenderLayer] = []
        var compositedOverflowScrollLayers: [WebCore.RenderLayer] = []

        if layer.needsScrollingTreeUpdate() {
            scrollingTreeState.needSynchronousScrollingReasonsUpdate = true
        }

        let layerBacking = layer.backing()
        if let layerBacking {
            updateLevel.compositedChildren = false

            // We updated the composited bounds in RenderLayerBacking::updateAfterLayout(), but it may have changed
            // based on which descendants are now composited.
            if layerBacking.updateCompositedBounds() {
                layer.setNeedsCompositingGeometryUpdate()
                // Our geometry can affect descendants.
                updateLevel.compositedChildren = true
            }

            if layerNeedsUpdate || layer.needsCompositingConfigurationUpdate() {
                let hadClippingLayer = layerBacking.hasClippingLayer()
                if layerBacking.updateConfiguration(traversalState.compositingAncestor) {
                    layerNeedsUpdate = true // We also need to update geometry.
                    layer.setNeedsCompositingLayerConnection()
                    // Composited children are positioned relative to parentForSublayers(), which changes with the clipping layer.
                    if hadClippingLayer != layerBacking.hasClippingLayer() {
                        updateLevel.compositedChildren = true
                    }
                }

                layerBacking.updateDebugIndicators(m_showDebugBorders, m_showRepaintCounter)
            }

            var layerGeometryChanged = false
            if layerNeedsUpdate || layer.needsCompositingGeometryUpdate() {
                layerBacking.updateGeometry(traversalState.compositingAncestor)
                layerGeometryChanged = true
            } else if layer.needsScrollingTreeUpdate() {
                layerGeometryChanged = true
            }

            if let reflection = layer.reflectionLayer(), let reflectionBacking = reflection.backing() {
                _ = reflectionBacking.updateCompositedBounds()
                reflectionBacking.updateGeometry(layer)
                reflectionBacking.updateAfterDescendants()
            }

            if layer.parent() == nil {
                updateRootLayerPosition()
            }

            // FIXME: do based on dirty flags. Need to do this for changes of geometry, configuration and hierarchy.
            // Need to be careful to do the right thing when a scroll-coordinated layer loses a scroll-coordinated ancestor.
            updateScrollCoordinationForBackedLayer(
                layer,
                traversalState.compositingAncestor,
                &scrollingTreeState,
                &scrollingStateForDescendants,
                layerGeometryChanged
            )

            traversalStateForDescendants.compositingAncestor = layer
        }

        if layer.childrenNeedCompositingGeometryUpdate() {
            updateLevel.compositedChildren = true
        }

        // If this layer has backing, then we are collecting its children, otherwise appending
        // to the compositing child list of an enclosing layer.
        var layerChildren: [WebCore.GraphicsLayer] = []

        let requireDescendantTraversal =
            layer.hasDescendantNeedingUpdateBackingOrHierarchyTraversal()
            || (layer.hasCompositingDescendant()
                && (layerBacking == nil || layer.needsCompositingLayerConnection() || !updateLevel.isEmpty))

        let requiresChildRebuild = layerBacking != nil && layer.needsCompositingLayerConnection() && !layer.hasCompositingDescendant()

        layer.withLayerListMutationForbidden {
            if layerBacking != nil {
                updateBackingAndHierarchyOfDescendants(
                    layer,
                    layerBacking,
                    &layerChildren,
                    traversalStateForDescendants,
                    &descendantLayersClippedByScrollers,
                    &compositedOverflowScrollLayers,
                    &scrollingTreeState,
                    &scrollingStateForDescendants,
                    updateLevel,
                    requireDescendantTraversal,
                    requiresChildRebuild
                )
            } else {
                updateBackingAndHierarchyOfDescendants(
                    layer,
                    layerBacking,
                    &childLayersOfEnclosingLayer,
                    traversalStateForDescendants,
                    &layersClippedByScrollers,
                    &overflowScrollLayers,
                    &scrollingTreeState,
                    &scrollingStateForDescendants,
                    updateLevel,
                    requireDescendantTraversal,
                    requiresChildRebuild
                )
            }

            if let layerBacking {
                if requireDescendantTraversal || requiresChildRebuild {
                    let widgetLayerAttachment = attachWidgetContentLayersIfNecessaryForSwift(layer.renderer())

                    if let newContentLayer = viewTransitionNewContentLayer(layer) {
                        layerChildren.append(newContentLayer)
                    }

                    if !widgetLayerAttachment.widgetLayersAttachedAsChildren {
                        // If the layer has a clipping layer the overflow controls layers will be siblings of the clipping layer.
                        // Otherwise, the overflow control layers are normal children.
                        if !layerBacking.hasClippingLayer() && !layerBacking.hasScrollingLayer() {
                            if let overflowControlLayer = layerBacking.overflowControlsContainer() {
                                layerChildren.append(overflowControlLayer)
                            }
                        }

                        adjustOverflowScrollbarContainerLayers(
                            layer,
                            compositedOverflowScrollLayers,
                            descendantLayersClippedByScrollers,
                            &layerChildren
                        )
                        setChildren(layerBacking.parentForSublayers()!, layerChildren)
                    }
                }

                // Layers that are captured in a view transition get manually parented to their pseudo in viewTransitionNewContentLayer().
                // The view transition root (when the document element is captured) gets parented in RenderLayerBacking::childForSuperlayers.
                var skipAddToEnclosing = layer.renderer().capturedInViewTransition() && !layer.renderer().isDocumentElementRenderer()
                if layer.renderer().isViewTransitionContainingBlock()
                    && WebCore.RenderLayerCompositor.documentHasActiveViewTransitionCapturedDocumentElement(layer.renderer())
                {
                    skipAddToEnclosing = true
                }

                if !skipAddToEnclosing {
                    childLayersOfEnclosingLayer.append(layerBacking.childForSuperlayers()!)
                }

                if layerBacking.hasAncestorClippingLayersWithScrollingForSwift() {
                    layersClippedByScrollers.append(layer)
                }

                if layer.hasCompositedScrollableOverflow() {
                    overflowScrollLayers.append(layer)
                }

                layerBacking.updateAfterDescendants()
            }

            layer.clearUpdateBackingOrHierarchyTraversalState()
        }
    }

    private func updateBackingAndHierarchyOfDescendants(
        _ layer: WebCore.RenderLayer,
        _ layerBacking: WebCore.RenderLayerBacking?,
        _ childList: inout [WebCore.GraphicsLayer],
        _ traversalStateForDescendants: UpdateBackingTraversalState,
        _ layersClippedByScrollers: inout [WebCore.RenderLayer],
        _ overflowScrollLayers: inout [WebCore.RenderLayer],
        _ scrollingTreeState: inout WebCore.ScrollingTreeState,
        _ scrollingStateForDescendants: inout WebCore.ScrollingTreeState,
        _ updateLevel: UpdateLevel,
        _ requireDescendantTraversal: Bool,
        _ requiresChildRebuild: Bool
    ) {
        func appendForegroundLayerIfNecessary(_ childList: inout [WebCore.GraphicsLayer]) {
            // If a negative z-order child is compositing, we get a foreground layer which needs to get parented.
            // Same thing for `spatial: portal` elements.
            let needsForegroundLayer =
                layer.paintOrderListCount(.Negative) > 0 || WebCore.RenderLayerCompositor.isSpatialPortalForSwift(layer.renderer())
            if needsForegroundLayer, let layerBacking, let foregroundLayer = layerBacking.foregroundLayer() {
                childList.append(foregroundLayer)
            }
        }

        // After recursing into a composited SVG child, add the overlay "(svg segment N)" layer that paints the
        // non-composited content after it on top. The order is set by matching each composited child exactly,
        // giving [primary segment][child0][segment 1][child1][segment 2]... A composited child that only has a
        // composited descendant works too, because that descendant is added to childList during the same
        // recursion, just before its segment.
        func appendSVGSegmentLayerIfNecessary(_ childLayer: WebCore.RenderLayer, _ childList: inout [WebCore.GraphicsLayer]) {
            guard let layerBacking, layerBacking.hasSVGPaintOrderSegments() else {
                return
            }
            if let segmentLayer = layerBacking.svgSegmentLayerAfterCompositedChild(childLayer) {
                childList.append(segmentLayer)
            }
        }

        if requireDescendantTraversal {
            var index = 0
            while index < layer.paintOrderListCount(.Negative) {
                let childLayer = layer.paintOrderListLayer(.Negative, index)
                updateBackingAndHierarchy(
                    childLayer,
                    &childList,
                    traversalStateForDescendants,
                    &layersClippedByScrollers,
                    &overflowScrollLayers,
                    &scrollingStateForDescendants,
                    updateLevel
                )
                appendSVGSegmentLayerIfNecessary(childLayer, &childList)
                index += 1
            }

            appendForegroundLayerIfNecessary(&childList)

            index = 0
            while index < layer.paintOrderListCount(.NormalFlow) {
                let childLayer = layer.paintOrderListLayer(.NormalFlow, index)
                updateBackingAndHierarchy(
                    childLayer,
                    &childList,
                    traversalStateForDescendants,
                    &layersClippedByScrollers,
                    &overflowScrollLayers,
                    &scrollingStateForDescendants,
                    updateLevel
                )
                appendSVGSegmentLayerIfNecessary(childLayer, &childList)
                index += 1
            }

            index = 0
            while index < layer.paintOrderListCount(.Positive) {
                let childLayer = layer.paintOrderListLayer(.Positive, index)
                updateBackingAndHierarchy(
                    childLayer,
                    &childList,
                    traversalStateForDescendants,
                    &layersClippedByScrollers,
                    &overflowScrollLayers,
                    &scrollingStateForDescendants,
                    updateLevel
                )
                appendSVGSegmentLayerIfNecessary(childLayer, &childList)
                index += 1
            }

            // Pass needSynchronousScrollingReasonsUpdate back up.
            WebCore.RenderLayerCompositor.mergeScrollingTreeStateFromDescendants(&scrollingTreeState, scrollingStateForDescendants)
        } else if requiresChildRebuild {
            appendForegroundLayerIfNecessary(&childList)
        }
    }

    // Finds the set of overflow:scroll layers whose overflow controls hosting layer needs to be reparented,
    // to ensure that the scrollbars show on top of positioned content inside the scroller.
    private func adjustOverflowScrollbarContainerLayers(
        _ stackingContextLayer: WebCore.RenderLayer,
        _ overflowScrollLayers: [WebCore.RenderLayer],
        _ layersClippedByScrollers: [WebCore.RenderLayer],
        _ layerChildren: inout [WebCore.GraphicsLayer]
    ) {
        if layersClippedByScrollers.isEmpty {
            return
        }

        // Each overflow:scroll layer that clips one of the layers, with the last layer it clips.
        var overflowScrollToLastContainedLayerMap: [(overflowScrollLayer: WebCore.RenderLayer, lastContainedLayer: WebCore.RenderLayer)] =
            []

        for clippedLayer in layersClippedByScrollers {
            let clippingBacking = clippedLayer.backing()!
            var stackIndex = 0
            while stackIndex < clippingBacking.ancestorClippingStackSizeForSwift() {
                if let scrollerLayer = clippingBacking.overflowScrollClippingLayerForSwift(stackIndex) {
                    if let mapIndex = overflowScrollToLastContainedLayerMap.firstIndex(where: {
                        isSameRenderLayer($0.overflowScrollLayer, scrollerLayer)
                    }) {
                        overflowScrollToLastContainedLayerMap[mapIndex].lastContainedLayer = clippedLayer
                    } else {
                        overflowScrollToLastContainedLayerMap.append((scrollerLayer, clippedLayer))
                    }
                }
                stackIndex += 1
            }
        }

        for overflowScrollingLayer in overflowScrollLayers {
            guard
                let mapIndex = overflowScrollToLastContainedLayerMap.firstIndex(where: {
                    isSameRenderLayer($0.overflowScrollLayer, overflowScrollingLayer)
                })
            else {
                continue
            }

            let lastContainedDescendant = overflowScrollToLastContainedLayerMap[mapIndex].lastContainedLayer
            if !lastContainedDescendant.isComposited() {
                continue
            }

            let lastContainedDescendantBacking = lastContainedDescendant.backing()!
            guard let overflowBacking = overflowScrollingLayer.backing() else {
                continue
            }

            guard var overflowContainerLayer = overflowBacking.overflowControlsContainer() else {
                continue
            }

            overflowContainerLayer.removeFromParent()

            if overflowBacking.hasAncestorClippingLayers() {
                overflowBacking.ensureOverflowControlsHostLayerAncestorClippingStack(stackingContextLayer)
            }

            if let clippingLastLayer = overflowBacking.overflowControlsHostClippingLastLayerForSwift() {
                setChildren(clippingLastLayer, [overflowContainerLayer])
                overflowContainerLayer = overflowBacking.overflowControlsHostClippingFirstLayerForSwift()!
            }

            let lastDescendantGraphicsLayer = lastContainedDescendantBacking.childForSuperlayers()
            let overflowScrollerGraphicsLayer = overflowBacking.childForSuperlayers()

            var lastDescendantLayerIndex: Int? = nil
            var scrollerLayerIndex: Int? = nil
            for i in layerChildren.indices {
                let graphicsLayer = layerChildren[i]
                if WebCore.RenderLayerCompositor.isSameGraphicsLayer(graphicsLayer, lastDescendantGraphicsLayer) {
                    lastDescendantLayerIndex = i
                } else if WebCore.RenderLayerCompositor.isSameGraphicsLayer(graphicsLayer, overflowScrollerGraphicsLayer) {
                    scrollerLayerIndex = i
                }
            }

            if let lastDescendantLayerIndex, let scrollerLayerIndex {
                let insertionIndex = max(lastDescendantLayerIndex + 1, scrollerLayerIndex + 1)
                layerChildren.insert(overflowContainerLayer, at: insertionIndex)
            }

            overflowBacking.adjustOverflowControlsPositionRelativeToAncestor(stackingContextLayer)
        }
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func enableCompositingMode(_ enable: Bool) {
        if enable != m_compositing {
            m_compositing = enable

            if m_compositing {
                ensureRootLayer()
                notifyIFramesOfCompositingChange()
            } else {
                destroyRootLayer()
            }

            m_renderView.get().layer()!.setNeedsPostLayoutCompositingUpdate()
        }
    }

    @cxx
    @implementation
    public func cacheAcceleratedCompositingFlags() {
        let settings = m_renderView.get().settings()
        var hasAcceleratedCompositing = settings.acceleratedCompositingEnabled()

        // We allow the chrome to override the settings, in case the page is rendered
        // on a chrome that doesn't allow accelerated compositing.
        if hasAcceleratedCompositing {
            m_compositingTriggers = allowedCompositingTriggers()
            hasAcceleratedCompositing = m_compositingTriggers != 0
        }

        let showDebugBorders = settings.showDebugBorders()
        let showRepaintCounter = settings.showRepaintCounter()
        let acceleratedDrawingEnabled = settings.acceleratedDrawingEnabled()
        let useDynamicContentScalingDisplayListsForDOMRendering = WebCore.RenderLayerCompositor
            .useDynamicContentScalingDisplayListsForDOMRendering(settings)

        // forceCompositingMode for subframes can only be computed after layout.
        var forceCompositingMode = m_forceCompositingMode
        if isRootFrameCompositor() {
            forceCompositingMode = m_renderView.get().settings().forceCompositingMode() && hasAcceleratedCompositing
        }

        if hasAcceleratedCompositing != m_hasAcceleratedCompositing || showDebugBorders != m_showDebugBorders
            || showRepaintCounter != m_showRepaintCounter || forceCompositingMode != m_forceCompositingMode
            || useDynamicContentScalingDisplayListsForDOMRendering != m_useDynamicContentScalingDisplayListsForDOMRendering
        {
            if let rootLayer = m_renderView.get().layer() {
                rootLayer.setNeedsCompositingConfigurationUpdate()
                rootLayer.setDescendantsNeedUpdateBackingAndHierarchyTraversal()
            }
        }

        let debugBordersChanged = m_showDebugBorders != showDebugBorders
        m_hasAcceleratedCompositing = hasAcceleratedCompositing
        m_forceCompositingMode = forceCompositingMode
        m_showDebugBorders = showDebugBorders
        m_showRepaintCounter = showRepaintCounter
        m_acceleratedDrawingEnabled = acceleratedDrawingEnabled
        m_useDynamicContentScalingDisplayListsForDOMRendering = useDynamicContentScalingDisplayListsForDOMRendering

        if debugBordersChanged {
            if let layer = layerForHorizontalScrollbar() {
                layer.setShowDebugBorder(m_showDebugBorders)
            }

            if let layer = layerForVerticalScrollbar() {
                layer.setShowDebugBorder(m_showDebugBorders)
            }

            if let layer = layerForScrollCorner() {
                layer.setShowDebugBorder(m_showDebugBorders)
            }
        }

        if updateCompositingPolicy() {
            rootRenderLayer().setDescendantsNeedCompositingRequirementsTraversal()
        }
    }

    @cxx
    @implementation
    public func cacheAcceleratedCompositingFlagsAfterLayout() {
        cacheAcceleratedCompositingFlags()

        if isRootFrameCompositor() {
            return
        }

        func frameContentRequiresCompositing() -> Bool {
            var queryData = WebCore.RenderLayerCompositor.RequiresCompositingData()
            if requiresCompositingForScrollableFrame(&queryData) {
                return true
            }

            return documentHasHDRContent()
        }

        let forceCompositingMode =
            m_hasAcceleratedCompositing && m_renderView.get().settings().forceCompositingMode() && frameContentRequiresCompositing()
        if forceCompositingMode != m_forceCompositingMode {
            m_forceCompositingMode = forceCompositingMode
            rootRenderLayer().setDescendantsNeedCompositingRequirementsTraversal()
        }
    }

    @cxx
    @implementation
    public func setRenderingIsSuppressed(_ suppressed: Bool) {
        if let rootLayer = rootGraphicsLayer() {
            rootLayer.setRenderingIsSuppressedIncludingDescendants(suppressed)
        }
    }

    @cxx
    @implementation
    public func didChangeVisibleRect() {
        guard let rootLayer = rootGraphicsLayer() else {
            return
        }

        let visibleRect = visibleRectForLayerFlushing()
        let requiresFlush = rootLayer.visibleRectChangeRequiresFlush(visibleRect)
        if requiresFlush {
            scheduleRenderingUpdate()
        }
    }

    @cxx
    @implementation
    public func has3DContent() -> Bool {
        layerHas3DContent(rootRenderLayer())
    }

    @cxx
    @implementation
    public func needsCompositingForContentOrOverlays() -> Bool {
        // Unsigned arithmetic, which wraps; only whether the sum is zero matters.
        m_contentLayersCount &+ UInt32(truncatingIfNeeded: pageOverlayCount()) != 0
    }

    @cxx
    @implementation
    public func frameViewDidChangeLocation(_ contentsOffset: WebCore.FloatPoint) {
        if let overflowControlsHostLayer = overflowControlsHostLayer() {
            overflowControlsHostLayer.setPosition(contentsOffset)
        }
    }

    @cxx
    @implementation
    public func frameViewDidChangeSize() {
        if let layer = m_renderView.get().layer() {
            layer.setNeedsCompositingGeometryUpdate()
        }

        if scrolledContentsLayer() != nil {
            updateScrollLayerClipping()
            frameViewDidScroll()
            updateOverflowControlsLayers()

            #if os(macOS) // HAVE(RUBBER_BANDING)
            updateSizeAndPositionForOverhangAreaLayer()
            #endif
        }
    }

    @cxx
    @implementation
    public func frameViewDidScroll() {
        if scrolledContentsLayer() == nil {
            return
        }

        // If there's a scrolling coordinator that manages scrolling for this frame view,
        // it will also manage updating the scroll layer position.
        if hasCoordinatedScrolling() {
            // We have to schedule a flush in order for the main TiledBacking to update its tile coverage.
            scheduleRenderingUpdate()
            return
        }

        updateScrollLayerPosition()
    }

    @cxx
    @implementation
    public func frameViewDidAddOrRemoveScrollbars() {
        updateOverflowControlsLayers()
    }

    @cxx
    @implementation
    public func frameViewDidLayout() {
        if let renderViewBacking = m_renderView.get().layer()!.backing() {
            renderViewBacking.adjustTiledBackingCoverage()
        }
    }

    @cxx
    @implementation
    public func rootLayerConfigurationChanged() {
        let renderViewLayer = m_renderView.get().layer()!
        if let renderViewBacking = renderViewLayer.backing(), renderViewBacking.isFrameLayerWithTiledBacking() {
            renderViewLayer.setNeedsCompositingConfigurationUpdate()
            scheduleCompositingLayerUpdate()
        }
    }
}

// A simplified version of containing block walking that only handles absolute and fixed position. Calls body with each
// ancestor layer, whether it is in the layer's containing block chain and whether it is its next paint-order ancestor,
// until body returns true.
func traverseRenderLayerAncestors(
    _ layer: WebCore.RenderLayer,
    _ body: (_ ancestorLayer: WebCore.RenderLayer, _ isContainingBlockChain: Bool, _ isPaintOrderAncestor: Bool) -> Bool
) {
    var positioningBehavior = layer.renderer()[.Style].position()
    var nextPaintOrderParent = layer.paintOrderParent()

    var ancestor = layer.parent()
    while let ancestorLayer = ancestor {
        var inContainingBlockChain = true

        switch positioningBehavior {
        case .Absolute:
            inContainingBlockChain = ancestorLayer.renderer().canContainAbsolutelyPositionedObjectsForSwift()
        case .Fixed:
            inContainingBlockChain = ancestorLayer.renderer().canContainFixedPositionObjectsForSwift()
        default:
            break
        }

        let isPaintOrderAncestor = isSameRenderLayer(ancestorLayer, nextPaintOrderParent)
        if body(ancestorLayer, inContainingBlockChain, isPaintOrderAncestor) {
            return
        }

        if inContainingBlockChain {
            positioningBehavior = ancestorLayer.renderer()[.Style].position()
        }

        if isPaintOrderAncestor {
            nextPaintOrderParent = ancestorLayer.paintOrderParent()
        }

        ancestor = ancestorLayer.parent()
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public static func layerScrollBehaviorRelativeToCompositedAncestor(
        _ layer: borrowing WebCore.RenderLayer,
        _ compositedAncestor: borrowing WebCore.RenderLayer
    ) -> WebCore.ScrollPositioningBehavior {
        if !layer.hasCompositedScrollingAncestor() {
            return .None
        }

        let compositedAncestorRef = WebCore.LayerRef(copy compositedAncestor)
        var needsMovesNode = false
        traverseRenderLayerAncestors(layer) { ancestorLayer, isContainingBlockChain, _ in
            if WebCore.LayerRef(ancestorLayer) == compositedAncestorRef {
                return true
            }

            if isContainingBlockChain && ancestorLayer.hasCompositedScrollableOverflow() {
                needsMovesNode = true
                return true
            }

            return false
        }

        if needsMovesNode {
            return .Moves
        }

        if Optional(fromCxx: layer.boxScrollingScope()) != Optional(fromCxx: compositedAncestor.contentsScrollingScope()) {
            return .Stationary
        }

        return .None
    }

    @cxx
    @implementation
    public func setRootElementCapturedInViewTransition(_ captured: Bool) {
        if m_rootElementCapturedInViewTransition == captured {
            return
        }
        m_rootElementCapturedInViewTransition = captured
        updateRootContentsLayerBackgroundColor()
    }

    @cxx
    @implementation
    public func updateRootContentsLayerBackgroundColor() {
        guard let rootContentsLayer = rootContentsLayer() else {
            return
        }

        if m_rootElementCapturedInViewTransition {
            rootContentsLayer.setBackgroundColor(m_viewBackgroundColor)
        } else {
            rootContentsLayer.setBackgroundColor(WebCore.Color())
        }
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func layerBecameComposited(_ layer: borrowing WebCore.RenderLayer) {
        // FIXME: Pass the layer itself once SILGen wraps a borrowed shared reference in an optional correctly (KIT
        // docs/interop-limitations.md, "A borrowed C++ shared reference passed as an optional fails the SIL
        // verifier"): an assertions toolchain stops on it. The copy is one retain and release.
        if !(WebCore.LayerRef(copy layer) == WebCore.LayerRef(m_renderView.get().layer())) {
            // An unsigned count, which wraps.
            m_contentLayersCount &+= 1
        }
    }

    // If an element has composited negative z-index children, those children render in front of the
    // layer background, so we need an extra 'contents' layer for the foreground of the layer object.
    @cxx
    @implementation
    public func needsContentsCompositingLayer(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        // An SVG container paints its children in DOM order from one flat list, so a composited negative-z
        // child is just an ordinary composited child that splits the list (it gets a following overlay segment
        // layer, and the primary segment may then be empty). It must not also pull out a foreground layer, which would
        // double-parent it. RenderSVGForeignObject is an SVG layer but paints its HTML subtree with HTML-style
        // z-order and keeps the foreground-layer path.
        if layer.isSVGLayer() && !layer.renderer().isRenderSVGForeignObject() {
            return false
        }

        var index = 0
        while index < layer.paintOrderListCount(.Negative) {
            let negativeZOrderLayer = layer.paintOrderListLayer(.Negative, index)
            if negativeZOrderLayer.isComposited() || negativeZOrderLayer.hasCompositingDescendant() {
                return true
            }
            index += 1
        }

        // When a <model> with a hosted contents layer is inside an `<a rel="ar">`, we need a
        // foreground layer so the AR badge painted in RenderModel::paintReplaced is composited
        // above the hosted model contents layer.
        if WebCore.RenderLayerCompositor.isModelInSystemPreviewLink(layer.renderer()) {
            return true
        }

        // DOM content goes in the foreground layer by default, the content layer will be a StereoLayer for models.
        if WebCore.RenderLayerCompositor.isSpatialPortalForSwift(layer.renderer()) {
            return true
        }

        return false
    }

    @cxx
    @implementation
    public func supportsFixedRootBackgroundCompositing() -> Bool {
        guard let renderViewBacking = m_renderView.get().layer()!.backing() else {
            return false
        }
        return renderViewBacking.isFrameLayerWithTiledBacking()
    }

    @cxx
    @implementation
    public func needsFixedRootBackgroundLayer(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        if !layer.isRenderViewLayer() {
            return false
        }

        if m_renderView.get().settings().fixedBackgroundsPaintRelativeToDocument() {
            return false
        }

        return supportsFixedRootBackgroundCompositing() && m_renderView.get().rootBackgroundIsEntirelyFixed()
    }

    @cxx
    @implementation
    public func documentUsesTiledBacking() -> Bool {
        guard let layer = m_renderView.get().layer() else {
            return false
        }

        guard let backing = layer.backing() else {
            return false
        }

        return backing.isFrameLayerWithTiledBacking()
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func allowBackingStoreDetachingForFixedPosition(_ layer: WebCore.RenderLayer, _ absoluteBounds: WebCore.LayoutRect) -> Bool {
        // We'll allow detaching if the layer is outside the layout viewport. Fixed layers inside
        // the layout viewport can be revealed by async scrolling, so we want to pin their backing store.
        let frameView = m_renderView.get().frameView()
        var fixedLayoutRect: WebCore.LayoutRect
        if frameView.useFixedLayout() {
            fixedLayoutRect = WebCore.LayoutRect(m_renderView.get().unscaledDocumentRect())
        } else {
            fixedLayoutRect = frameView.rectForFixedPositionLayout()
        }

        return !fixedLayoutRect.intersects(absoluteBounds)
    }

    @cxx
    @implementation
    public func repaintOnCompositingChange(_ layer: WebCore.RenderLayer, _ repaintContainer: WebCore.RenderLayerModelObject?) {
        // If the renderer is not attached yet, no need to repaint.
        let renderer: WebCore.RenderObject = layer.renderer()
        if !WebCore.RenderObject.isSameRenderer(renderer, m_renderView.get()) && renderer.parent() == nil {
            return
        }

        layer.repaintIncludingNonCompositingDescendants(repaintContainer)
        if WebCore.RenderObject.isSameRenderer(repaintContainer, m_renderView.get()) {
            // The contents of this layer may be moving between the window
            // and a GraphicsLayer, so we need to make sure the window system
            // synchronizes those changes on the screen.
            m_renderView.get().frameView().setNeedsOneShotDrawingSynchronization()
        }
    }

    // This method assumes that layout is up-to-date, unlike repaintOnCompositingChange().
    @cxx
    @implementation
    public func repaintInCompositedAncestor(_ layer: WebCore.RenderLayer, _ rect: WebCore.LayoutRect) {
        guard let compositedAncestor = layer.enclosingRepaintTargetLayer(WebCore.ExcludeSelf) else {
            return
        }

        var repaintRect = rect
        repaintRect.move(layer.offsetFromAncestor(compositedAncestor, WebCore.RenderLayer.DontAdjustForColumns))
        compositedAncestor.setBackingNeedsRepaintInRect(repaintRect, .Clip)

        // The contents of this layer may be moving from a GraphicsLayer to the window,
        // so we need to make sure the window system synchronizes those changes on the screen.
        if compositedAncestor.isRenderViewLayer() {
            m_renderView.get().frameView().setNeedsOneShotDrawingSynchronization()
        }
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func shouldCompositeOverflowControls() -> Bool {
        let frameView = m_renderView.get().frameView()

        if !frameView.managesScrollbars() {
            return false
        }

        if documentUsesTiledBacking() {
            return true
        }

        if overflowControlsHostLayer() != nil && isRootFrameCompositor() {
            return true
        }

        #if !USE_COORDINATED_GRAPHICS // !USE(COORDINATED_GRAPHICS)
        if !m_renderView.get().frameView().hasOverlayScrollbarsForSwift() {
            return false
        }
        #endif

        return true
    }

    @cxx
    @implementation
    public func requiresHorizontalScrollbarLayer() -> Bool {
        shouldCompositeOverflowControls() && m_renderView.get().frameView().horizontalScrollbar() != nil
    }

    @cxx
    @implementation
    public func requiresVerticalScrollbarLayer() -> Bool {
        shouldCompositeOverflowControls() && m_renderView.get().frameView().verticalScrollbar() != nil
    }

    @cxx
    @implementation
    public func requiresScrollCornerLayer() -> Bool {
        shouldCompositeOverflowControls() && m_renderView.get().frameView().isScrollCornerVisible()
    }

    #if os(macOS) // HAVE(RUBBER_BANDING)
    @cxx
    @implementation
    public func requiresOverhangAreasLayer() -> Bool {
        if !isMainFrameCompositor() {
            return false
        }

        // We do want a layer if we're using tiled drawing and can scroll.
        let frameView = m_renderView.get().frameView()
        if documentUsesTiledBacking() && frameView.hasOpaqueBackground() && !frameView.prohibitsScrolling() {
            return true
        }

        return false
    }
    #endif
}

extension WebCore.RenderLayerCompositor {
    #if os(macOS) // HAVE(RUBBER_BANDING)
    @cxx
    @implementation
    public func requiresContentShadowLayer() -> Bool {
        if !isMainFrameCompositor() {
            return false
        }

        #if canImport(Darwin) // PLATFORM(COCOA)
        if viewHasTransparentBackgroundForSwift() {
            return false
        }

        // If the background is going to extend, then it doesn't make sense to have a shadow layer.
        if m_renderView.get().settings().backgroundShouldExtendBeyondPage() {
            return false
        }

        // On Mac, we want a content shadow layer if we're using tiled drawing and can scroll.
        if documentUsesTiledBacking() && !m_renderView.get().frameView().prohibitsScrolling() {
            return true
        }
        #endif

        return false
    }

    @cxx
    @implementation
    public func updateLayerForTopOverhangImage(_ wantsLayer: Bool) {
        if !isMainFrameCompositor() {
            return
        }

        if !wantsLayer {
            unparentAndClearGraphicsLayer(.TopOverhangImage)
            return
        }

        if layerForTopOverhangImage() == nil {
            createGraphicsLayer(.TopOverhangImage, .Normal)
            scrolledContentsLayer()!.addChildBelowForSwift(layerForTopOverhangImage()!, rootContentsLayer())
        }
    }

    @cxx
    @implementation
    public func updateLayerForTopOverhangColorExtension(_ wantsLayer: Bool) {
        if !isMainFrameCompositor() {
            return
        }

        if !wantsLayer {
            unparentAndClearGraphicsLayer(.TopOverhangColorExtension)
            return
        }

        if layerForTopOverhangColorExtension() == nil {
            createGraphicsLayer(.TopOverhangColorExtension, .Normal)
            let layer = layerForTopOverhangColorExtension()!
            layer.setDrawsContent(false)
            scrolledContentsLayer()!.addChildBelowForSwift(layer, layerForTopOverhangImage() ?? rootContentsLayer())
        }
    }

    @cxx
    @implementation
    public func updateLayerForBottomOverhangArea(_ wantsLayer: Bool) {
        if !isMainFrameCompositor() {
            return
        }

        if !wantsLayer {
            unparentAndClearGraphicsLayer(.BottomOverhang)
            return
        }

        if layerForBottomOverhangArea() == nil {
            createGraphicsLayer(.BottomOverhang, .Normal)
            scrolledContentsLayer()!.addChildBelowForSwift(layerForBottomOverhangArea()!, rootContentsLayer())
        }

        let frameView = m_renderView.get().frameView()
        layerForBottomOverhangArea()!
            .setPosition(
                WebCore.FloatPoint(
                    0,
                    rootContentsLayer()!.sizeForSwift().height() + Float(frameView.headerHeight())
                        + Float(frameView.footerHeight()) + frameView.obscuredContentInsetTopForSwift()
                )
            )
    }

    @cxx
    @implementation
    public func updateLayerForHeader(_ wantsLayer: Bool) {
        if !isMainFrameCompositor() {
            return
        }

        if !wantsLayer {
            if headerLayer() != nil {
                unparentAndClearGraphicsLayer(.Header)

                // The ScrollingTree knows about the header layer, and the position of the root layer is affected
                // by the header layer, so if we remove the header, we need to tell the scrolling tree.
                if let scrollingCoordinator = scrollingCoordinator() {
                    scrollingCoordinator.frameViewRootLayerDidChange(m_renderView.get().frameView())
                }
            }
            return
        }

        if headerLayer() == nil {
            createGraphicsLayer(.Header, .Normal)
            scrolledContentsLayer()!.addChildAboveForSwift(headerLayer()!, rootContentsLayer())
        }

        let frameView = m_renderView.get().frameView()
        let headerLayer = self.headerLayer()!
        headerLayer.setPosition(
            WebCore.FloatPoint(
                0,
                WebCore.LocalFrameView.yPositionForHeaderLayer(
                    WebCore.FloatPoint(frameView.scrollPosition()),
                    frameView.obscuredContentInsetTopForSwift()
                )
            )
        )
        headerLayer.setAnchorPoint(WebCore.FloatPoint3D())
        headerLayer.setSize(WebCore.FloatSize(Float(frameView.visibleSize().width()), Float(frameView.headerHeight())))

        if let scrollingCoordinator = scrollingCoordinator() {
            scrollingCoordinator.frameViewRootLayerDidChange(frameView)
        }

        chromeClientDidAddHeaderLayer(headerLayer)
    }

    @cxx
    @implementation
    public func updateLayerForFooter(_ wantsLayer: Bool) {
        if !isMainFrameCompositor() {
            return
        }

        let frameView = m_renderView.get().frameView()

        if !wantsLayer {
            if footerLayer() != nil {
                unparentAndClearGraphicsLayer(.Footer)

                // The ScrollingTree knows about the footer layer, and the total scrollable size is affected
                // by the footer layer, so if we remove the footer, we need to tell the scrolling tree.
                if let scrollingCoordinator = scrollingCoordinator() {
                    scrollingCoordinator.frameViewRootLayerDidChange(frameView)
                }
            }
            return
        }

        if footerLayer() == nil {
            createGraphicsLayer(.Footer, .Normal)
            scrolledContentsLayer()!.addChildAboveForSwift(footerLayer()!, rootContentsLayer())
        }

        let footerLayer = self.footerLayer()!
        let totalContentHeight =
            rootContentsLayer()!.sizeForSwift().height() + Float(frameView.headerHeight()) + Float(frameView.footerHeight())
        footerLayer.setPosition(
            WebCore.FloatPoint(
                0,
                WebCore.LocalFrameView.yPositionForFooterLayer(
                    WebCore.FloatPoint(frameView.scrollPosition()),
                    frameView.obscuredContentInsetTopForSwift(),
                    totalContentHeight,
                    Float(frameView.footerHeight())
                )
            )
        )
        footerLayer.setAnchorPoint(WebCore.FloatPoint3D())
        footerLayer.setSize(WebCore.FloatSize(Float(frameView.visibleSize().width()), Float(frameView.footerHeight())))

        if let scrollingCoordinator = scrollingCoordinator() {
            scrollingCoordinator.frameViewRootLayerDidChange(frameView)
        }

        chromeClientDidAddFooterLayer(footerLayer)
    }

    @cxx
    @implementation
    public func updateLayerForOverhangAreasBackgroundColor() {
        guard let layer = layerForOverhangAreas() else {
            return
        }

        if m_renderView.get().settings().backgroundShouldExtendBeyondPage() {
            let underPageBackgroundColorOverride = page().underPageBackgroundColorOverride()
            let backgroundColor =
                underPageBackgroundColorOverride.isValid() ? underPageBackgroundColorOverride : m_rootExtendedBackgroundColor
            layer.setBackgroundColor(backgroundColor)
        }
    }

    @cxx
    @implementation
    public func updateSizeAndPositionForOverhangAreaLayer() {
        guard let layer = layerForOverhangAreas() else {
            return
        }

        let frameView = m_renderView.get().frameView()
        let insetLeft = frameView.obscuredContentInsetLeftForSwift()
        let insetTop = frameView.obscuredContentInsetTopForSwift()
        var overhangAreaSize = frameView.frameRect().size()
        // FIXME: Handle bottom and right insets too.
        overhangAreaSize.contract(Int32(insetLeft), Int32(insetTop))
        overhangAreaSize.clampNegativeToZero()
        layer.setSize(WebCore.FloatSize(overhangAreaSize))
        layer.setPosition(WebCore.FloatPoint(insetLeft, insetTop))
    }

    @cxx
    @implementation
    public func updateSizeAndPositionForTopOverhangColorExtensionLayer() {
        guard let layer = layerForTopOverhangColorExtension() else {
            return
        }

        let frameView = m_renderView.get().frameView()
        let layerSize = WebCore.IntSize(frameView.contentsSize().width(), frameView.visibleSize().height())
        layer.setSize(WebCore.FloatSize(layerSize))

        let rootLayerPosition = frameView.positionForRootContentLayer()
        layer.setPosition(WebCore.FloatPoint(rootLayerPosition.x(), rootLayerPosition.y() - Float(layerSize.height())))
    }
    #endif

    @cxx
    @implementation
    public func updateRootLayerPosition() {
        if let rootContentsLayer = rootContentsLayer() {
            let frameView = m_renderView.get().frameView()
            rootContentsLayer.setSize(WebCore.FloatSize(frameView.contentsSize()))
            rootContentsLayer.setPosition(frameView.positionForRootContentLayer())
            rootContentsLayer.setAnchorPoint(WebCore.FloatPoint3D())
        }

        updateScrollLayerClipping()

        #if os(macOS) // HAVE(RUBBER_BANDING)
        if let contentShadowLayer = layerForContentShadow(), let rootContentsLayer = rootContentsLayer() {
            contentShadowLayer.setPosition(rootContentsLayer.positionForSwift())
            contentShadowLayer.setSize(rootContentsLayer.sizeForSwift())
        }

        var wantsLayer = layerForTopOverhangColorExtension() != nil
        var cachedTopColor = WebCore.Color()
        if !wantsLayer {
            cachedTopColor = fixedContainerEdgesTopColor()
            wantsLayer = cachedTopColor.isVisible()
        }

        updateLayerForTopOverhangColorExtension(wantsLayer)
        if let layer = layerForTopOverhangColorExtension() {
            if cachedTopColor.isVisible() {
                layer.setBackgroundColor(cachedTopColor)
            }
        }

        updateSizeAndPositionForTopOverhangColorExtensionLayer()
        updateLayerForTopOverhangImage(layerForTopOverhangImage() != nil)
        updateLayerForBottomOverhangArea(layerForBottomOverhangArea() != nil)
        updateLayerForHeader(headerLayer() != nil)
        updateLayerForFooter(footerLayer() != nil)
        #endif
    }

    @cxx
    @implementation
    public func updateOverflowControlsLayers() {
        #if os(macOS) // HAVE(RUBBER_BANDING)
        if requiresOverhangAreasLayer() {
            if layerForOverhangAreas() == nil {
                createGraphicsLayer(.OverhangAreas, .Normal)
                let layer = layerForOverhangAreas()!
                layer.setDrawsContent(false)

                updateSizeAndPositionForOverhangAreaLayer()
                layer.setAnchorPoint(WebCore.FloatPoint3D())
                updateLayerForOverhangAreasBackgroundColor()

                // We want the overhang areas layer to be positioned below the frame contents,
                // so insert it below the clip layer.
                overflowControlsHostLayer()!.addChildBelowForSwift(layer, layerForClipping())
            }
        } else {
            unparentAndClearGraphicsLayer(.OverhangAreas)
        }

        if requiresContentShadowLayer() {
            if layerForContentShadow() == nil {
                createGraphicsLayer(.ContentShadow, .Normal)
                let layer = layerForContentShadow()!
                let rootContentsLayer = self.rootContentsLayer()!
                layer.setSize(rootContentsLayer.sizeForSwift())
                layer.setPosition(rootContentsLayer.positionForSwift())
                layer.setAnchorPoint(WebCore.FloatPoint3D())
                layer.setCustomAppearance(.ScrollingShadow)

                scrolledContentsLayer()!.addChildBelowForSwift(layer, rootContentsLayer)
            }
        } else {
            unparentAndClearGraphicsLayer(.ContentShadow)
        }
        #endif

        if requiresHorizontalScrollbarLayer() {
            if layerForHorizontalScrollbar() == nil {
                createGraphicsLayer(.HorizontalScrollbarContainer, .Normal)
                let layer = layerForHorizontalScrollbar()!
                layer.setAllowsBackingStoreDetaching(false)
                layer.setAllowsTiling(false)
                layer.setShowDebugBorder(m_showDebugBorders)
                #if canImport(Darwin) // USE(CA)
                layer.setAcceleratesDrawing(acceleratedDrawingEnabled())
                #endif
                overflowControlsHostLayer()!.addChildForSwift(layer)

                frameViewScrollbarLayerDidChange(.Horizontal)
            }
        } else if layerForHorizontalScrollbar() != nil {
            unparentAndClearGraphicsLayer(.HorizontalScrollbarContainer)

            frameViewScrollbarLayerDidChange(.Horizontal)
        }

        if requiresVerticalScrollbarLayer() {
            if layerForVerticalScrollbar() == nil {
                createGraphicsLayer(.VerticalScrollbarContainer, .Normal)
                let layer = layerForVerticalScrollbar()!
                layer.setAllowsBackingStoreDetaching(false)
                layer.setAllowsTiling(false)
                layer.setShowDebugBorder(m_showDebugBorders)
                #if canImport(Darwin) // USE(CA)
                layer.setAcceleratesDrawing(acceleratedDrawingEnabled())
                #endif
                overflowControlsHostLayer()!.addChildForSwift(layer)

                frameViewScrollbarLayerDidChange(.Vertical)
            }
        } else if layerForVerticalScrollbar() != nil {
            unparentAndClearGraphicsLayer(.VerticalScrollbarContainer)

            frameViewScrollbarLayerDidChange(.Vertical)
        }

        if requiresScrollCornerLayer() {
            if layerForScrollCorner() == nil {
                createGraphicsLayer(.ScrollCorner, .Normal)
                let layer = layerForScrollCorner()!
                layer.setAllowsBackingStoreDetaching(false)
                layer.setShowDebugBorder(m_showDebugBorders)
                #if canImport(Darwin) // USE(CA)
                layer.setAcceleratesDrawing(acceleratedDrawingEnabled())
                #endif
                overflowControlsHostLayer()!.addChildForSwift(layer)
            }
        } else {
            unparentAndClearGraphicsLayer(.ScrollCorner)
        }

        m_renderView.get().frameView().positionScrollbarLayers()
    }

    @cxx
    @implementation
    public func ensureRootLayer() {
        let expectedAttachment =
            isRootFrameCompositor()
            ? WebCore.RenderLayerCompositor.RootLayerAttachedViaChromeClient
            : WebCore.RenderLayerCompositor.RootLayerAttachedViaEnclosingFrame
        if expectedAttachment == m_rootLayerAttachment {
            return
        }

        if rootContentsLayer() == nil {
            createGraphicsLayer(.ContentRoot, .Normal)
            let rootContentsLayer = self.rootContentsLayer()!
            let overflowRect = WebCore.snappedIntRect(m_renderView.get().layoutOverflowRect())
            rootContentsLayer.setSize(WebCore.FloatSize(Float(overflowRect.maxX()), Float(overflowRect.maxY())))
            rootContentsLayer.setPosition(WebCore.FloatPoint())

            updateRootContentsLayerAppliesPageScale()

            // Need to clip to prevent transformed content showing outside this frame
            updateRootContentLayerClipping()
            updateRootContentsLayerBackgroundColor()
        }

        if requiresScrollLayer(expectedAttachment) {
            if overflowControlsHostLayer() == nil {
                // Create a layer to host the clipping layer and the overflow controls layers.
                createGraphicsLayer(.OverflowControlsHost, .Normal)
                let overflowControlsHostLayer = self.overflowControlsHostLayer()!

                createGraphicsLayer(.FrameScrolledContents, .ScrolledContents)
                let scrolledContentsLayer = self.scrolledContentsLayer()!
                scrolledContentsLayer.setAnchorPoint(WebCore.FloatPoint3D())

                #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
                if m_renderView.get().settings().asyncFrameScrollingEnabled() {
                    createGraphicsLayer(.ScrollContainer, .ScrollContainer)
                    let scrollContainerLayer = self.scrollContainerLayer()!

                    scrollContainerLayer.setMasksToBounds(true)
                    scrollContainerLayer.setAnchorPoint(WebCore.FloatPoint3D())

                    scrollContainerLayer.addChildForSwift(scrolledContentsLayer)
                    overflowControlsHostLayer.addChildForSwift(scrollContainerLayer)
                }
                #endif
                // FIXME: m_scrollContainerLayer and m_clipLayer have similar roles here, but m_clipLayer has some special positioning to
                // account for clipping and top content inset (see LocalFrameView::insetClipLayerRect()).
                if scrollContainerLayer() == nil {
                    createGraphicsLayer(.FrameClipping, .Normal)
                    let clipLayer = self.clipLayer()!
                    clipLayer.setMasksToBounds(true)
                    clipLayer.setAnchorPoint(WebCore.FloatPoint3D())

                    clipLayer.addChildForSwift(scrolledContentsLayer)
                    overflowControlsHostLayer.addChildForSwift(clipLayer)
                }

                scrolledContentsLayer.addChildForSwift(rootContentsLayer()!)

                updateScrollLayerClipping()
                updateOverflowControlsLayers()

                if hasCoordinatedScrolling() {
                    scheduleRenderingUpdate()
                } else {
                    updateScrollLayerPosition()
                }
            }
        } else {
            if overflowControlsHostLayer() != nil {
                unparentAndClearGraphicsLayer(.OverflowControlsHost)
                unparentAndClearGraphicsLayer(.FrameClipping)
                unparentAndClearGraphicsLayer(.ScrollContainer)
                unparentAndClearGraphicsLayer(.FrameScrolledContents)
            }
        }

        // Check to see if we have to change the attachment
        if m_rootLayerAttachment != WebCore.RenderLayerCompositor.RootLayerUnattached {
            detachRootLayer()
        }

        attachRootLayer(expectedAttachment)
    }

    @cxx
    @implementation
    public func destroyRootLayer() {
        if rootContentsLayer() == nil {
            return
        }

        detachRootLayer()

        #if os(macOS) // HAVE(RUBBER_BANDING)
        unparentAndClearGraphicsLayer(.OverhangAreas)
        #endif

        let frameView = m_renderView.get().frameView()

        if layerForHorizontalScrollbar() != nil {
            unparentAndClearGraphicsLayer(.HorizontalScrollbarContainer)
            frameViewScrollbarLayerDidChange(.Horizontal)
            if let horizontalScrollbar = frameView.horizontalScrollbar() {
                frameView.invalidateScrollbarForSwift(
                    horizontalScrollbar,
                    WebCore.IntRect(WebCore.IntPoint(0, 0), horizontalScrollbar.frameRect().size())
                )
            }
        }

        if layerForVerticalScrollbar() != nil {
            unparentAndClearGraphicsLayer(.VerticalScrollbarContainer)
            frameViewScrollbarLayerDidChange(.Vertical)
            if let verticalScrollbar = frameView.verticalScrollbar() {
                frameView.invalidateScrollbarForSwift(
                    verticalScrollbar,
                    WebCore.IntRect(WebCore.IntPoint(0, 0), verticalScrollbar.frameRect().size())
                )
            }
        }

        if layerForScrollCorner() != nil {
            unparentAndClearGraphicsLayer(.ScrollCorner)
            frameView.invalidateScrollCornerForSwift(frameView.scrollCornerRect())
        }

        if overflowControlsHostLayer() != nil {
            unparentAndClearGraphicsLayer(.OverflowControlsHost)
            unparentAndClearGraphicsLayer(.FrameClipping)
            unparentAndClearGraphicsLayer(.ScrollContainer)
            unparentAndClearGraphicsLayer(.FrameScrolledContents)
        }
        unparentAndClearGraphicsLayer(.ContentRoot)
    }

    @cxx
    @implementation
    public func attachRootLayer(_ attachment: WebCore.RenderLayerCompositor.RootLayerAttachment) {
        if rootContentsLayer() == nil {
            return
        }

        if attachment == WebCore.RenderLayerCompositor.RootLayerAttachedViaChromeClient {
            attachRootGraphicsLayerViaChromeClient(rootGraphicsLayer())
        } else if attachment == WebCore.RenderLayerCompositor.RootLayerAttachedViaEnclosingFrame {
            // The layer will get hooked up via RenderLayerBacking::updateConfiguration()
            // for the frame's renderer in the parent document.
            if let ownerElement = m_renderView.get().document().ownerElement() {
                ownerElement.scheduleInvalidateStyleAndLayerComposition()
                if let renderer = ownerElement.renderer() {
                    renderer.repaint()
                }
            }
        }

        m_rootLayerAttachment = attachment
        rootLayerAttachmentChanged()

        if m_shouldFlushOnReattach {
            scheduleRenderingUpdate()
            m_shouldFlushOnReattach = false
        }
    }

    @cxx
    @implementation
    public func detachRootLayer() {
        if rootContentsLayer() == nil || m_rootLayerAttachment == WebCore.RenderLayerCompositor.RootLayerUnattached {
            return
        }

        if let scrollingCoordinator = scrollingCoordinator() {
            scrollingCoordinator.frameViewWillBeDetached(m_renderView.get().frameView())
        }

        if m_rootLayerAttachment == WebCore.RenderLayerCompositor.RootLayerAttachedViaEnclosingFrame {
            // The layer will get unhooked up via RenderLayerBacking::updateConfiguration()
            // for the frame's renderer in the parent document.
            if let layer = overflowControlsHostLayer() {
                layer.removeFromParent()
            } else {
                rootContentsLayer()!.removeFromParent()
            }

            if let ownerElement = m_renderView.get().document().ownerElement() {
                ownerElement.scheduleInvalidateStyleAndLayerComposition()
            }

            if let frameRootScrollingNodeID = m_renderView.get().frameView().scrollingNodeID().value {
                if let scrollingCoordinator = scrollingCoordinator() {
                    scrollingCoordinator.frameViewWillBeDetached(m_renderView.get().frameView())
                    scrollingCoordinator.unparentNode(frameRootScrollingNodeID)
                }
            }
        } else if m_rootLayerAttachment == WebCore.RenderLayerCompositor.RootLayerAttachedViaChromeClient {
            if let scrollingCoordinator = scrollingCoordinator() {
                scrollingCoordinator.frameViewWillBeDetached(m_renderView.get().frameView())
            }
            attachRootGraphicsLayerViaChromeClient(nil)
        }

        m_rootLayerAttachment = WebCore.RenderLayerCompositor.RootLayerUnattached
        rootLayerAttachmentChanged()
    }

    @cxx
    @implementation
    public func updateRootLayerAttachment() {
        ensureRootLayer()
    }

    @cxx
    @implementation
    public func rootLayerAttachmentChanged() {
        // The document-relative page overlay layer (which is pinned to the root frame's layer tree)
        // is moved between different RenderLayerCompositors' layer trees, and needs to be
        // reattached whenever we swap in a new RenderLayerCompositor.
        if m_rootLayerAttachment == WebCore.RenderLayerCompositor.RootLayerUnattached {
            return
        }

        // The attachment can affect whether the RenderView layer's paintsIntoWindow() behavior,
        // so call updateDrawsContent() to update that.
        if let layer = m_renderView.get().layer(), let backing = layer.backing() {
            backing.updateDrawsContent()
        }

        // Host the document overlay in the root frame's layer tree. Under Site Isolation the main frame
        // can be remote here, so the local root frame owns the compositing tree that reaches the screen
        // (isRootFrameCompositor(), matching documentOverlayHostLayer()). Gating on isMainFrame() would
        // orphan the overlay in a subframe process across a root-layer re-attach.
        if !isRootFrameCompositor() {
            return
        }

        let overlayHost = layerWithDocumentOverlays()
        rootContentsLayer()!.addChildForSwift(overlayHost)
    }

    @cxx
    @implementation
    public func notifyIFramesOfCompositingChange() {
        // Compositing affects the answer to RenderIFrame::requiresAcceleratedCompositing(), so
        // we need to schedule a style recalc in our parent document.
        if let ownerElement = m_renderView.get().document().ownerElement() {
            ownerElement.scheduleInvalidateStyleAndLayerComposition()
        }
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func rootBackgroundColorOrTransparencyChanged() {
        if !usesCompositing() {
            return
        }

        var backgroundColor = WebCore.Color()
        let isTransparent = viewHasTransparentBackgroundForSwift(&backgroundColor)

        let extendedBackgroundColor = m_renderView.get().settings().backgroundShouldExtendBeyondPage() ? backgroundColor : WebCore.Color()

        let transparencyChanged = m_viewBackgroundIsTransparent != isTransparent
        let backgroundColorChanged = !(m_viewBackgroundColor == backgroundColor)
        let extendedBackgroundColorChanged = !(m_rootExtendedBackgroundColor == extendedBackgroundColor)

        if !transparencyChanged && !backgroundColorChanged && !extendedBackgroundColorChanged {
            return
        }

        m_viewBackgroundIsTransparent = isTransparent
        m_viewBackgroundColor = backgroundColor
        m_rootExtendedBackgroundColor = extendedBackgroundColor

        if extendedBackgroundColorChanged {
            chromeClientPageExtendedBackgroundColorDidChange()

            #if os(macOS) // HAVE(RUBBER_BANDING)
            updateLayerForOverhangAreasBackgroundColor()
            #endif
            updateRootContentsLayerBackgroundColor()
        }

        rootLayerConfigurationChanged()
    }

    @cxx
    @implementation
    public func updateEventRegions() {
        var isProhibitedFrame = false
        if let ownerElement = m_renderView.get().document().ownerElement() {
            isProhibitedFrame = ownerElement.renderer() == nil
        }
        if isProhibitedFrame {
            return
        }

        updateEventRegionsRecursive(m_renderView.get().layer()!)
        m_renderView.get().setNeedsEventRegionUpdateForNonCompositedFrame(false)
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func updateRootContentLayerClipping() {
        rootContentsLayer()!.setMasksToBounds(!m_renderView.get().settings().backgroundShouldExtendBeyondPage())
    }

    @cxx
    @implementation
    public func updateRootContentsLayerAppliesPageScale() {
        guard let rootContentsLayer = rootContentsLayer(), m_renderView.get().frameView().frame().isRootFrame() else {
            return
        }

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
        // iOS always delegates scaling. Page::delegatesScaling() isn't set until didCommitLoad, so it would read
        // false for a layer created before then.
        let appliesPageScale = true
        #else
        // This layer intercepts pageScaleFactor() when scaling is delegated, so tiles rasterize at the zoomed
        // resolution. The scale is baked into the RenderView layer's geometry otherwise.
        let appliesPageScale = page().delegatesScaling()
        #endif

        rootContentsLayer.setAppliesPageScale(appliesPageScale)
    }

    @cxx
    @implementation
    public func hasCoordinatedScrolling() -> Bool {
        guard let scrollingCoordinator = scrollingCoordinator() else {
            return false
        }
        return scrollingCoordinator.coordinatesScrollingForFrameView(m_renderView.get().frameView())
    }

    @cxx
    @implementation
    public func frameViewFixedObjectsDidChange() {
        if let scrollingCoordinator = scrollingCoordinator() {
            scrollingCoordinator.frameViewFixedObjectsDidChange(m_renderView.get().frameView())
        }
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func canRender3DTransforms() -> Bool {
        hasAcceleratedCompositing() && hasCompositingTrigger(.ThreeDTransform)
    }

    @cxx
    @implementation
    public func willRecalcStyle() {
        cacheAcceleratedCompositingFlags()
    }

    @cxx
    @implementation
    public func didRecalcStyleWithNoPendingLayout() -> Bool {
        updateCompositingLayers(.AfterStyleChange, nil)
    }

    @cxx
    @implementation
    public func updateCompositingLayersTimerFired() {
        _ = updateCompositingLayers(.AfterLayout, nil)
    }

    @cxx
    @implementation
    public func notifyFlushRequired(_ layer: WebCore.GraphicsLayer?) {
        scheduleRenderingUpdate()
    }

    @cxx
    @implementation
    public func backdropRootIsOpaque(_ layer: WebCore.GraphicsLayer?) -> Bool {
        if !WebCore.RenderLayerCompositor.isSameGraphicsLayer(layer, rootGraphicsLayer()) {
            return false
        }

        return !viewHasTransparentBackgroundForSwift()
    }

    @cxx
    @implementation
    public func didPaintBacking(_ backing: WebCore.RenderLayerBacking?) {
        let frameView = m_renderView.get().frameView()
        frameView.setLastPaintTime(WTF.MonotonicTime.now())
        if !frameView.milestonesPendingPaint().isEmpty() {
            frameView.firePaintRelatedMilestonesIfNeeded()
        }
    }

    @cxx
    @implementation
    public func deviceScaleFactor() -> Float {
        page().deviceScaleFactor()
    }

    @cxx
    @implementation
    public func zoomedOutPageScaleFactor() -> Float {
        page().zoomedOutPageScaleFactor()
    }

    @cxx
    @implementation
    public func isRootFrameCompositor() -> Bool {
        m_renderView.get().frameView().frame().isRootFrame()
    }

    @cxx
    @implementation
    public func isMainFrameCompositor() -> Bool {
        m_renderView.get().frameView().frame().isMainFrame()
    }

    @cxx
    @implementation
    public func visualUpdatesAllowed() -> Bool {
        m_renderView.get().document().visualUpdatesAllowed()
    }

    @cxx
    @implementation
    public func viewNeedsToInvalidateEventRegionOfEnclosingCompositingLayerForRepaint() -> Bool {
        // Event regions are only updated on compositing layers. Non-composited layers must
        // delegate to their enclosing compositing layer for repaint to update the event region
        // for elements inside them.
        !m_renderView.get().isComposited()
    }

    @cxx
    @implementation
    public func deviceOrPageScaleFactorChanged() {
        // Page scale will only be applied at to the RenderView and sublayers, but the device scale factor
        // needs to be applied at the level of rootGraphicsLayer().
        if let rootLayer = rootGraphicsLayer() {
            rootLayer.noteDeviceOrPageScaleFactorChangedIncludingDescendants()
        }
    }

    @cxx
    @implementation
    public func hasSubscrollers() -> Bool {
        guard let scrollingCoordinator = scrollingCoordinator() else {
            return false
        }
        return scrollingCoordinator.hasSubscrollers(m_renderView.get().frame().rootFrame().frameID())
    }

    @cxx
    @implementation
    public func updateScrollLayerPosition() {
        let frameView = m_renderView.get().frameView()
        let scrollPosition = frameView.scrollPosition()

        // We use scroll position here because the root content layer is offset to account for scrollOrigin (see
        // LocalFrameView::positionForRootContentLayer).
        // Wraps at INT_MIN, as int negation does in practice.
        scrolledContentsLayer()!.setPosition(WebCore.FloatPoint(Float(0 &- scrollPosition.x()), Float(0 &- scrollPosition.y())))

        if let fixedBackgroundLayer = fixedRootBackgroundLayer() {
            let position = frameView.scrollPositionForFixedPosition()
            fixedBackgroundLayer.setPosition(WebCore.FloatPoint(position.x().toFloat(), position.y().toFloat()))
        }
    }
}

// MARK: Scrolling coordination

// What a scrolling node update refreshes: the node's GraphicsLayers, and its geometry.
private struct ScrollingNodeChangeFlags {
    var layer: Bool
    var layerGeometry: Bool
}

private func scrollCoordinationRoleForNodeType(_ nodeType: WebCore.ScrollingNodeType) -> WebCore.ScrollCoordinationRole {
    switch nodeType {
    case .MainFrame, .Subframe, .Overflow, .PluginScrolling:
        return .Scrolling
    case .OverflowProxy:
        return .ScrollingProxy
    case .FrameHosting:
        return .FrameHosting
    case .PluginHosting:
        return .PluginHosting
    case .Fixed, .Sticky:
        return .ViewportConstrained
    case .Positioned:
        return .Positioning
    default:
        assertionFailure()
        return .Scrolling
    }
}

private func optionalNodeID(_ nodeID: WebCore.ScrollingNodeID?) -> WebCore.OptionalScrollingNodeID {
    guard let nodeID else {
        return .init()
    }
    return .init(nodeID)
}

extension WebCore.RenderLayerCompositor {
    private func setNodeLayer(
        _ scrollingCoordinator: WebCore.ScrollingCoordinator,
        _ nodeID: WebCore.ScrollingNodeID,
        _ layer: WebCore.GraphicsLayer?
    ) {
        scrollingCoordinator.setNodeLayers(nodeID, layer: layer)
    }

    // Takes the backing, not its layer: the backing's willBeDestroyed() calls this while its layer is destroyed, and Swift
    // retains a layer it is passed.
    @cxx
    @implementation
    public func removeFromScrollCoordinatedLayers(_ backing: WebCore.RenderLayerBacking) {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
        removeFromLegacyScrollingLayerCoordinator(backing)
        #endif

        detachScrollCoordinatedBacking(backing, WebCore.allScrollCoordinationRoles())
    }

    @cxx
    @implementation
    public func unparentChildrenAndDestroyScrollingNode(_ nodeID: WebCore.ScrollingNodeID) {
        guard let scrollingCoordinator = scrollingCoordinator() else {
            return
        }

        // The children's layers are paint-order descendants of the layer being updated, which has not yet decided
        // whether to traverse its descendants, so marking them is enough to get them reattached in this update.
        setNeedsScrollingTreeUpdateForChildrenOfNode(scrollingCoordinator, nodeID)
        removeScrollingNodeLayerForSwift(nodeID)
        scrollingCoordinator.unparentChildrenAndDestroyNode(.init(nodeID))
    }

    func updateScrollCoordinationForBackedLayer(
        _ layer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer?,
        _ scrollingTreeState: inout WebCore.ScrollingTreeState,
        _ scrollingStateForDescendants: inout WebCore.ScrollingTreeState,
        _ layerGeometryChanged: Bool
    ) {
        let scrollingNodeChanges = ScrollingNodeChangeFlags(layer: true, layerGeometry: layerGeometryChanged)

        scrollingStateForDescendants.setParentNodeIDForSwift(
            optionalNodeID(updateScrollCoordinationForLayer(layer, compositingAncestor, &scrollingTreeState, scrollingNodeChanges))
        )
        scrollingStateForDescendants.hasParent = true
        scrollingStateForDescendants.nextChildIndex = 0
    }

    static func mergeScrollingTreeStateFromDescendants(
        _ scrollingTreeState: inout WebCore.ScrollingTreeState,
        _ scrollingStateForDescendants: WebCore.ScrollingTreeState
    ) {
        if scrollingStateForDescendants.needSynchronousScrollingReasonsUpdate {
            scrollingTreeState.needSynchronousScrollingReasonsUpdate = true
        }
        if WebCore.RenderLayerCompositor.isSameScrollingNodeIDForSwift(
            scrollingTreeState.parentNodeIDForSwift(),
            scrollingStateForDescendants.parentNodeIDForSwift()
        ) {
            scrollingTreeState.nextChildIndex = scrollingStateForDescendants.nextChildIndex
        }
    }

    private func coordinatedScrollingRolesForLayer(
        _ layer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer?
    ) -> WebCore.ScrollCoordinationRoles {
        var coordinationRoles = WebCore.ScrollCoordinationRoles()
        if viewportConstrainedSublayers(layer, compositingAncestor) != .None {
            coordinationRoles.add(WebCore.ScrollCoordinationRoles(.ViewportConstrained))
        }

        if useCoordinatedScrollingForLayer(layer) {
            coordinationRoles.add(WebCore.ScrollCoordinationRoles(.Scrolling))
        }

        switch computeCoordinatedPositioningForLayer(layer, compositingAncestor) {
        case .Moves:
            coordinationRoles.add(WebCore.ScrollCoordinationRoles(.ScrollingProxy))
        case .Stationary:
            coordinationRoles.add(WebCore.ScrollCoordinationRoles(.Positioning))
        default:
            break
        }

        if isLayerForIFrameWithScrollCoordinatedContents(layer) {
            coordinationRoles.add(WebCore.ScrollCoordinationRoles(.FrameHosting))
        }

        if isLayerForPluginWithScrollCoordinatedContents(layer) {
            coordinationRoles.add(WebCore.ScrollCoordinationRoles(.PluginHosting))
        }

        return coordinationRoles
    }

    // Returns the ScrollingNodeID which acts as the parent for children.
    private func updateScrollCoordinationForLayer(
        _ layer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer?,
        _ treeState: inout WebCore.ScrollingTreeState,
        _ changes: ScrollingNodeChangeFlags
    ) -> WebCore.ScrollingNodeID? {
        let roles = coordinatedScrollingRolesForLayer(layer, compositingAncestor)

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
        updateLegacyViewportConstrainedLayer(layer, roles.contains(.ViewportConstrained))
        #endif

        if !hasCoordinatedScrolling() {
            // If this frame isn't coordinated, it cannot contain any scrolling tree nodes.
            return nil
        }

        // With no roles every branch below takes its detach path - short-cut and return the parent node ID.
        if roles.isEmpty() {
            guard let backing = layer.backing(), backing.hasAnyScrollingNodeID() else {
                return treeState.parentNodeIDForSwift().value
            }
        }

        var newNodeID = treeState.parentNodeIDForSwift().value

        // The state the next node attaches to: the caller's, until a node here becomes the parent of the rest.
        var childTreeState = WebCore.ScrollingTreeState()
        var attachesToChildTreeState = false
        func becomeParent(_ nodeID: WebCore.ScrollingNodeID?) {
            childTreeState.setParentNodeIDForSwift(optionalNodeID(nodeID))
            childTreeState.hasParent = true
            childTreeState.nextChildIndex = 0
            attachesToChildTreeState = true
        }

        // If there's a positioning node, it's the parent scrolling node for fixed/sticky/scrolling/frame hosting.
        if roles.contains(.Positioning) {
            newNodeID = updateScrollingNodeForPositioningRole(layer, compositingAncestor, &treeState, changes)
            becomeParent(newNodeID)
        } else {
            detachScrollCoordinatedLayer(layer, WebCore.ScrollCoordinationRoles(.Positioning))
        }

        // If there's a scrolling proxy node, it's the parent scrolling node for fixed/sticky/scrolling/frame hosting.
        if roles.contains(.ScrollingProxy) {
            if attachesToChildTreeState {
                newNodeID = updateScrollingNodeForScrollingProxyRole(layer, &childTreeState, changes)
            } else {
                newNodeID = updateScrollingNodeForScrollingProxyRole(layer, &treeState, changes)
            }
            becomeParent(newNodeID)
        } else {
            detachScrollCoordinatedLayer(layer, WebCore.ScrollCoordinationRoles(.ScrollingProxy))
        }

        // If is fixed or sticky, it's the parent scrolling node for scrolling/frame hosting.
        if roles.contains(.ViewportConstrained) {
            if attachesToChildTreeState {
                newNodeID = updateScrollingNodeForViewportConstrainedRole(layer, &childTreeState, changes)
            } else {
                newNodeID = updateScrollingNodeForViewportConstrainedRole(layer, &treeState, changes)
            }
            // ViewportConstrained nodes are the parent of same-layer scrolling nodes, so adjust the ScrollingTreeState.
            becomeParent(newNodeID)
        } else {
            detachScrollCoordinatedLayer(layer, WebCore.ScrollCoordinationRoles(.ViewportConstrained))
        }

        if roles.contains(.Scrolling) {
            if attachesToChildTreeState {
                newNodeID = updateScrollingNodeForScrollingRole(layer, &childTreeState, changes)
            } else {
                newNodeID = updateScrollingNodeForScrollingRole(layer, &treeState, changes)
            }
        } else {
            detachScrollCoordinatedLayer(layer, WebCore.ScrollCoordinationRoles(.Scrolling))
        }

        if roles.contains(.FrameHosting) {
            if attachesToChildTreeState {
                newNodeID = updateScrollingNodeForFrameHostingRole(layer, &childTreeState, changes)
            } else {
                newNodeID = updateScrollingNodeForFrameHostingRole(layer, &treeState, changes)
            }
        } else {
            detachScrollCoordinatedLayer(layer, WebCore.ScrollCoordinationRoles(.FrameHosting))
        }

        if roles.contains(.PluginHosting) {
            if attachesToChildTreeState {
                newNodeID = updateScrollingNodeForPluginHostingRole(layer, &childTreeState, changes)
            } else {
                newNodeID = updateScrollingNodeForPluginHostingRole(layer, &treeState, changes)
            }
        } else {
            detachScrollCoordinatedLayer(layer, WebCore.ScrollCoordinationRoles(.PluginHosting))
        }

        return newNodeID
    }

    private func attachScrollingNode(
        _ layer: WebCore.RenderLayer,
        _ nodeType: WebCore.ScrollingNodeType,
        _ treeState: inout WebCore.ScrollingTreeState
    ) -> WebCore.ScrollingNodeID? {
        guard let scrollingCoordinator = scrollingCoordinator() else {
            return nil
        }

        // Crash logs suggest that backing can be null here, but we don't know how: rdar://problem/18545452.
        guard let backing = layer.backing() else {
            assertionFailure()
            return nil
        }

        assert(treeState.hasParent || nodeType == .Subframe)
        assert(nodeType != .MainFrame || treeState.parentNodeIDForSwift().value == nil)

        let role = scrollCoordinationRoleForNodeType(nodeType)
        guard let nodeID = registerScrollingNodeID(scrollingCoordinator, backing.scrollingNodeIDForRole(role).value, nodeType, &treeState)
        else {
            return nil
        }

        backing.setScrollingNodeIDForRole(nodeID, role)

        #if os(macOS) || ENABLE_SCROLLING_THREAD // ENABLE(SCROLLING_THREAD)
        if nodeType == .Subframe {
            clipLayer()!.setScrollingNodeID(.init(nodeID))
        }
        #endif

        addScrollingNodeLayerForSwift(nodeID, layer)

        return nodeID
    }

    private func registerScrollingNodeID(
        _ scrollingCoordinator: WebCore.ScrollingCoordinator,
        _ existingNodeID: WebCore.ScrollingNodeID?,
        _ nodeType: WebCore.ScrollingNodeType,
        _ treeState: inout WebCore.ScrollingTreeState
    ) -> WebCore.ScrollingNodeID? {
        let nodeID = existingNodeID ?? scrollingCoordinator.uniqueScrollingNodeID()
        let rootFrameID = m_renderView.get().frame().rootFrame().frameID()

        var registeredNodeID: WebCore.ScrollingNodeID?
        if nodeType == .Subframe && !treeState.hasParent {
            registeredNodeID = scrollingCoordinator.createNode(rootFrameID, nodeType, nodeID).value
        } else {
            let newNodeID = scrollingCoordinator.insertNode(
                rootFrameID,
                nodeType,
                nodeID,
                treeState.parentNodeIDForSwift(),
                treeState.nextChildIndex
            )
            if !WebCore.RenderLayerCompositor.isSameScrollingNodeIDForSwift(newNodeID, .init(nodeID)) {
                // We'll get a new nodeID if the type changed (and not if the node is new).
                scrollingCoordinator.unparentChildrenAndDestroyNode(.init(nodeID))
                removeScrollingNodeLayerForSwift(nodeID)
            }
            registeredNodeID = newNodeID.value
        }

        guard let registeredNodeID else {
            assertionFailure()
            return nil
        }

        // A count of a node's children, which cannot reach Int.max.
        treeState.nextChildIndex &+= 1
        return registeredNodeID
    }

    private func detachScrollCoordinatedBackingWithRole(
        _ backing: WebCore.RenderLayerBacking,
        _ scrollingCoordinator: WebCore.ScrollingCoordinator,
        _ role: WebCore.ScrollCoordinationRole
    ) {
        func unregisterNode(_ nodeID: WebCore.ScrollingNodeID) {
            setNeedsScrollingTreeUpdateForChildrenOfNode(scrollingCoordinator, nodeID)
            removeScrollingNodeLayerForSwift(nodeID)
        }

        if role == .ScrollingProxy {
            for index in 0..<backing.ancestorClippingStackSizeForSwift() {
                if let proxyNodeID = backing.ancestorClippingStackProxyNodeIDForSwift(index).value {
                    unregisterNode(proxyNodeID)
                }
            }
            return
        }

        if let nodeID = backing.scrollingNodeIDForRole(role).value {
            unregisterNode(nodeID)
        }
    }

    private func detachScrollCoordinatedLayer(_ layer: WebCore.RenderLayer, _ roles: WebCore.ScrollCoordinationRoles) {
        guard let backing = layer.backing() else {
            return
        }

        detachScrollCoordinatedBacking(backing, roles)
    }

    private func detachScrollCoordinatedBacking(_ backing: WebCore.RenderLayerBacking, _ roles: WebCore.ScrollCoordinationRoles) {
        guard let scrollingCoordinator = scrollingCoordinator() else {
            return
        }

        if roles.contains(.Scrolling) {
            detachScrollCoordinatedBackingWithRole(backing, scrollingCoordinator, .Scrolling)
        }

        if roles.contains(.ScrollingProxy) {
            detachScrollCoordinatedBackingWithRole(backing, scrollingCoordinator, .ScrollingProxy)
        }

        if roles.contains(.FrameHosting) {
            detachScrollCoordinatedBackingWithRole(backing, scrollingCoordinator, .FrameHosting)
        }

        if roles.contains(.PluginHosting) {
            detachScrollCoordinatedBackingWithRole(backing, scrollingCoordinator, .PluginHosting)
        }

        if roles.contains(.ViewportConstrained) {
            detachScrollCoordinatedBackingWithRole(backing, scrollingCoordinator, .ViewportConstrained)
        }

        if roles.contains(.Positioning) {
            detachScrollCoordinatedBackingWithRole(backing, scrollingCoordinator, .Positioning)
        }

        backing.detachFromScrollingCoordinator(roles)
    }

    private func updateScrollingNodeForViewportConstrainedRole(
        _ layer: WebCore.RenderLayer,
        _ treeState: inout WebCore.ScrollingTreeState,
        _ changes: ScrollingNodeChangeFlags
    ) -> WebCore.ScrollingNodeID? {
        let scrollingCoordinator = scrollingCoordinator()

        var nodeType = WebCore.ScrollingNodeType.Fixed
        if layer.renderer()[.Style].position() == .Sticky {
            nodeType = .Sticky
        } else {
            assert(layer.renderer().isFixedPositioned())
        }

        guard let newNodeID = attachScrollingNode(layer, nodeType, &treeState) else {
            assertionFailure()
            return treeState.parentNodeIDForSwift().value
        }

        if changes.layer {
            let backing = layer.backing()!
            scrollingCoordinator!.setNodeLayers(
                newNodeID,
                layer: backing.viewportClippingOrAnchorLayer(),
                viewportAnchorLayer: backing.viewportAnchorLayer()
            )
        }

        if changes.layerGeometry {
            switch nodeType {
            case .Fixed:
                setFixedViewportConstraintsForSwift(scrollingCoordinator!, newNodeID, layer)
            case .Sticky:
                setStickyViewportConstraintsForSwift(scrollingCoordinator!, newNodeID, layer)
            default:
                break
            }
        }

        return newNodeID
    }

    @cxx
    @implementation
    public func updateScrollingNodeLayers(
        _ nodeID: WebCore.ScrollingNodeID,
        _ layer: WebCore.RenderLayer,
        _ scrollingCoordinator: WebCore.ScrollingCoordinator
    ) {
        // Plugins handle their own scrolling node layers.
        if isLayerForPluginWithScrollCoordinatedContents(layer) {
            return
        }

        if layer.isRenderViewLayer() {
            let frameView = m_renderView.get().frameView()
            scrollingCoordinator.setNodeLayers(
                nodeID,
                scrollContainerLayer: scrollContainerLayer(),
                scrolledContentsLayer: scrolledContentsLayer(),
                counterScrollingLayer: fixedRootBackgroundLayer(),
                insetClipLayer: clipLayer(),
                rootContentsLayer: rootContentsLayer(),
                horizontalScrollbarLayer: frameView.layerForHorizontalScrollbar(),
                verticalScrollbarLayer: frameView.layerForVerticalScrollbar()
            )
        } else {
            let scrollableArea = layer.scrollableArea()
            assert(scrollableArea != nil)

            let backing = layer.backing()!
            scrollingCoordinator.setNodeLayers(
                nodeID,
                layer: backing.graphicsLayer(),
                scrollContainerLayer: backing.scrollContainerLayer(),
                scrolledContentsLayer: backing.scrolledContentsLayer(),
                horizontalScrollbarLayer: scrollableArea!.layerForHorizontalScrollbar(),
                verticalScrollbarLayer: scrollableArea!.layerForVerticalScrollbar()
            )
        }
    }

    private func updateScrollingNodeForScrollingRole(
        _ layer: WebCore.RenderLayer,
        _ treeState: inout WebCore.ScrollingTreeState,
        _ changes: ScrollingNodeChangeFlags
    ) -> WebCore.ScrollingNodeID? {
        let scrollingCoordinator = scrollingCoordinator()

        if layer.isRenderViewLayer() {
            let frameView = m_renderView.get().frameView()
            assert(scrollingCoordinator!.coordinatesScrollingForFrameView(frameView))

            guard
                let newNodeID = attachScrollingNode(
                    m_renderView.get().layer()!,
                    m_renderView.get().frame().isMainFrame() ? .MainFrame : .Subframe,
                    &treeState
                )
            else {
                assertionFailure()
                return treeState.parentNodeIDForSwift().value
            }

            if changes.layer {
                updateScrollingNodeLayers(newNodeID, layer, scrollingCoordinator!)
            }

            if changes.layerGeometry {
                WebCore.RenderLayerCompositor.setScrollingNodeScrollableAreaGeometryForSwift(scrollingCoordinator!, newNodeID, frameView)
                scrollingCoordinator!.setFrameScrollingNodeState(newNodeID, frameView)
            }
            ensureScrollbarsControllerForSwift(frameView)
            return newNodeID
        }

        guard let newNodeID = attachScrollingNode(layer, .Overflow, &treeState) else {
            assertionFailure()
            return treeState.parentNodeIDForSwift().value
        }

        // Plugins handle their own scrolling node layers and geometry.
        if isLayerForPluginWithScrollCoordinatedContents(layer) {
            return newNodeID
        }

        if changes.layer {
            updateScrollingNodeLayers(newNodeID, layer, scrollingCoordinator!)
        }

        if changes.layerGeometry && treeState.hasParent {
            if let scrollableArea = layer.scrollableArea() {
                WebCore.RenderLayerCompositor.setScrollingNodeScrollableAreaGeometryForSwift(
                    scrollingCoordinator!,
                    newNodeID,
                    scrollableArea
                )
            }
        }
        if let scrollableArea = layer.scrollableArea() {
            ensureScrollbarsControllerForSwift(scrollableArea)
        }

        return newNodeID
    }

    private func updateScrollingNodeForScrollingProxyRole(
        _ layer: WebCore.RenderLayer,
        _ treeState: inout WebCore.ScrollingTreeState,
        _ changes: ScrollingNodeChangeFlags
    ) -> WebCore.ScrollingNodeID? {
        let scrollingCoordinator = scrollingCoordinator()
        let backing = layer.backing()!
        if !backing.hasAncestorClippingLayers() {
            return treeState.parentNodeIDForSwift().value
        }

        var nodeID: WebCore.ScrollingNodeID?
        for index in 0..<backing.ancestorClippingStackSizeForSwift() {
            if !backing.ancestorClippingStackEntryIsOverflowScrollForSwift(index) {
                continue
            }

            nodeID = registerScrollingNodeID(
                scrollingCoordinator!,
                backing.ancestorClippingStackProxyNodeIDForSwift(index).value,
                .OverflowProxy,
                &treeState
            )
            guard let proxyNodeID = nodeID else {
                assertionFailure()
                return treeState.parentNodeIDForSwift().value
            }
            backing.setAncestorClippingStackProxyNodeIDForSwift(index, proxyNodeID)
            addScrollingNodeLayerForSwift(proxyNodeID, layer)
            #if os(macOS) || ENABLE_SCROLLING_THREAD // ENABLE(SCROLLING_THREAD)
            if let scrollingLayer = backing.ancestorClippingStackScrollingLayerForSwift(index) {
                scrollingLayer.setScrollingNodeID(.init(proxyNodeID))
            }
            #endif

            if changes.layer {
                setNodeLayer(scrollingCoordinator!, proxyNodeID, backing.ancestorClippingStackScrollingLayerForSwift(index))
            }

            if changes.layerGeometry {
                let clippingLayer = backing.overflowScrollClippingLayerForSwift(index)!
                assert(clippingLayer.isComposited())

                if !setupScrollProxyRelatedOverflowScrollingNode(scrollingCoordinator!, proxyNodeID, clippingLayer) {
                    addLayerWithUnresolvedRelationsForSwift(layer)
                }
            }
        }

        // FIXME: also m_overflowControlsHostLayerAncestorClippingStack

        return nodeID ?? treeState.parentNodeIDForSwift().value
    }

    private func updateScrollingNodeForFrameHostingRole(
        _ layer: WebCore.RenderLayer,
        _ treeState: inout WebCore.ScrollingTreeState,
        _ changes: ScrollingNodeChangeFlags
    ) -> WebCore.ScrollingNodeID? {
        let scrollingCoordinator = scrollingCoordinator()

        guard let newNodeID = attachScrollingNode(layer, .FrameHosting, &treeState) else {
            assertionFailure()
            return treeState.parentNodeIDForSwift().value
        }

        if changes.layer {
            setNodeLayer(scrollingCoordinator!, newNodeID, layer.backing()!.graphicsLayer())
        }

        WebCore.RenderLayerCompositor.setLayerHostingContextIdentifierForSwift(scrollingCoordinator!, newNodeID, layer)
        return newNodeID
    }

    private func isLayerForIFrameWithScrollCoordinatedContents(_ layer: WebCore.RenderLayer) -> Bool {
        let renderer = layer.renderer()
        if !renderer.isRenderWidget() {
            return false
        }

        if renderer.hasRemoteContentFrameForSwift() {
            return renderer.hasLayer() && renderer.layer()!.isComposited()
        }

        guard let view = renderer.contentRenderViewForSwift() else {
            return false
        }

        if let scrollingCoordinator = scrollingCoordinator() {
            return scrollingCoordinator.coordinatesScrollingForFrameView(view.frameView())
        }

        return false
    }

    private func updateScrollingNodeForPluginHostingRole(
        _ layer: WebCore.RenderLayer,
        _ treeState: inout WebCore.ScrollingTreeState,
        _ changes: ScrollingNodeChangeFlags
    ) -> WebCore.ScrollingNodeID? {
        guard let newNodeID = attachScrollingNode(layer, .PluginHosting, &treeState) else {
            assertionFailure()
            return treeState.parentNodeIDForSwift().value
        }

        return newNodeID
    }

    private func updateScrollingNodeForPositioningRole(
        _ layer: WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer?,
        _ treeState: inout WebCore.ScrollingTreeState,
        _ changes: ScrollingNodeChangeFlags
    ) -> WebCore.ScrollingNodeID? {
        let scrollingCoordinator = scrollingCoordinator()

        guard let newNodeID = attachScrollingNode(layer, .Positioned, &treeState) else {
            assertionFailure()
            return treeState.parentNodeIDForSwift().value
        }

        if changes.layer {
            setNodeLayer(scrollingCoordinator!, newNodeID, layer.backing()!.graphicsLayer())
        }

        if changes.layerGeometry && treeState.hasParent {
            let backing = layer.backing()!
            // Would be nice to avoid calling computeCoordinatedPositioningForLayer() again.
            let positioningBehavior = computeCoordinatedPositioningForLayer(layer, compositingAncestor)
            var relatedNodeIDs = collectRelatedCoordinatedScrollingNodes(layer, positioningBehavior)
            scrollingCoordinator!.setRelatedOverflowScrollingNodes(newNodeID, relatedNodeIDs.takeNodeIDs())

            let graphicsLayer = backing.graphicsLayer()!
            var constraints = WebCore.AbsolutePositionConstraints()
            constraints.setAlignmentOffset(graphicsLayer.pixelAlignmentOffset())
            constraints.setLayerPositionAtLastLayout(graphicsLayer.positionForSwift())
            scrollingCoordinator!.setPositionedNodeConstraints(newNodeID, constraints)
        }

        return newNodeID
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public func viewportConstrainedSublayers(
        _ layer: borrowing WebCore.RenderLayer,
        _ compositingAncestor: WebCore.RenderLayer?
    ) -> WebCore.ViewportConstrainedSublayers {
        let layer = copy layer
        func sublayersForViewportConstrainedLayer() -> WebCore.ViewportConstrainedSublayers {
            if !m_renderView.get().settings().contentInsetBackgroundFillEnabled() {
                return .Anchor
            }

            if !isMainFrameCompositor() {
                return .Anchor
            }

            if !isSameRenderLayer(compositingAncestor, m_renderView.get().layer()) {
                return .Anchor
            }

            if documentIsFullscreenForSwift() {
                return .Anchor
            }

            return .ClippingAndAnchor
        }

        if layer.renderer().isStickilyPositioned() {
            if !isAsyncScrollableStickyLayerForSwift(layer) {
                return .None
            }

            // A sticky layer in a composited scroller sticks in that scroller (isAsyncScrollableStickyLayer's
            // enclosing accelerated overflow layer).
            if let enclosingOverflowLayer = layer.enclosingOverflowClipLayer(WebCore.ExcludeSelf),
                enclosingOverflowLayer.hasCompositedScrollableOverflow()
            {
                return .Anchor
            }

            return sublayersForViewportConstrainedLayer()
        }

        if !(layer.renderer().isFixedPositioned() && layer.behavesAsFixed()) {
            return .None
        }

        if layer.renderer().effectiveCapturedInViewTransition() {
            return .None
        }

        var ancestor = layer.parent()
        while let current = ancestor {
            if current.hasCompositedScrollableOverflow() {
                return sublayersForViewportConstrainedLayer()
            }

            if current.isStackingContext() && current.isComposited() && current.renderer().isFixedPositioned() {
                return .None
            }
            ancestor = current.parent()
        }

        return sublayersForViewportConstrainedLayer()
    }

    @cxx
    @implementation
    public func fixedLayerIntersectsViewport(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        let layer = copy layer
        assert(layer.renderer().isFixedPositioned())

        // Fixed position elements that are invisible in the current view don't get their own layer.
        // FIXME: We shouldn't have to check useFixedLayout() here; one of the viewport rects needs to give the correct answer.
        let frameView = m_renderView.get().frameView()
        let viewBounds =
            frameView.useFixedLayout()
            ? WebCore.LayoutRect(m_renderView.get().unscaledDocumentRect()) : frameView.rectForFixedPositionLayout()

        var boundsFlags = WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.UseLocalClipRectIfPossible)
        boundsFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeFilterOutsets))
        boundsFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.UseFragmentBoxesExcludingCompositing))
        boundsFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.ExcludeHiddenDescendants))
        boundsFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.DontConstrainForMask))
        boundsFlags.add(WebCore.RenderLayer.CalculateLayerBoundsFlags(WebCore.RenderLayer.IncludeCompositedDescendants))
        let layerBounds = layer.calculateLayerBounds(layer, WebCore.LayoutSize(), boundsFlags)
        // Map to m_renderView to ignore page scale.
        let absoluteBounds = layer.renderer()
            .localToContainerQuadForSwift(
                WebCore.FloatQuad(
                    WebCore.FloatRect(
                        layerBounds.x().toFloat(),
                        layerBounds.y().toFloat(),
                        layerBounds.width().toFloat(),
                        layerBounds.height().toFloat()
                    )
                ),
                m_renderView.get()
            )
            .boundingBox()
        return viewBounds.intersects(WebCore.LayoutRect(WebCore.enclosingIntRect(absoluteBounds)))
    }

    @cxx
    @implementation
    public func useCoordinatedScrollingForLayer(_ layer: borrowing WebCore.RenderLayer) -> Bool {
        let layer = copy layer
        if layer.isRenderViewLayer() && hasCoordinatedScrolling() {
            return true
        }

        if let scrollingCoordinator = scrollingCoordinator() {
            return scrollingCoordinator.coordinatesScrollingForOverflowLayer(layer)
        }

        return false
    }

    @cxx
    @implementation
    public func computeCoordinatedPositioningForLayer(
        _ layer: borrowing WebCore.RenderLayer,
        _ compositedAncestor: WebCore.RenderLayer?
    ) -> WebCore.ScrollPositioningBehavior {
        let layer = copy layer
        if layer.isRenderViewLayer() {
            return .None
        }

        if layer.renderer().isFixedPositioned() && layer.behavesAsFixed() {
            return .None
        }

        if !layer.hasCompositedScrollingAncestor() {
            return .None
        }

        if scrollingCoordinator() == nil {
            return .None
        }

        guard let compositedAncestor else {
            assertionFailure()
            return .None
        }

        return WebCore.RenderLayerCompositor.layerScrollBehaviorRelativeToCompositedAncestor(layer, compositedAncestor)
    }
}

private func collectStationaryLayerRelatedOverflowNodes(_ layer: WebCore.RenderLayer, _ scrollingNodes: inout WebCore.ScrollingNodeIDList) {
    assert(layer.isComposited())

    // Collect all the composited scrollers which affect the position of this layer relative to its compositing ancestor (which might be
    // inside the scroller or the scroller itself).
    var seenPaintOrderAncestor = false
    traverseRenderLayerAncestors(layer) { ancestorLayer, isContainingBlockChain, isPaintOrderAncestor in
        seenPaintOrderAncestor = seenPaintOrderAncestor || isPaintOrderAncestor
        if isContainingBlockChain && isPaintOrderAncestor {
            return true
        }

        if seenPaintOrderAncestor && !isContainingBlockChain && ancestorLayer.hasCompositedScrollableOverflow() {
            assert(ancestorLayer.isComposited())
            if ancestorLayer.isComposited(), let scrollingNodeID = ancestorLayer.backing()!.scrollingNodeIDForRole(.Scrolling).value {
                scrollingNodes.append(scrollingNodeID)
            }
        }

        return false
    }
}

private func collectRelatedCoordinatedScrollingNodes(
    _ layer: WebCore.RenderLayer,
    _ positioningBehavior: WebCore.ScrollPositioningBehavior
) -> WebCore.ScrollingNodeIDList {
    var overflowNodeIDs = WebCore.ScrollingNodeIDList()

    switch positioningBehavior {
    case .Stationary:
        if layer.ancestorCompositingLayer() == nil {
            return overflowNodeIDs
        }
        collectStationaryLayerRelatedOverflowNodes(layer, &overflowNodeIDs)
    default:
        assertionFailure()
    }

    return overflowNodeIDs
}

extension WebCore.RenderLayerCompositor {
    // Repaints the frame view's slow repaint objects whose enclosing layer the given layer scrolls.
    func repaintSlowRepaintObjectsScrolledByLayer(_ scrollableLayer: WebCore.RenderLayer) {
        let slowRepaintObjects = slowRepaintObjectsForSwift()
        for rendererIndex in 0..<slowRepaintObjects.size() {
            guard let renderer = slowRepaintObjects.rendererAt(rendererIndex) else {
                continue
            }
            if let layer = renderer.enclosingLayer(), layer.ancestorLayerIsInContainingBlockChain(scrollableLayer, nil) {
                renderer.repaint()
            }
        }
    }
}

// The frame hosting node of the frame's owner in its parent document, if the owner's layer is composited.
private func frameHostingNodeForFrame(_ frame: WebCore.LocalFrame) -> WebCore.ScrollingNodeID? {
    guard let document = frame.document(), frame.view() != nil else {
        return nil
    }

    // Find the frame's enclosing layer in our render tree.
    guard let ownerElement = document.ownerElement() else {
        return nil
    }

    guard let widgetRenderer = ownerElement.renderer(), widgetRenderer.isRenderWidget() else {
        return nil
    }

    guard widgetRenderer.hasLayer(), let widgetLayer = widgetRenderer.asRenderLayerModelObject()!.layer(), widgetLayer.isComposited() else {
        return nil
    }

    return widgetLayer.backing()!.scrollingNodeIDForRole(.FrameHosting).value
}

extension WebCore.RenderLayerCompositor {
    func rootScrollingTreeState() -> WebCore.ScrollingTreeState {
        assert(!hasLayersWithUnresolvedRelationsForSwift())
        var scrollingTreeState = WebCore.ScrollingTreeState()
        scrollingTreeState.hasParent = true

        if !m_renderView.get().frame().isMainFrame() {
            let parentNodeID = frameHostingNodeForFrame(m_renderView.get().frame())
            scrollingTreeState.setParentNodeIDForSwift(optionalNodeID(parentNodeID))
            scrollingTreeState.hasParent = parentNodeID != nil
        }
        return scrollingTreeState
    }

    @cxx
    @implementation
    public func setupScrollProxyRelatedOverflowScrollingNode(
        _ scrollingCoordinator: WebCore.ScrollingCoordinator,
        _ scrollingProxyNodeID: WebCore.ScrollingNodeID,
        _ overflowScrollingLayer: WebCore.RenderLayer
    ) -> Bool {
        guard let backing = overflowScrollingLayer.backing() else {
            return false
        }

        guard let overflowScrollNodeID = backing.scrollingNodeIDForRole(.Scrolling).value else {
            return false
        }

        var relatedNodeIDs = WebCore.ScrollingNodeIDList()
        relatedNodeIDs.append(overflowScrollNodeID)
        scrollingCoordinator.setRelatedOverflowScrollingNodes(scrollingProxyNodeID, relatedNodeIDs.takeNodeIDs())
        return true
    }
}

extension WebCore.RenderLayerCompositor {
    @cxx
    @implementation
    public static func asyncScrollableContainerNodeID(_ renderer: borrowing WebCore.RenderObject) -> WebCore.OptionalScrollingNodeID {
        let renderer = copy renderer
        guard let enclosingLayer = renderer.enclosingLayer() else {
            return .init()
        }

        func layerScrollingNodeID(_ layer: WebCore.RenderLayer) -> WebCore.ScrollingNodeID? {
            if layer.isComposited() {
                return layer.backing()!.scrollingNodeIDForRole(.Scrolling).value
            }
            return nil
        }

        // If the renderer is inside the layer, we care about the layer's scrollability. Otherwise, we let traverseAncestorLayers look at
        // ancestors.
        if !renderer.hasLayer() {
            if let scrollingNodeID = layerScrollingNodeID(enclosingLayer) {
                return .init(scrollingNodeID)
            }
        }

        var containerScrollingNodeID: WebCore.ScrollingNodeID?
        traverseRenderLayerAncestors(enclosingLayer) { ancestorLayer, isContainingBlockChain, _ in
            if isContainingBlockChain && ancestorLayer.hasCompositedScrollableOverflow() {
                containerScrollingNodeID = layerScrollingNodeID(ancestorLayer)
                return true
            }
            return false
        }

        return optionalNodeID(containerScrollingNodeID)
    }

    @cxx
    @implementation
    public func resolveScrollingTreeRelationships() {
        if !hasLayersWithUnresolvedRelationsForSwift() {
            return
        }

        let scrollingCoordinator = scrollingCoordinator()

        let layersWithUnresolvedRelations = layersWithUnresolvedRelationsForSwift()
        for layerIndex in 0..<layersWithUnresolvedRelations.size() {
            guard let layer = layersWithUnresolvedRelations.layerAt(layerIndex) else {
                continue
            }

            if !layer.isComposited() {
                continue
            }

            let backing = layer.backing()!
            for index in 0..<backing.ancestorClippingStackSizeForSwift() {
                if !backing.ancestorClippingStackEntryIsOverflowScrollForSwift(index) {
                    continue
                }

                let succeeded = setupScrollProxyRelatedOverflowScrollingNode(
                    scrollingCoordinator!,
                    backing.ancestorClippingStackProxyNodeIDForSwift(index).value!,
                    backing.overflowScrollClippingLayerForSwift(index)!
                )
                assert(succeeded)
            }
        }

        clearLayersWithUnresolvedRelationsForSwift()
    }

    @cxx
    @implementation
    public func updateSynchronousScrollingNodes() {
        if !hasCoordinatedScrolling() {
            return
        }

        if m_renderView.get().settings().fixedBackgroundsPaintRelativeToDocument() {
            return
        }

        let scrollingCoordinator = scrollingCoordinator()!

        let rootScrollingNodeID = m_renderView.get().frameView().scrollingNodeID()
        var nodesToClear = scrollingNodeIDsForSwift()

        func clearSynchronousReasonsOnNonRootNodes() {
            for index in 0..<nodesToClear.size() {
                let nodeID = nodesToClear.at(index)
                if WebCore.RenderLayerCompositor.isSameScrollingNodeIDForSwift(.init(nodeID), rootScrollingNodeID) {
                    continue
                }

                // Harmless to call setSynchronousScrollingReasons on a non-scrolling node.
                scrollingCoordinator.setSynchronousScrollingReasons(.init(nodeID), .init())
            }
        }

        func setHasSlowRepaintObjectsSynchronousScrollingReasonOnRootNode(_ hasSlowRepaintObjects: Bool) {
            guard let rootScrollingNodeID = rootScrollingNodeID.value else {
                return
            }
            // ScrollingCoordinator manages all bits other than HasSlowRepaintObjects, so maintain their current value.
            var reasons = scrollingCoordinator.synchronousScrollingReasons(.init(rootScrollingNodeID))
            reasons.set(.init(WebCore.SynchronousScrollingReason.HasSlowRepaintObjects), hasSlowRepaintObjects)
            scrollingCoordinator.setSynchronousScrollingReasons(.init(rootScrollingNodeID), reasons)
        }

        let slowRepaintObjects = slowRepaintObjectsForSwift()
        var rootHasSlowRepaintObjects = false
        for rendererIndex in 0..<slowRepaintObjects.size() {
            guard let renderer = slowRepaintObjects.rendererAt(rendererIndex) else {
                continue
            }

            guard let layer = renderer.enclosingLayer() else {
                continue
            }

            let scrollingScope =
                WebCore.RenderObject.isSameRenderer(layer.renderer(), renderer) ? layer.boxScrollingScope() : layer.contentsScrollingScope()
            if scrollingScope.value == nil {
                continue
            }

            if let enclosingScrollingNodeID = WebCore.RenderLayerCompositor.asyncScrollableContainerNodeID(renderer).value {
                assert(!WebCore.RenderLayerCompositor.isSameScrollingNodeIDForSwift(.init(enclosingScrollingNodeID), rootScrollingNodeID))

                scrollingCoordinator.setSynchronousScrollingReasons(
                    .init(enclosingScrollingNodeID),
                    .init(WebCore.SynchronousScrollingReason.HasSlowRepaintObjects)
                )
                nodesToClear.remove(enclosingScrollingNodeID)

                // Although the root scrolling layer does not have a slow repaint object in it directly,
                // we need to set some synchronous scrolling reason on it so that
                // ScrollingCoordinator::shouldUpdateScrollLayerPositionSynchronously returns an
                // appropriate value. (Scrolling itself would be correct without this, since the
                // scrolling tree propagates DescendantScrollersHaveSynchronousScrolling bits up the
                // tree, but shouldUpdateScrollLayerPositionSynchronously looks at the scrolling state
                // tree instead.)
                rootHasSlowRepaintObjects = true
            } else if !layer.behavesAsFixed() {
                rootHasSlowRepaintObjects = true
            }
        }

        setHasSlowRepaintObjectsSynchronousScrollingReasonOnRootNode(rootHasSlowRepaintObjects)
        clearSynchronousReasonsOnNonRootNodes()
    }
}
