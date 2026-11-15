// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
// Copyright (C) 2013 Google Inc. All rights reserved.
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

// The safe Span overloads Swift synthesizes for FilterOutsetsList.span() and FilterImageRects.span() call Cxx's
// Span(_unsafeCxxSpan:). Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.CSSFilterRendererView
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect

// Filter::supportedFilterRenderingModes() of the CSS and SVG filter renderers: the modes that all of a renderer's
// functions or effects support. Starting from all modes, the renderer folds in the modes of each with this.
@_expose(Cxx)
func filterRenderingModesIntersection(_ modes: UInt8, _ functionModes: UInt8) -> UInt8 {
    modes & functionModes
}

#if USE_CORE_IMAGE
// CSSFilterRenderer::computeEnclosingFilterRegion(): the union of a CSS filter's region and the regions of the filters
// among its functions, against which the Core Image geometry of the whole chain is computed.
@_expose(Cxx)
func cssFilterEnclosingFilterRegion(
    _ filterRegion: WebCore.FloatRect,
    _ functionFilterRegions: borrowing WebCore.FilterImageRects
) -> WebCore.FloatRect {
    let regions: Span<WebCore.FloatRect> = functionFilterRegions.span()
    var svgFilterRegions: [WebCore.FloatRect] = []
    svgFilterRegions.reserveCapacity(regions.count)
    for index in regions.indices {
        svgFilterRegions.append(regions[index])
    }
    return describedCSSFilterEnclosingFilterRegion(filterRegion, svgFilterRegions)
}
#endif

// CSSFilterRenderer::calculateOutsets(): the sum of the outsets of a CSS filter's functions, wrapping on overflow.
@_expose(Cxx)
func cssFilterOutsets(_ functionOutsets: borrowing WebCore.FilterOutsetsList) -> WebCore.FilterOutsets {
    let outsets: Span<WebCore.FilterOutsets> = functionOutsets.span()
    var sum = WebCore.FilterOutsets()
    for index in outsets.indices {
        let next = outsets[index]
        sum = WebCore.FilterOutsets(
            top: sum.top &+ next.top,
            right: sum.right &+ next.right,
            bottom: sum.bottom &+ next.bottom,
            left: sum.left &+ next.left
        )
    }
    return sum
}

// CSSFilterRenderer::apply(): applies the functions in turn, each to the previous one's result.
@_expose(Cxx)
func cssFilterApply(
    _ filter: WebCore.CSSFilterRendererView,
    _ sourceImage: WebCore.ImageBuffer?,
    _ sourceImageRect: WebCore.FloatRect,
    _ allocator: WebCore.FilterImageAllocator,
    _ results: inout FilterResultsImpl,
    _ rendersResult: Bool,
    _ absoluteImageRect: inout WebCore.IntRect
) -> WebCore.RefPtrImageBuffer {
    cssFilterResult(CSSFilterDescription(filter), sourceImage, sourceImageRect, allocator, &results, rendersResult, &absoluteImageRect)
}

// CSSFilterRenderer::apply() of a described CSS filter: its result, with its absolute image rect, or nil if it fails.
// `rendersResult`: as FilterEngine.finalResult() takes it.
@_spi(WebKitGPU) public func applyCSSFilter(
    _ filter: borrowing CSSFilterDescription,
    _ sourceImage: WebCore.ImageBuffer?,
    _ sourceImageRect: WebCore.FloatRect,
    _ allocator: WebCore.FilterImageAllocator,
    _ results: inout FilterResultsState,
    _ rendersResult: Bool,
    _ absoluteImageRect: inout WebCore.IntRect
) -> WebCore.ImageBuffer? {
    cssFilterResult(filter, sourceImage, sourceImageRect, allocator, &results.impl, rendersResult, &absoluteImageRect).get()
}

private func cssFilterResult(
    _ filter: borrowing CSSFilterDescription,
    _ sourceImage: WebCore.ImageBuffer?,
    _ sourceImageRect: WebCore.FloatRect,
    _ allocator: WebCore.FilterImageAllocator,
    _ results: inout FilterResultsImpl,
    _ rendersResult: Bool,
    _ absoluteImageRect: inout WebCore.IntRect
) -> WebCore.RefPtrImageBuffer {
    let context = filterApplyContextOf(filter.renderer)
    return withFilterEngine(allocator, &results) { engine in
        guard var result = engine.sourceImage(sourceImage, sourceImageRect, context) else {
            return WebCore.RefPtrImageBuffer()
        }
        for (index, function) in filter.functions.enumerated() {
            let next: FilterImageBox?
            switch function {
            case .effect(let effect):
                next = engine.applyEffect(
                    effect,
                    FilterEffectKey(filter.identifier, UInt32(index)),
                    context,
                    filter.renderer,
                    FilterEffectInputs(result)
                )
            case .svgFilter(let svgFilter):
                next = engine.applyReferencedSVGFilter(svgFilter, result)
            case nil:
                next = nil
            }
            guard let next else {
                return WebCore.RefPtrImageBuffer()
            }
            result = next
        }
        return engine.finalResult(result, context, rendersResult, &absoluteImageRect)
    }
}

#endif // ENABLE_WEBCORE_SWIFT
