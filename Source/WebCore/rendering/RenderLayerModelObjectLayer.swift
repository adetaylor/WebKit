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
 *           (C) 2005, 2006 Samuel Weinig (sam.weinig@gmail.com)
 * Copyright (C) 2005-2025 Apple Inc. All rights reserved.
 * Copyright (C) 2010-2015 Google Inc. All rights reserved.
 * Copyright (C) 2023, 2024 Igalia S.L.
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

// RenderLayerModelObject's layer: whether it has one that paints itself, and making one when the subtree allows it.
// WebCore.RenderLayerModelObject names this file in SWIFT_PRIVATE_FILEID.

internal import WebCore_Private

extension WebCore.RenderLayerModelObject {
    @cxx
    @implementation
    public func hasSelfPaintingLayer() -> Bool {
        layer()?.isSelfPaintingLayer() ?? false
    }

    @cxx
    @implementation
    public func createLayerIfAllowed() -> Bool {
        if layer() != nil || !isLayerCreationAllowedForSubtree {
            return false
        }
        createLayer()
        if parentRendererOfRenderObject(self) != nil && !needsLayout() {
            layer()!.setRepaintStatusBody(.NeedsFullRepaint)
        }
        return true
    }

    @cxx
    @implementation
    public func hasAcceleratedCompositing() -> Bool {
        view().compositor().hasAcceleratedCompositing()
    }

    @cxx
    @implementation
    public func shouldPlaceVerticalScrollbarOnLeft() -> Bool {
        // RTL Scrollbars require some system support, and this system support does not exist on certain versions of macOS. iOS uses a
        // separate mechanism.
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
        return false
        #else
        switch settings().userInterfaceDirectionPolicy() {
        case .Content:
            return self[.Style].shouldPlaceVerticalScrollbarOnLeft()
        case .System:
            return settings().systemLayoutDirection() == .RTL
        @unknown default:
            assertionFailure()
            return self[.Style].shouldPlaceVerticalScrollbarOnLeft()
        }
        #endif
    }

    @cxx
    @implementation
    public override func transformRelatedPropertyDidChange() {
        guard let layer = layer(), let backing = layer.backing() else {
            return
        }
        backing.transformRelatedPropertyDidChange()
    }

    // MARK: SVG transforms

    @cxx
    @implementation
    public func svgTransformAttributeChangeInducesLayerComposition() -> Bool {
        // True when a just-parsed SVG transform attribute flips whether this container needs a layer,
        // so the change must create or destroy one. A 2D transform gates layer creation for any SVG
        // container (requiresLayer() returns true for isTransformed() && isRenderSVGContainer()), which
        // covers both <g> (RenderSVGTransformableContainer) and nested <svg> (RenderSVGViewportContainer).
        if !isRenderSVGContainer() {
            return false
        }
        // requiresLayer() reads the cached hasSVGTransform() flag - so make sure it's not stale.
        updateHasSVGTransformFlags()
        return requiresLayer() != hasLayer()
    }

    @cxx
    @implementation
    public func invalidateCachedSVGBoundingBoxesOfAncestors() {
        var ancestor = parentRendererOfRenderObject(self)
        while let current = ancestor {
            if let svgAncestor = current.asRenderLayerModelObject() {
                svgAncestor.invalidateCachedSVGTransformDependentBoundingBoxes()
                svgAncestor.invalidateCachedVisualOverflowRect()
                if svgAncestor.hasLayer() {
                    svgAncestor.layer()!.setNeedsPositionUpdate()
                }
            }
            if current.isRenderSVGRoot() {
                break
            }
            ancestor = parentRendererOfRenderObject(current)
        }
    }

    // MARK: SVG painting

    @cxx
    @implementation
    public func shouldPaintSVGLeafRenderer(
        _ paintInfo: WebCore.PaintInfoView,
        _ relevantPaintPhases: WebCore.RenderLayerModelObject.PaintPhases
    ) -> Bool {
        shouldPaintSVGLeafRenderer(paintInfo: paintInfo.pointee, relevantPaintPhases)
    }

    private func shouldPaintSVGLeafRenderer(
        paintInfo: borrowing WebCore.PaintInfo,
        _ relevantPaintPhases: WebCore.RenderLayerModelObject.PaintPhases
    ) -> Bool {
        if paintInfo.paintingDisabled() {
            return false
        }

        if !relevantPaintPhases.contains(paintInfo.phase) {
            return false
        }

        if !paintInfo.shouldPaintWithinRoot(self) {
            return false
        }

        if usedVisibility() == .Hidden || self[.Style].displayIsNone() {
            return false
        }

        return true
    }

    @cxx
    @implementation
    public func shouldPaintSVGContainerRenderer(
        _ paintInfo: WebCore.PaintInfoView,
        _ relevantPaintPhases: WebCore.RenderLayerModelObject.PaintPhases
    ) -> Bool {
        shouldPaintSVGContainerRenderer(paintInfo: paintInfo.pointee, relevantPaintPhases)
    }

    private func shouldPaintSVGContainerRenderer(
        paintInfo: borrowing WebCore.PaintInfo,
        _ relevantPaintPhases: WebCore.RenderLayerModelObject.PaintPhases
    ) -> Bool {
        let phase = paintInfo.phase
        if phase != .EventRegion {
            if paintInfo.paintingDisabled() {
                return false
            }
        }

        if !relevantPaintPhases.contains(paintInfo.phase) {
            return false
        }

        if !paintInfo.shouldPaintWithinRoot(self) {
            return false
        }

        if self[.Style].displayIsNone() {
            return false
        }

        // Children can override with "visibility: visible", per SVG spec.
        let paintedIfHidden = phase == .Foreground || phase == .ClippingMask || phase == .Mask
        if !paintedIfHidden && usedVisibility() == .Hidden {
            return false
        }

        return true
    }

    @cxx
    @implementation
    public func paintSVGEventRegion(_ paintInfo: WebCore.PaintInfoView, _ paintOffset: WebCore.LayoutPoint) {
        paintSVGEventRegion(paintInfo: paintInfo.pointee, paintOffset)
    }

    private func paintSVGEventRegion(paintInfo: borrowing WebCore.PaintInfo, _ paintOffset: WebCore.LayoutPoint) {
        let phase = paintInfo.phase
        assert(phase == .EventRegion)
        if usedVisibility() == .Hidden || objectBoundingBox().isEmpty() {
            return
        }

        let adjustedPaintOffset = paintOffset + currentSVGLayoutLocation()
        let coordinateSystemOriginTranslation = adjustedPaintOffset - nominalSVGLayoutLocation()
        var eventRegionBounds = strokeBoundingBox()
        eventRegionBounds.move(
            WebCore.FloatSize(coordinateSystemOriginTranslation.width().toFloat(), coordinateSystemOriginTranslation.height().toFloat())
        )
        paintInfo.eventRegionContextForSwift()!
            .unite(WebCore.FloatRoundedRect(eventRegionBounds, WebCore.CornerRadii()), self, self[.Style], false)
    }

    // MARK: Content change

    @cxx
    @implementation
    public func contentChanged(_ changeType: WebCore.ContentChangeType, _ dirtyRect: WebCore.RenderLayer.OptionalFloatRect) {
        if let layer = layer() {
            layer.contentChanged(changeType, dirtyRect)
        }
    }

    // MARK: Renderer transform

    @cxx
    @implementation
    public func computeRendererTransform() -> WebCore.AffineTransform {
        if !isTransformed() {
            return WebCore.AffineTransform()
        }
        if let renderLayer = layer() {
            return renderLayer.currentTransform(WebCore.RenderLayer.individualTransformOperations()).toAffineTransform()
        }
        var matrix = WebCore.TransformationMatrix()
        let referenceBoxRect = transformReferenceBoxRect(self[.Style])
        applyTransform(&matrix, self[.Style], referenceBoxRect, WebCore.RenderLayer.individualTransformOperations())
        return matrix.toAffineTransform()
    }
}
