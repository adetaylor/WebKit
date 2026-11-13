// Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2012 University of Szeged
// Copyright (C) 2015-2026 Apple Inc. All rights reserved.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.
//
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

#if USE_CORE_IMAGE
import CoreGraphics
#endif
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.IntRect

// The geometry functions of Filter (Filter.cpp) for the Swift code of effects, which gets a FilterApplyContext in place
// of the Filter. Each one does what the Filter function of the same name does, in the same order.
extension WebCore.FilterApplyContext {
    func resolvedSize(_ size: WebCore.FloatSize) -> WebCore.FloatSize {
        // Without objectBoundingBox primitive units the Filter returns the size itself, even a signaling NaN, which a
        // multiplication by 1 would quiet.
        let scale = resolvedSizeScale
        if scale.width() == 1 && scale.height() == 1 {
            return size
        }
        return WebCore.FloatSize(size.width() * scale.width(), size.height() * scale.height())
    }

    func scaledByFilterScale(_ point: WebCore.FloatPoint) -> WebCore.FloatPoint {
        point.scaled(filterScale.width(), filterScale.height())
    }

    func scaledByFilterScale(_ size: WebCore.FloatSize) -> WebCore.FloatSize {
        WebCore.FloatSize(size.width() * filterScale.width(), size.height() * filterScale.height())
    }

    func scaledByFilterScale(_ rect: WebCore.FloatRect) -> WebCore.FloatRect {
        var scaledRect = rect
        scaledRect.scale(filterScale)
        return scaledRect
    }

    func maxEffectRect(_ primitiveSubregion: WebCore.FloatRect) -> WebCore.FloatRect {
        WebCore.intersection(primitiveSubregion, filterRegion)
    }

    func clipToMaxEffectRect(_ imageRect: WebCore.FloatRect, _ primitiveSubregion: WebCore.FloatRect) -> WebCore.FloatRect {
        WebCore.intersection(imageRect, maxEffectRect(primitiveSubregion))
    }

    // Core Image coordinates: relative to the absolute enclosing filter region, with the y axis flipped.
    func flippedRectRelativeToAbsoluteEnclosingFilterRegion(_ absoluteRect: WebCore.FloatRect) -> WebCore.FloatRect {
        let region = absoluteEnclosingFilterRegion
        return WebCore.FloatRect(
            absoluteRect.x() - region.x(),
            region.maxY() - absoluteRect.maxY(),
            absoluteRect.width(),
            absoluteRect.height()
        )
    }

    func flippedRectRelativeToAbsoluteEnclosingFilterRegion(_ absoluteRect: WebCore.IntRect) -> WebCore.FloatRect {
        flippedRectRelativeToAbsoluteEnclosingFilterRegion(WebCore.FloatRect(absoluteRect))
    }

    #if USE_CORE_IMAGE
    // The Core Image rect of an absolute rect, as the C++ appliers passed it to Core Image: usually the result's
    // absolute image rect, to crop the result to.
    func coreImageRect(_ absoluteRect: WebCore.IntRect) -> CGRect {
        let rect = flippedRectRelativeToAbsoluteEnclosingFilterRegion(absoluteRect)
        return CGRect(x: CGFloat(rect.x()), y: CGFloat(rect.y()), width: CGFloat(rect.width()), height: CGFloat(rect.height()))
    }
    #endif
}

// The FilterApplyContext of a filter, from its parameters. The resolved size scale is the size of one primitive unit
// (SVGFilterRenderer::resolvedSize()); the enclosing filter region is the one Core Image renders.
func filterApplyContextOf(_ renderer: borrowing WebCore.FilterRendererParameters) -> WebCore.FilterApplyContext {
    var context = WebCore.FilterApplyContext()
    context.filterScale = renderer.filterScale
    context.filterRegion = renderer.filterRegion
    context.resolvedSizeScale = svgFilterResolvedSize(
        WebCore.FloatSize(1, 1),
        renderer.referenceBox,
        renderer.primitiveUnitsAreObjectBoundingBox
    )
    #if USE_CORE_IMAGE
    var absoluteEnclosingFilterRegion = renderer.enclosingFilterRegion
    absoluteEnclosingFilterRegion.scale(renderer.filterScale)
    context.absoluteEnclosingFilterRegion = absoluteEnclosingFilterRegion
    #endif
    context.accelerated = renderer.accelerated
    context.fastAndLowQuality = renderer.fastAndLowQuality
    context.showDebugOverlay = renderer.showDebugOverlay
    return context
}

// FilterEffect::calculateImageRect() of effects that don't override it: the union of the input image rects (nil without
// inputs) clipped to the maximum effect rect, or the maximum effect rect without inputs.
func filterEffectImageRect(
    _ context: borrowing WebCore.FilterApplyContext,
    unitedInputImageRects: WebCore.FloatRect?,
    _ primitiveSubregion: WebCore.FloatRect
) -> WebCore.FloatRect {
    guard let unitedInputImageRects else {
        return context.maxEffectRect(primitiveSubregion)
    }
    return context.clipToMaxEffectRect(unitedInputImageRects, primitiveSubregion)
}

#endif // ENABLE_WEBCORE_SWIFT
