// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
// Copyright (C) 2010 Sencha, Inc. All rights reserved.
// Copyright (C) 2010 Igalia S.L. All rights reserved.
// Copyright (C) Research In Motion Limited 2011. All rights reserved.
// Copyright (C) 2013 Digia Plc. and/or its subsidiary(-ies).
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

// std::optional's value comes from Cxx. Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.AffineTransform
import WebCore_Private.Core.Color
import WebCore_Private.Core.FloatQuad
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelBufferSwiftBridge
import WebCore_Private.Core.ShadowBlurSwiftBridge

// ShadowBlur's constructors: the shadow's blur radius, offset and type.
@_expose(Cxx)
func shadowBlurState(
    _ radius: WebCore.ShadowBlurSize,
    _ offset: WebCore.ShadowBlurSize,
    _ colorIsVisible: Bool,
    _ shadowsIgnoreTransforms: Bool,
    _ legacyRadius: Bool
) -> WebCore.ShadowBlurState {
    var blurRadius = radius
    if legacyRadius {
        blurRadius = WebCore.ShadowBlurSize(
            width: shadowBlurLegacyRadius(radius.width),
            height: shadowBlurLegacyRadius(radius.height)
        )
    }

    // Limit blur radius to 128 to avoid lots of very expensive blurring.
    blurRadius = WebCore.ShadowBlurSize(
        width: blurRadius.width < 128 ? blurRadius.width : 128,
        height: blurRadius.height < 128 ? blurRadius.height : 128
    )
    var state = WebCore.ShadowBlurState()
    state.blurRadius = blurRadius
    state.offset = offset
    state.shadowsIgnoreTransforms = shadowsIgnoreTransforms

    // The type of shadow is decided by the blur radius, shadow offset, and shadow color.
    if !colorIsVisible {
        // Can't paint the shadow with invalid or invisible color.
        state.type = .NoShadow
    } else if blurRadius.width > 0 || blurRadius.height > 0 {
        // Shadow is always blurred, even the offset is zero.
        state.type = .BlurShadow
    } else if offset.width == 0 && offset.height == 0 {
        // Without blur and zero offset means the shadow is fully hidden.
        state.type = .NoShadow
    } else {
        state.type = .SolidShadow
    }
    return state
}

// ShadowBlur::drawRectShadow().
@_expose(Cxx)
func shadowBlurDrawRectShadow(
    _ state: inout WebCore.ShadowBlurState,
    _ transform: borrowing WebCore.AffineTransform,
    _ clipBounds: WebCore.IntRect,
    _ shadowedRect: WebCore.ShadowBlurRect,
    _ radii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    let plan = state.rectShadowPlan(transform, clipBounds, shadowedRect, radii)
    var destination = copy destination
    shadowBlurDrawRectShadowPlan(state, plan, shadowedRect, radii, color, &destination)
}

// ShadowBlur::drawRectShadow() through a renderer that draws the shadow's pieces itself.
func shadowBlurDrawRectShadow<Destination: ShadowDrawing & ~Escapable>(
    _ state: inout WebCore.ShadowBlurState,
    _ transform: borrowing WebCore.AffineTransform,
    _ clipBounds: WebCore.IntRect,
    _ shadowedRect: WebCore.ShadowBlurRect,
    _ radii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    into destination: inout Destination
) {
    let plan = state.rectShadowPlan(transform, clipBounds, shadowedRect, radii)
    shadowBlurDrawRectShadowPlan(state, plan, shadowedRect, radii, color, &destination)
}

// ShadowBlur::drawInsetShadow().
@_expose(Cxx)
func shadowBlurDrawInsetShadow(
    _ state: inout WebCore.ShadowBlurState,
    _ transform: borrowing WebCore.AffineTransform,
    _ clipBounds: WebCore.IntRect,
    _ fullRect: WebCore.ShadowBlurRect,
    _ holeRect: WebCore.ShadowBlurRect,
    _ holeRadii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    let plan = state.insetShadowPlan(transform, clipBounds, fullRect, holeRect, holeRadii)
    var destination = copy destination
    shadowBlurDrawInsetShadowPlan(state, plan, fullRect, holeRect, holeRadii, color, &destination)
}

// ShadowBlur::drawShadowLayer().
@_expose(Cxx)
func shadowBlurDrawShadowLayer(
    _ state: inout WebCore.ShadowBlurState,
    _ transform: borrowing WebCore.AffineTransform,
    _ clipBounds: WebCore.IntRect,
    _ layerArea: WebCore.ShadowBlurRect,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    let plan = state.layerPlan(transform, clipBounds, layerArea)
    shadowBlurDrawShadowLayerPlan(state, plan, color, destination)
}

extension WebCore.ShadowBlurState {
    func blur(_ image: inout MutableSpan<UInt8>, _ width: Int32, _ height: Int32, _ rowStride: Int32) {
        shadowBlurLayerImage(
            &image,
            width,
            height,
            rowStride,
            blurRadius.width,
            blurRadius.height,
            shadowsIgnoreTransforms
        )
    }

    var isBlurShadow: Bool {
        type == .BlurShadow
    }

    // What drawRectShadow() draws. Adjusts the blur radius to the transform if it draws anything.
    fileprivate mutating func rectShadowPlan(
        _ transform: borrowing WebCore.AffineTransform,
        _ clipBounds: WebCore.IntRect,
        _ shadowedRect: WebCore.ShadowBlurRect,
        _ radii: WebCore.ShadowBlurCornerRadii
    ) -> ShadowBlurRectShadowPlan {
        var plan = ShadowBlurRectShadowPlan()
        guard let tiling = tilingPlan(transform, clipBounds, shadowedRect, shadowedRect, radii, false) else {
            return plan
        }
        plan.drawing = tiling.drawing
        plan.layer = tiling.layer
        plan.blurRadius = blurRadius
        if tiling.drawing != .withTiling {
            return plan
        }

        plan.templateSize = tiling.templateSize
        plan.templateShadow = shadowBlurTemplateInterior(tiling.templateSize, tiling.edgeSize)

        var shadowBounds = shadowedRect
        shadowBounds.move(transformedOffset(transform))
        shadowBounds.inflateX(Float(tiling.edgeSize.width))
        shadowBounds.inflateY(Float(tiling.edgeSize.height))

        plan.tiles = shadowBlurTiles(shadowBounds, radii, tiling.edgeSize, tiling.templateSize)
        plan.tiles.fillsCenter = !plan.tiles.center.isEmpty
        return plan
    }

    // What drawInsetShadow() draws. Adjusts the blur radius to the transform if it draws anything.
    fileprivate mutating func insetShadowPlan(
        _ transform: borrowing WebCore.AffineTransform,
        _ clipBounds: WebCore.IntRect,
        _ fullRect: WebCore.ShadowBlurRect,
        _ holeRect: WebCore.ShadowBlurRect,
        _ holeRadii: WebCore.ShadowBlurCornerRadii
    ) -> ShadowBlurInsetShadowPlan {
        var plan = ShadowBlurInsetShadowPlan()
        guard let tiling = tilingPlan(transform, clipBounds, fullRect, holeRect, holeRadii, true) else {
            return plan
        }
        plan.drawing = tiling.drawing
        plan.layer = tiling.layer
        plan.blurRadius = blurRadius
        if tiling.drawing != .withTiling {
            return plan
        }

        let templateSize = tiling.templateSize
        let edgeSize = tiling.edgeSize
        plan.templateSize = templateSize

        // Draw the rectangle with hole.
        plan.templateBounds = WebCore.ShadowBlurRect(
            x: 0,
            y: 0,
            width: Float(templateSize.width),
            height: Float(templateSize.height)
        )
        plan.templateHole = shadowBlurTemplateInterior(templateSize, edgeSize)

        let offset = transformedOffset(transform)

        plan.boundingRect = fullRect
        plan.boundingRect.move(offset)

        var destHoleBounds = holeRect
        destHoleBounds.move(offset)
        destHoleBounds.inflateX(Float(edgeSize.width))
        destHoleBounds.inflateY(Float(edgeSize.height))
        plan.holeBounds = destHoleBounds

        plan.tiles = shadowBlurTiles(destHoleBounds, holeRadii, edgeSize, templateSize)
        return plan
    }

    // What drawRectShadow() and drawInsetShadow() share: the layer, the adjusted blur radius, and whether to tile,
    // which needs a template no larger than `tiledRect` (the shadowed rect, or the hole of an inset shadow).
    @inline(never)
    private mutating func tilingPlan(
        _ transform: borrowing WebCore.AffineTransform,
        _ clipBounds: WebCore.IntRect,
        _ layerArea: WebCore.ShadowBlurRect,
        _ tiledRect: WebCore.ShadowBlurRect,
        _ radii: WebCore.ShadowBlurCornerRadii,
        _ isInset: Bool
    ) -> ShadowBlurTilingPlan? {
        guard let layer = layerImageProperties(transform, layerArea, clipBounds) else {
            return nil
        }

        adjustBlurRadius(transform)

        var canUseTilingTechnique = true

        // drawRectShadowWithTiling does not work with rotations.
        // https://bugs.webkit.org/show_bug.cgi?id=45042
        if !transform.preservesAxisAlignment() || type != .BlurShadow {
            canUseTilingTechnique = false
        }

        let edgeSize = blurredEdgeSize()
        let templateSize = self.templateSize(edgeSize, radii)

        if Float(templateSize.width) > tiledRect.width || Float(templateSize.height) > tiledRect.height {
            canUseTilingTechnique = false
        } else if isInset {
            if Float(templateSize.width &* templateSize.height) > tiledRect.width * tiledRect.height {
                canUseTilingTechnique = false
            }
        } else {
            let resultSize = layer.shadowedResultSize
            if Float(shadowBlurUnclampedArea(templateSize)) > resultSize.width * resultSize.height {
                canUseTilingTechnique = false
            }
        }

        return ShadowBlurTilingPlan(
            drawing: canUseTilingTechnique ? .withTiling : .withoutTiling,
            layer: layer,
            edgeSize: edgeSize,
            templateSize: templateSize
        )
    }

    // The layer drawShadowLayer() draws, if any. Adjusts the blur radius to the transform if it draws anything.
    fileprivate mutating func layerPlan(
        _ transform: borrowing WebCore.AffineTransform,
        _ clipBounds: WebCore.IntRect,
        _ layerArea: WebCore.ShadowBlurRect
    ) -> ShadowBlurLayerPlan {
        var plan = ShadowBlurLayerPlan()
        guard let layer = layerImageProperties(transform, layerArea, clipBounds) else {
            return plan
        }
        adjustBlurRadius(transform)
        plan.draws = true
        plan.layer = layer
        return plan
    }

    private mutating func adjustBlurRadius(_ transform: borrowing WebCore.AffineTransform) {
        if shadowsIgnoreTransforms {
            blurRadius.width *= 1 / Float(transform.xScale())
            blurRadius.height *= 1 / Float(transform.yScale())
        }
    }

    // The offset, in the coordinates of a transform the shadow ignores.
    private func transformedOffset(_ transform: borrowing WebCore.AffineTransform) -> WebCore.ShadowBlurSize {
        var offset = self.offset
        if shadowsIgnoreTransforms {
            offset.width *= Float(1 / transform.xScale())
            offset.height *= Float(1 / transform.yScale())
        }
        return offset
    }

    private func blurredEdgeSize() -> ShadowBlurIntSize {
        var edgeSize = shadowBlurExpandedIntSize(blurRadius)

        // To avoid slowing down blurLayerImage() for radius == 1, we give it two empty pixels on each side.
        if edgeSize.width == 1 {
            edgeSize.width = 2
        }

        if edgeSize.height == 1 {
            edgeSize.height = 2
        }

        return edgeSize
    }

    private func layerImageProperties(
        _ transform: borrowing WebCore.AffineTransform,
        _ shadowedRect: WebCore.ShadowBlurRect,
        _ clipRect: WebCore.IntRect
    ) -> ShadowBlurLayerImageProperties? {
        var calculatedLayerImageProperties = ShadowBlurLayerImageProperties()

        let edgeSize = blurredEdgeSize()

        // Calculate the destination of the blurred and/or transformed layer.
        var layerRect: WebCore.ShadowBlurRect
        var inflation = ShadowBlurIntSize()

        var mapsThroughTransform = false
        if shadowsIgnoreTransforms {
            mapsThroughTransform = !transform.isIdentity()
        }
        if mapsThroughTransform {
            var transformedPolygon = transform.mapQuad(WebCore.FloatQuad(shadowedRect.floatRect))
            transformedPolygon.move(WebCore.FloatSize(offset.width, offset.height))
            let inverse = transform.inverse().value ?? WebCore.AffineTransform()
            layerRect = WebCore.ShadowBlurRect(inverse.mapQuad(transformedPolygon).boundingBox())
        } else {
            layerRect = shadowedRect
            layerRect.move(offset)
        }

        // We expand the area by the blur radius to give extra space for the blur transition.
        if type == .BlurShadow {
            layerRect.inflateX(Float(edgeSize.width))
            layerRect.inflateY(Float(edgeSize.height))
            inflation = edgeSize
        }

        let unclippedLayerRect = layerRect

        if !clipRect.contains(WebCore.enclosingIntRect(layerRect.floatRect)) {
            // If we are totally outside the clip region, we aren't painting at all.
            if WebCore.intersection(layerRect.floatRect, WebCore.FloatRect(clipRect)).isEmpty() {
                return nil
            }

            var inflatedClip = clipRect
            // Pixels at the edges can be affected by pixels outside the buffer,
            // so intersect with the clip inflated by the blur.
            if type == .BlurShadow {
                inflatedClip.inflateX(edgeSize.width)
                inflatedClip.inflateY(edgeSize.height)
            } else {
                // Enlarge the clipping area 1 pixel so that the fill does not
                // bleed (due to antialiasing) even if the unaligned clip rect occurred
                inflatedClip.inflateX(1)
                inflatedClip.inflateY(1)
            }

            var intersected = layerRect.floatRect
            intersected.intersect(WebCore.FloatRect(inflatedClip))
            layerRect = WebCore.ShadowBlurRect(intersected)
        }

        let frameWidth = WTF.truncateFloatToInt32(Float(inflation.width) * 2)
        let frameHeight = WTF.truncateFloatToInt32(Float(inflation.height) * 2)
        calculatedLayerImageProperties.shadowedResultSize = WebCore.ShadowBlurSize(
            width: shadowedRect.width + Float(frameWidth),
            height: shadowedRect.height + Float(frameHeight)
        )
        calculatedLayerImageProperties.layerOrigin = ShadowBlurPoint(x: layerRect.x, y: layerRect.y)
        calculatedLayerImageProperties.layerSize = WebCore.ShadowBlurSize(width: layerRect.width, height: layerRect.height)

        let clippedOutWidth = unclippedLayerRect.x - layerRect.x
        let clippedOutHeight = unclippedLayerRect.y - layerRect.y

        // Set the origin as the top left corner of the scratch image, or, in case there's a clipped
        // out region, set the origin accordingly to the full bounding rect's top-left corner.
        let translationX = -shadowedRect.x + Float(inflation.width) - abs(clippedOutWidth)
        let translationY = -shadowedRect.y + Float(inflation.height) - abs(clippedOutHeight)
        calculatedLayerImageProperties.layerContextTranslation = WebCore.ShadowBlurSize(
            width: translationX,
            height: translationY
        )

        return calculatedLayerImageProperties
    }

    private func templateSize(
        _ radiusPadding: ShadowBlurIntSize,
        _ radii: WebCore.ShadowBlurCornerRadii
    ) -> ShadowBlurIntSize {
        let blurExpansion = ShadowBlurIntSize(
            width: WTF.truncateFloatToInt32(Float(radiusPadding.width) * 2),
            height: WTF.truncateFloatToInt32(Float(radiusPadding.height) * 2)
        )

        let slices = ShadowBlurSlices(blurExpansion, radii)

        return ShadowBlurIntSize(
            width: shadowBlurTemplateSideLength &+ slices.left &+ slices.right,
            height: shadowBlurTemplateSideLength &+ slices.top &+ slices.bottom
        )
    }
}

// The FloatRect, FloatSize and FloatPoint arithmetic the geometry uses, on the plain values, in the C++'s order.
extension WebCore.ShadowBlurRect {
    fileprivate init(_ rect: WebCore.FloatRect) {
        self.init(x: rect.x(), y: rect.y(), width: rect.width(), height: rect.height())
    }

    var floatRect: WebCore.FloatRect {
        WebCore.FloatRect(x, y, width, height)
    }

    fileprivate var maxX: Float {
        x + width
    }

    fileprivate var maxY: Float {
        y + height
    }

    fileprivate var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    fileprivate mutating func move(_ delta: WebCore.ShadowBlurSize) {
        x += delta.width
        y += delta.height
    }

    fileprivate mutating func inflateX(_ dx: Float) {
        x = x - dx
        width = width + dx + dx
    }

    fileprivate mutating func inflateY(_ dy: Float) {
        y = y - dy
        height = height + dy + dy
    }
}

struct ShadowBlurPoint {
    var x: Float = 0
    var y: Float = 0
}

struct ShadowBlurIntSize {
    var width: Int32 = 0
    var height: Int32 = 0
}

struct ShadowBlurLayerImageProperties {
    var shadowedResultSize = WebCore.ShadowBlurSize() // Size of the result of shadowing which is same as shadowedRect + blurred edges.
    var layerOrigin = ShadowBlurPoint() // Top-left corner of the (possibly clipped) bounding rect to draw the shadow to.
    var layerSize = WebCore.ShadowBlurSize() // Size of layerImage pixels that need blurring.
    var layerContextTranslation = WebCore.ShadowBlurSize() // Translation to apply to layerContext for the shadow to be correctly clipped.
}

enum ShadowBlurDrawing {
    case none
    case withoutTiling
    case withTiling
}

// Draws the `source` part of the shadow template at `destination`.
struct ShadowBlurTile {
    var destination = WebCore.ShadowBlurRect()
    var source = WebCore.ShadowBlurRect()
}

// The pieces of a tiled shadow, in drawing order, and its solid center.
struct ShadowBlurTiles {
    var top = ShadowBlurTile()
    var bottom = ShadowBlurTile()
    var left = ShadowBlurTile()
    var right = ShadowBlurTile()
    var topLeft = ShadowBlurTile()
    var topRight = ShadowBlurTile()
    var bottomRight = ShadowBlurTile()
    var bottomLeft = ShadowBlurTile()
    var center = WebCore.ShadowBlurRect()
    var fillsCenter = false
}

struct ShadowBlurRectShadowPlan {
    var drawing = ShadowBlurDrawing.none
    var layer = ShadowBlurLayerImageProperties()
    // The blur radius, after any adjustment to the transform.
    var blurRadius = WebCore.ShadowBlurSize()
    var templateSize = ShadowBlurIntSize()
    var templateShadow = WebCore.ShadowBlurRect()
    var tiles = ShadowBlurTiles()
}

struct ShadowBlurInsetShadowPlan {
    var drawing = ShadowBlurDrawing.none
    var layer = ShadowBlurLayerImageProperties()
    // The blur radius, after any adjustment to the transform.
    var blurRadius = WebCore.ShadowBlurSize()
    var templateSize = ShadowBlurIntSize()
    var templateBounds = WebCore.ShadowBlurRect()
    var templateHole = WebCore.ShadowBlurRect()
    var boundingRect = WebCore.ShadowBlurRect()
    var holeBounds = WebCore.ShadowBlurRect()
    var tiles = ShadowBlurTiles()
}

struct ShadowBlurLayerPlan {
    var draws = false
    var layer = ShadowBlurLayerImageProperties()
}

// expandedIntSize().
func shadowBlurExpandedIntSize(_ size: WebCore.ShadowBlurSize) -> ShadowBlurIntSize {
    let expanded = WebCore.expandedIntSize(WebCore.FloatSize(size.width, size.height))
    return ShadowBlurIntSize(width: expanded.width(), height: expanded.height())
}

private struct ShadowBlurTilingPlan {
    var drawing: ShadowBlurDrawing
    var layer: ShadowBlurLayerImageProperties
    var edgeSize: ShadowBlurIntSize
    var templateSize: ShadowBlurIntSize
}

private var shadowBlurTemplateSideLength: Int32 { 1 }

private func shadowBlurLegacyRadius(_ radius: Float) -> Float {
    radius > 8 ? 8 + 4 * ((radius - 8) / 2).squareRoot() : radius
}

// IntSize::unclampedArea().
private func shadowBlurUnclampedArea(_ size: ShadowBlurIntSize) -> UInt64 {
    (Int64(size.width) * Int64(size.height)).magnitude
}

// std::max.
@inline(__always)
private func shadowBlurMax(_ a: Float, _ b: Float) -> Float {
    a < b ? b : a
}

// computeSliceSizesFromRadii(): twice the edge size and the larger of two corner radii.
@inline(never)
private func shadowBlurSlice(_ twiceRadius: Int32, _ radius1: Float, _ radius2: Float) -> Int32 {
    Int32(arm64Truncating: Float(twiceRadius) + shadowBlurMax(radius1, radius2))
}

private struct ShadowBlurSlices {
    var left: Int32
    var right: Int32
    var top: Int32
    var bottom: Int32

    init(_ twiceRadius: ShadowBlurIntSize, _ radii: WebCore.ShadowBlurCornerRadii) {
        left = shadowBlurSlice(twiceRadius.width, radii.topLeft.width, radii.bottomLeft.width)
        right = shadowBlurSlice(twiceRadius.width, radii.topRight.width, radii.bottomRight.width)

        top = shadowBlurSlice(twiceRadius.height, radii.topLeft.height, radii.topRight.height)
        bottom = shadowBlurSlice(twiceRadius.height, radii.bottomLeft.height, radii.bottomRight.height)
    }
}

// The template's rect inside its blurred edges.
private func shadowBlurTemplateInterior(
    _ templateSize: ShadowBlurIntSize,
    _ edgeSize: ShadowBlurIntSize
) -> WebCore.ShadowBlurRect {
    WebCore.ShadowBlurRect(
        x: Float(edgeSize.width),
        y: Float(edgeSize.height),
        width: Float(templateSize.width &- 2 &* edgeSize.width),
        height: Float(templateSize.height &- 2 &* edgeSize.height)
    )
}

// These functions use tiling to improve the performance of the shadow
// drawing of rounded rectangles. The code basically does the following
// steps:
//
//    1. Calculate the size of the shadow template, a rectangle that
//    contains all the necessary tiles to draw the complete shadow.
//
//    2. If that size is smaller than the real rectangle render the new
//    template rectangle and its shadow in a new surface, in other case
//    render the shadow of the real rectangle in the destination
//    surface.
//
//    3. Calculate the sizes and positions of the tiles and their
//    destinations and use drawPattern to render the final shadow. The
//    code divides the rendering in 8 tiles:
//
//       1 | 2 | 3
//      -----------
//       4 |   | 5
//      -----------
//       6 | 7 | 8
//
//    The corners are directly copied from the template rectangle to the
//    real one and the side tiles are 1 pixel width, we use them as
//    tiles to cover the destination side. The corner tiles are bigger
//    than just the side of the rounded corner, we need to increase it
//    because the modifications caused by the corner over the blur
//    effect. We fill the central or outer part with solid color to complete
//    the shadow.
private func shadowBlurTiles(
    _ shadowBounds: WebCore.ShadowBlurRect,
    _ radii: WebCore.ShadowBlurCornerRadii,
    _ bufferPadding: ShadowBlurIntSize,
    _ templateSize: ShadowBlurIntSize
) -> ShadowBlurTiles {
    let twiceRadius = ShadowBlurIntSize(width: bufferPadding.width &* 2, height: bufferPadding.height &* 2)

    let slices = ShadowBlurSlices(twiceRadius, radii)
    let leftSlice = Float(slices.left)
    let rightSlice = Float(slices.right)
    let topSlice = Float(slices.top)
    let bottomSlice = Float(slices.bottom)

    let centerWidth = Int32(arm64Truncating: shadowBounds.width - leftSlice - rightSlice)
    let centerHeight = Int32(arm64Truncating: shadowBounds.height - topSlice - bottomSlice)
    let centerRect = WebCore.ShadowBlurRect(
        x: shadowBounds.x + leftSlice,
        y: shadowBounds.y + topSlice,
        width: Float(centerWidth),
        height: Float(centerHeight)
    )

    var tiles = ShadowBlurTiles()
    tiles.center = centerRect

    let templateSideLength = Float(shadowBlurTemplateSideLength)
    let bottomTileY = Float(templateSize.height &- slices.bottom)
    let rightTileX = Float(templateSize.width &- slices.right)

    // Top side.
    tiles.top.source = WebCore.ShadowBlurRect(x: leftSlice, y: 0, width: templateSideLength, height: topSlice)
    tiles.top.destination = WebCore.ShadowBlurRect(
        x: centerRect.x,
        y: centerRect.y - topSlice,
        width: centerRect.width,
        height: topSlice
    )

    // Draw the bottom side.
    tiles.bottom.source = WebCore.ShadowBlurRect(x: leftSlice, y: bottomTileY, width: templateSideLength, height: bottomSlice)
    tiles.bottom.destination = WebCore.ShadowBlurRect(
        x: centerRect.x,
        y: centerRect.maxY,
        width: centerRect.width,
        height: bottomSlice
    )

    // Left side.
    tiles.left.source = WebCore.ShadowBlurRect(x: 0, y: topSlice, width: leftSlice, height: templateSideLength)
    tiles.left.destination = WebCore.ShadowBlurRect(
        x: centerRect.x - leftSlice,
        y: centerRect.y,
        width: leftSlice,
        height: centerRect.height
    )

    // Right side.
    tiles.right.source = WebCore.ShadowBlurRect(x: rightTileX, y: topSlice, width: rightSlice, height: templateSideLength)
    tiles.right.destination = WebCore.ShadowBlurRect(
        x: centerRect.maxX,
        y: centerRect.y,
        width: rightSlice,
        height: centerRect.height
    )

    // Top left corner.
    tiles.topLeft.source = WebCore.ShadowBlurRect(x: 0, y: 0, width: leftSlice, height: topSlice)
    tiles.topLeft.destination = WebCore.ShadowBlurRect(
        x: centerRect.x - leftSlice,
        y: centerRect.y - topSlice,
        width: leftSlice,
        height: topSlice
    )

    // Top right corner.
    tiles.topRight.source = WebCore.ShadowBlurRect(x: rightTileX, y: 0, width: rightSlice, height: topSlice)
    tiles.topRight.destination = WebCore.ShadowBlurRect(
        x: centerRect.maxX,
        y: centerRect.y - topSlice,
        width: rightSlice,
        height: topSlice
    )

    // Bottom right corner.
    tiles.bottomRight.source = WebCore.ShadowBlurRect(x: rightTileX, y: bottomTileY, width: rightSlice, height: bottomSlice)
    tiles.bottomRight.destination = WebCore.ShadowBlurRect(
        x: centerRect.maxX,
        y: centerRect.maxY,
        width: rightSlice,
        height: bottomSlice
    )

    // Bottom left corner.
    tiles.bottomLeft.source = WebCore.ShadowBlurRect(x: 0, y: bottomTileY, width: leftSlice, height: bottomSlice)
    tiles.bottomLeft.destination = WebCore.ShadowBlurRect(
        x: centerRect.x - leftSlice,
        y: centerRect.maxY,
        width: leftSlice,
        height: bottomSlice
    )

    return tiles
}

#endif // ENABLE_WEBCORE_SWIFT
