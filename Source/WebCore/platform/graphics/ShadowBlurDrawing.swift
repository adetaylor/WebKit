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

// The safe MutableSpan overload Swift synthesizes for PixelBufferAccess's span accessor comes from Cxx. Xcode builds
// don't find it unless this file imports Cxx.
private import Cxx
#if USE_CG
import Synchronization
#endif
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.Color
import WebCore_Private.Core.ColorSpace
import WebCore_Private.Core.CompositeOperation
import WebCore_Private.Core.CornerRadii
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatRoundedRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.GraphicsTypes
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.ImageBufferAllocator
import WebCore_Private.Core.IntPoint
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.Path
import WebCore_Private.Core.PathSegmentData
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferFormat
import WebCore_Private.Core.PixelBufferSwiftBridge
import WebCore_Private.Core.PixelFormat
import WebCore_Private.Core.RenderingMode
import WebCore_Private.Core.ShadowBlurSwiftBridge
import WebCore_Private.Core.WindRule

// Where a shadow is drawn: into the GraphicsContext of the GraphicsContext overloads of ShadowBlur::drawRectShadow() and
// drawInsetShadow(), or else through the callbacks of the other overloads.
@inline(never)
private func shadowBlurDrawBuffer(
    _ destination: borrowing WebCore.ShadowBlurDestination,
    _ layerImage: WebCore.ImageBuffer,
    _ layerOrigin: WebCore.FloatPoint,
    _ layerSize: WebCore.FloatSize,
    _ color: borrowing WebCore.Color
) {
    if destination.hasGraphicsContext() {
        shadowBlurDrawShadowBuffer(destination.graphicsContext(), layerImage, layerOrigin, layerSize, color)
    } else {
        destination.drawBuffer(layerImage, layerOrigin, layerSize)
    }
}

@inline(never)
private func shadowBlurDrawImage(
    _ destination: borrowing WebCore.ShadowBlurDestination,
    _ image: WebCore.ImageBuffer,
    _ destRect: WebCore.FloatRect,
    _ srcRect: WebCore.FloatRect
) {
    if destination.hasGraphicsContext() {
        shadowBlurDrawImage(destination.graphicsContext(), image, destRect, srcRect)
    } else {
        destination.drawImage(image, destRect, srcRect)
    }
}

@inline(never)
private func shadowBlurFillRect(
    _ destination: borrowing WebCore.ShadowBlurDestination,
    _ rect: WebCore.FloatRect,
    _ color: borrowing WebCore.Color
) {
    if destination.hasGraphicsContext() {
        shadowBlurFillRect(destination.graphicsContext(), rect, color)
    } else {
        destination.fillRect(rect, color)
    }
}

@inline(never)
private func shadowBlurFillRectWithHole(
    _ destination: borrowing WebCore.ShadowBlurDestination,
    _ rect: WebCore.FloatRect,
    _ holeRect: WebCore.FloatRect,
    _ color: borrowing WebCore.Color
) {
    if destination.hasGraphicsContext() {
        shadowBlurFillRectWithHole(destination.graphicsContext(), rect, holeRect, color)
    } else {
        destination.fillRectWithHole(rect, holeRect, color)
    }
}

// MARK: The GraphicsContext overloads

// ShadowBlur::drawShadowBuffer().
private func shadowBlurDrawShadowBuffer(
    _ graphicsContext: borrowing WebCore.GraphicsContextView,
    _ layerImage: WebCore.ImageBuffer,
    _ layerOrigin: WebCore.FloatPoint,
    _ layerSize: WebCore.FloatSize,
    _ color: borrowing WebCore.Color
) {
    graphicsContext.save()

    let bufferSize = WebCore.FloatSize(layerImage.backendSize())
    if bufferSize.width() != layerSize.width() || bufferSize.height() != layerSize.height() {
        // The rect passed to clipToNativeImage() has to be the size of the entire buffer,
        // but we may not have cleared it all, so clip to the filled part first.
        graphicsContext.clip(WebCore.FloatRect(layerOrigin, layerSize))
    }
    guard graphicsContext.clipToImageBuffer(layerImage, WebCore.FloatRect(layerOrigin, bufferSize)) else {
        graphicsContext.restore()
        return
    }
    graphicsContext.setFillColor(color)

    graphicsContext.clearDropShadow()
    graphicsContext.fillRect(WebCore.FloatRect(layerOrigin, layerSize))

    graphicsContext.restore()
}

@inline(never)
private func shadowBlurDrawImage(
    _ graphicsContext: borrowing WebCore.GraphicsContextView,
    _ image: WebCore.ImageBuffer,
    _ destRect: WebCore.FloatRect,
    _ srcRect: WebCore.FloatRect
) {
    // Note that drawing the ImageBuffer is faster than creating a Image and drawing that,
    // because ImageBuffer::draw() knows that it doesn't have to copy the image bits.
    graphicsContext.save()
    graphicsContext.clearDropShadow()
    graphicsContext.drawImageBuffer(image, destRect, srcRect, .SourceOver, .Normal)
    graphicsContext.restore()
}

private func shadowBlurFillRect(
    _ graphicsContext: borrowing WebCore.GraphicsContextView,
    _ rect: WebCore.FloatRect,
    _ color: borrowing WebCore.Color
) {
    graphicsContext.save()
    graphicsContext.setFillColor(color)
    graphicsContext.clearDropShadow()
    graphicsContext.fillRect(rect)
    graphicsContext.restore()
}

private func shadowBlurFillRectWithHole(
    _ graphicsContext: borrowing WebCore.GraphicsContextView,
    _ rect: WebCore.FloatRect,
    _ holeRect: WebCore.FloatRect,
    _ color: borrowing WebCore.Color
) {
    var exteriorPath = WebCore.Path()
    exteriorPath.addRect(rect)
    exteriorPath.addRect(holeRect)

    graphicsContext.save()
    graphicsContext.setFillRule(.EvenOdd)
    graphicsContext.setFillColor(color)
    graphicsContext.clearDropShadow()
    graphicsContext.fillPath(exteriorPath)
    graphicsContext.restore()
}

// MARK: Shadows

func shadowBlurDrawRectShadowPlan(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ plan: ShadowBlurRectShadowPlan,
    _ shadowedRect: WebCore.ShadowBlurRect,
    _ radii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    switch plan.drawing {
    case .none:
        return
    case .withoutTiling:
        shadowBlurDrawRectShadowWithoutTiling(shadow, shadowedRect, radii, plan.layer, color, destination)
    case .withTiling:
        shadowBlurDrawRectShadowWithTiling(shadow, plan, radii, color, destination)
    }
}

func shadowBlurDrawInsetShadowPlan(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ plan: ShadowBlurInsetShadowPlan,
    _ fullRect: WebCore.ShadowBlurRect,
    _ holeRect: WebCore.ShadowBlurRect,
    _ holeRadii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    switch plan.drawing {
    case .none:
        return
    case .withoutTiling:
        shadowBlurDrawInsetShadowWithoutTiling(shadow, fullRect, holeRect, holeRadii, plan.layer, color, destination)
    case .withTiling:
        shadowBlurDrawInsetShadowWithTiling(shadow, plan, holeRadii, color, destination)
    }
}

// ShadowBlur::drawShadowLayer().
func shadowBlurDrawShadowLayerPlan(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ plan: ShadowBlurLayerPlan,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    if !plan.draws {
        return
    }

    let layerSize = shadowBlurExpandedIntSize(plan.layer.layerSize)
    let layerImageBuffer = shadowBlurCreateImageBuffer(layerSize)
    guard let layerImage = layerImageBuffer.get() else {
        return
    }

    let layerDrawing = WebCore.ImageBufferDrawing(layerImage)
    let shadowContext = layerDrawing.context()
    shadowContext.save()
    shadowContext.translate(plan.layer.layerContextTranslation.floatSize)
    destination.drawShadow(layerImage)
    shadowContext.restore()

    shadowBlurBlurAndColorShadowBuffer(shadow, layerImage, layerSize, color)
    destination.drawBuffer(layerImage, plan.layer.layerOrigin.floatPoint, plan.layer.layerSize.floatSize)
}

private func shadowBlurDrawRectShadowWithoutTiling(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ shadowedRect: WebCore.ShadowBlurRect,
    _ radii: WebCore.ShadowBlurCornerRadii,
    _ layer: ShadowBlurLayerImageProperties,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    let layerSize = shadowBlurExpandedIntSize(layer.layerSize)
    let layerImageBuffer = shadowBlurCreateImageBuffer(layerSize)
    guard let layerImage = layerImageBuffer.get() else {
        return
    }

    let layerDrawing = WebCore.ImageBufferDrawing(layerImage)
    let shadowContext = layerDrawing.context()
    shadowContext.save()
    shadowContext.setFillColor(WebCore.GraphicsContextSwiftBridge.blackColor())

    shadowContext.save()
    shadowContext.translate(layer.layerContextTranslation.floatSize)
    shadowContext.setFillColor(WebCore.GraphicsContextSwiftBridge.blackColor())
    if radii.isZero {
        shadowContext.fillRect(shadowedRect.floatRect)
    } else {
        var path = WebCore.Path()
        path.addRoundedRect(shadowBlurFloatRoundedRect(shadowedRect, radii), .PreferNative)
        shadowContext.fillPath(path)
    }

    shadowBlurBlurShadowBuffer(shadow, layerImage, layerSize)
    shadowContext.restore()

    shadowBlurDrawBuffer(destination, layerImage, layer.layerOrigin.floatPoint, layer.layerSize.floatSize, color)
    shadowContext.restore()
}

private func shadowBlurDrawInsetShadowWithoutTiling(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ fullRect: WebCore.ShadowBlurRect,
    _ holeRect: WebCore.ShadowBlurRect,
    _ holeRadii: WebCore.ShadowBlurCornerRadii,
    _ layer: ShadowBlurLayerImageProperties,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    let layerSize = shadowBlurExpandedIntSize(layer.layerSize)
    let layerImageBuffer = shadowBlurCreateImageBuffer(layerSize)
    guard let layerImage = layerImageBuffer.get() else {
        return
    }

    let layerDrawing = WebCore.ImageBufferDrawing(layerImage)
    let shadowContext = layerDrawing.context()
    shadowContext.save()
    shadowContext.translate(layer.layerContextTranslation.floatSize)

    var path = WebCore.Path()
    path.addRect(fullRect.floatRect)
    if holeRadii.isZero {
        path.addRect(holeRect.floatRect)
    } else {
        path.addRoundedRect(shadowBlurFloatRoundedRect(holeRect, holeRadii), .PreferNative)
    }

    shadowContext.setFillRule(.EvenOdd)
    shadowContext.setFillColor(WebCore.GraphicsContextSwiftBridge.blackColor())
    shadowContext.fillPath(path)

    shadowBlurBlurShadowBuffer(shadow, layerImage, layerSize)
    shadowContext.restore()

    shadowBlurDrawBuffer(destination, layerImage, layer.layerOrigin.floatPoint, layer.layerSize.floatSize, color)
}

private func shadowBlurDrawRectShadowWithTiling(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ plan: ShadowBlurRectShadowPlan,
    _ radii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    #if USE_CG
    let shadow = copy shadow
    let color = copy color
    let destination = copy destination
    let drewWithScratchBuffer: Bool? = shadowBlurScratchBuffer.withLockIfAvailable { scratchBuffer in
        guard let layerImage = scratchBuffer.imageBuffer(plan.templateSize) else {
            return true
        }
        let redrawNeeded = scratchBuffer.setCachedShadowValues(plan.blurRadius, color, plan.templateShadow, radii, plan.layer.layerSize)
        shadowBlurDrawRectShadowWithTemplate(shadow, layerImage, plan, radii, color, destination, redrawNeeded)
        return true
    }
    if drewWithScratchBuffer != nil {
        return
    }
    #endif

    let layerImageBuffer = shadowBlurCreateImageBuffer(plan.templateSize)
    if let layerImage = layerImageBuffer.get() {
        shadowBlurDrawRectShadowWithTemplate(shadow, layerImage, plan, radii, color, destination, true)
    }
}

// ShadowBlur::drawRectShadowWithTilingWithLayerImageBuffer().
@inline(never)
private func shadowBlurDrawRectShadowWithTemplate(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ layerImage: WebCore.ImageBuffer,
    _ plan: ShadowBlurRectShadowPlan,
    _ radii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination,
    _ redrawNeeded: Bool
) {
    if redrawNeeded {
        // Draw shadow into the ImageBuffer.
        let layerDrawing = WebCore.ImageBufferDrawing(layerImage)
        let shadowContext = layerDrawing.context()
        shadowContext.save()

        shadowContext.clearRect(WebCore.FloatRect(0, 0, Float(plan.templateSize.width), Float(plan.templateSize.height)))
        shadowContext.setFillColor(WebCore.GraphicsContextSwiftBridge.blackColor())

        if radii.isZero {
            shadowContext.fillRect(plan.templateShadow.floatRect)
        } else {
            var path = WebCore.Path()
            path.addRoundedRect(shadowBlurFloatRoundedRect(plan.templateShadow, radii), .PreferNative)
            shadowContext.fillPath(path)
        }
        shadowBlurBlurAndColorShadowBuffer(shadow, layerImage, plan.templateSize, color)
        shadowContext.restore()
    }

    // Fill center
    if plan.tiles.fillsCenter {
        shadowBlurFillRect(destination, plan.tiles.center.floatRect, color)
    }

    shadowBlurDrawLayerPieces(layerImage, plan.tiles, destination)
}

private func shadowBlurDrawInsetShadowWithTiling(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ plan: ShadowBlurInsetShadowPlan,
    _ holeRadii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    #if USE_CG
    let shadow = copy shadow
    let color = copy color
    let destination = copy destination
    let drewWithScratchBuffer: Bool? = shadowBlurScratchBuffer.withLockIfAvailable { scratchBuffer in
        guard let layerImage = scratchBuffer.imageBuffer(plan.templateSize) else {
            return true
        }
        let redrawNeeded = scratchBuffer.setCachedInsetShadowValues(
            plan.blurRadius,
            color,
            plan.templateBounds,
            plan.templateHole,
            holeRadii
        )
        shadowBlurDrawInsetShadowWithTemplate(shadow, layerImage, plan, holeRadii, color, destination, redrawNeeded)
        return true
    }
    if drewWithScratchBuffer != nil {
        return
    }
    #endif

    let layerImageBuffer = shadowBlurCreateImageBuffer(plan.templateSize)
    if let layerImage = layerImageBuffer.get() {
        shadowBlurDrawInsetShadowWithTemplate(shadow, layerImage, plan, holeRadii, color, destination, true)
    }
}

// ShadowBlur::drawInsetShadowWithTilingWithLayerImageBuffer().
@inline(never)
private func shadowBlurDrawInsetShadowWithTemplate(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ layerImage: WebCore.ImageBuffer,
    _ plan: ShadowBlurInsetShadowPlan,
    _ holeRadii: WebCore.ShadowBlurCornerRadii,
    _ color: borrowing WebCore.Color,
    _ destination: borrowing WebCore.ShadowBlurDestination,
    _ redrawNeeded: Bool
) {
    if redrawNeeded {
        // Draw shadow into a new ImageBuffer.
        let layerDrawing = WebCore.ImageBufferDrawing(layerImage)
        let shadowContext = layerDrawing.context()
        shadowContext.save()
        shadowContext.clearRect(plan.templateBounds.floatRect)
        shadowContext.setFillRule(.EvenOdd)
        shadowContext.setFillColor(WebCore.GraphicsContextSwiftBridge.blackColor())

        var path = WebCore.Path()
        path.addRect(plan.templateBounds.floatRect)
        if holeRadii.isZero {
            path.addRect(plan.templateHole.floatRect)
        } else {
            path.addRoundedRect(shadowBlurFloatRoundedRect(plan.templateHole, holeRadii), .PreferNative)
        }

        shadowContext.fillPath(path)

        shadowBlurBlurAndColorShadowBuffer(shadow, layerImage, plan.templateSize, color)
        shadowContext.restore()
    }

    // Fill the external part of the shadow (which may be visible because of offset).
    shadowBlurFillRectWithHole(destination, plan.boundingRect.floatRect, plan.holeBounds.floatRect, color)

    shadowBlurDrawLayerPieces(layerImage, plan.tiles, destination)
}

@inline(never)
private func shadowBlurDrawLayerPieces(
    _ layerImage: WebCore.ImageBuffer,
    _ tiles: ShadowBlurTiles,
    _ destination: borrowing WebCore.ShadowBlurDestination
) {
    if destination.hasGraphicsContext() {
        let graphicsContext = destination.graphicsContext()
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.top.destination.floatRect, tiles.top.source.floatRect)
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.bottom.destination.floatRect, tiles.bottom.source.floatRect)
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.left.destination.floatRect, tiles.left.source.floatRect)
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.right.destination.floatRect, tiles.right.source.floatRect)
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.topLeft.destination.floatRect, tiles.topLeft.source.floatRect)
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.topRight.destination.floatRect, tiles.topRight.source.floatRect)
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.bottomRight.destination.floatRect, tiles.bottomRight.source.floatRect)
        shadowBlurDrawImage(graphicsContext, layerImage, tiles.bottomLeft.destination.floatRect, tiles.bottomLeft.source.floatRect)
        return
    }
    destination.drawImage(layerImage, tiles.top.destination.floatRect, tiles.top.source.floatRect)
    destination.drawImage(layerImage, tiles.bottom.destination.floatRect, tiles.bottom.source.floatRect)
    destination.drawImage(layerImage, tiles.left.destination.floatRect, tiles.left.source.floatRect)
    destination.drawImage(layerImage, tiles.right.destination.floatRect, tiles.right.source.floatRect)
    destination.drawImage(layerImage, tiles.topLeft.destination.floatRect, tiles.topLeft.source.floatRect)
    destination.drawImage(layerImage, tiles.topRight.destination.floatRect, tiles.topRight.source.floatRect)
    destination.drawImage(layerImage, tiles.bottomRight.destination.floatRect, tiles.bottomRight.source.floatRect)
    destination.drawImage(layerImage, tiles.bottomLeft.destination.floatRect, tiles.bottomLeft.source.floatRect)
}

// ShadowBlur::blurShadowBuffer().
@inline(never)
private func shadowBlurBlurShadowBuffer(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ layerImage: WebCore.ImageBuffer,
    _ templateSize: ShadowBlurIntSize
) {
    if !shadow.isBlurShadow {
        return
    }

    let format = WebCore.PixelBufferFormat(
        alphaFormat: .Unpremultiplied,
        pixelFormat: .RGBA8,
        colorSpace: WebCore.GraphicsContextSwiftBridge.sRGBColorSpace()
    )
    let blurRect = WebCore.IntRect(WebCore.IntPoint(), WebCore.IntSize(templateSize.width, templateSize.height))
    let layerData = layerImage.getPixelBuffer(format, blurRect, WebCore.ImageBufferAllocator())
    guard let pixelBuffer = layerData.get() else {
        return
    }

    let size = WebCore.FilterGraphicsBridge.size(pixelBuffer)
    var access = WebCore.PixelBufferAccess(pixelBuffer)
    var bytes: MutableSpan<UInt8> = access.mutableSpan()
    shadow.blur(&bytes, size.width(), size.height(), size.width() &* 4)
    WebCore.FilterGraphicsBridge.putPixelBuffer(layerImage, pixelBuffer, blurRect)
}

// ShadowBlur::blurAndColorShadowBuffer().
@inline(never)
private func shadowBlurBlurAndColorShadowBuffer(
    _ shadow: borrowing WebCore.ShadowBlurState,
    _ layerImage: WebCore.ImageBuffer,
    _ templateSize: ShadowBlurIntSize,
    _ color: borrowing WebCore.Color
) {
    shadowBlurBlurShadowBuffer(shadow, layerImage, templateSize)

    // Mask the image with the shadow color.
    let layerDrawing = WebCore.ImageBufferDrawing(layerImage)
    let shadowContext = layerDrawing.context()
    shadowContext.save()
    shadowContext.setCompositeOperation(.SourceIn, .Normal)
    shadowContext.setFillColor(color)
    shadowContext.fillRect(WebCore.FloatRect(0, 0, Float(templateSize.width), Float(templateSize.height)))
    shadowContext.restore()
}

@inline(never)
private func shadowBlurCreateImageBuffer(_ size: ShadowBlurIntSize) -> WebCore.RefPtrImageBuffer {
    WebCore.ImageBuffer.create(
        WebCore.FloatSize(Float(size.width), Float(size.height)),
        .Unaccelerated,
        .Unspecified,
        1,
        WebCore.GraphicsContextSwiftBridge.sRGBColorSpace(),
        .BGRA8,
        nil
    )
}

@inline(never)
private func shadowBlurFloatRoundedRect(
    _ rect: WebCore.ShadowBlurRect,
    _ radii: WebCore.ShadowBlurCornerRadii
) -> WebCore.FloatRoundedRect {
    WebCore.FloatRoundedRect(
        rect.floatRect,
        radii.topLeft.floatSize,
        radii.topRight.floatSize,
        radii.bottomLeft.floatSize,
        radii.bottomRight.floatSize
    )
}

// CornerRadii::isZero().
extension WebCore.ShadowBlurCornerRadii {
    fileprivate var isZero: Bool {
        topLeft.isZero && topRight.isZero && bottomLeft.isZero && bottomRight.isZero
    }
}

extension WebCore.ShadowBlurSize {
    var floatSize: WebCore.FloatSize {
        WebCore.FloatSize(width, height)
    }

    // FloatSize::isZero().
    fileprivate var isZero: Bool {
        abs(width) < Float.ulpOfOne && abs(height) < Float.ulpOfOne
    }
}

extension ShadowBlurPoint {
    var floatPoint: WebCore.FloatPoint {
        WebCore.FloatPoint(x, y)
    }
}

// MARK: The scratch buffer

#if USE_CG
// ShadowBlur needs a scratch image as the buffer for the blur filter.
// Instead of creating and destroying the buffer for every operation,
// we create a buffer which will be automatically purged via a timer.
//
// The C++ values in it are only used under the mutex.
private struct ShadowBlurScratchBuffer: ~Copyable, @unchecked Sendable {
    private var buffer = WebCore.RefPtrImageBuffer()

    private var lastInsetBounds = WebCore.ShadowBlurRect()
    private var lastShadowRect = WebCore.ShadowBlurRect()
    private var lastRadii = WebCore.ShadowBlurCornerRadii()
    private var lastColor = WebCore.Color()
    private var lastRadius = WebCore.ShadowBlurSize()
    private var lastWasInset = false
    private var lastLayerSize = WebCore.ShadowBlurSize()

    mutating func imageBuffer(_ size: ShadowBlurIntSize) -> WebCore.ImageBuffer? {
        defer {
            if buffer.get() != nil {
                WebCore.scheduleShadowBlurScratchBufferPurge()
            }
        }

        // We do not need to recreate the buffer if the current buffer is large enough.
        if let imageBuffer = buffer.get() {
            let bufferSize = imageBuffer.truncatedLogicalSize()
            if bufferSize.width() >= size.width && bufferSize.height() >= size.height {
                return imageBuffer
            }
        }

        // Round to the nearest 32 pixels so we do not grow the buffer for similar sized requests.
        let roundedSize = ShadowBlurIntSize(width: roundUpToMultipleOf32(size.width), height: roundUpToMultipleOf32(size.height))

        clear()

        // ShadowBlur is not used with accelerated drawing, so it's OK to make an unconditionally unaccelerated buffer.
        buffer = shadowBlurCreateImageBuffer(roundedSize)
        return buffer.get()
    }

    mutating func setCachedShadowValues(
        _ radius: WebCore.ShadowBlurSize,
        _ color: borrowing WebCore.Color,
        _ shadowRect: WebCore.ShadowBlurRect,
        _ radii: WebCore.ShadowBlurCornerRadii,
        _ layerSize: WebCore.ShadowBlurSize
    ) -> Bool {
        let sameColor = lastColor == color
        if !lastWasInset && lastRadius.equals(radius) && sameColor && lastShadowRect.equals(shadowRect) && lastRadii.equals(radii)
            && lastLayerSize.equals(layerSize)
        {
            return false
        }

        lastWasInset = false
        lastRadius = radius
        lastColor = copy color
        lastShadowRect = shadowRect
        lastRadii = radii
        lastLayerSize = layerSize

        return true
    }

    mutating func setCachedInsetShadowValues(
        _ radius: WebCore.ShadowBlurSize,
        _ color: borrowing WebCore.Color,
        _ bounds: WebCore.ShadowBlurRect,
        _ shadowRect: WebCore.ShadowBlurRect,
        _ radii: WebCore.ShadowBlurCornerRadii
    ) -> Bool {
        let sameColor = lastColor == color
        if lastWasInset && lastRadius.equals(radius) && sameColor && lastInsetBounds.equals(bounds)
            && shadowRect.equals(lastShadowRect) && radii.equals(lastRadii)
        {
            return false
        }

        lastWasInset = true
        lastInsetBounds = bounds
        lastRadius = radius
        lastColor = copy color
        lastShadowRect = shadowRect
        lastRadii = radii

        return true
    }

    mutating func clear() {
        buffer = WebCore.RefPtrImageBuffer()
        lastRadius = WebCore.ShadowBlurSize()
        lastLayerSize = WebCore.ShadowBlurSize()
    }

    private func roundUpToMultipleOf32(_ d: Int32) -> Int32 {
        (1 &+ (d >> 5)) &<< 5
    }
}

private let shadowBlurScratchBuffer = Mutex(ShadowBlurScratchBuffer())

// The scratch buffer's purge timer fired.
@_expose(Cxx)
func purgeShadowBlurScratchBuffer() {
    _ = shadowBlurScratchBuffer.withLockIfAvailable { scratchBuffer in
        scratchBuffer.clear()
    }
}

// The operator== of FloatSize, FloatRect and CornerRadii.
extension WebCore.ShadowBlurSize {
    fileprivate func equals(_ other: WebCore.ShadowBlurSize) -> Bool {
        width == other.width && height == other.height
    }
}

extension WebCore.ShadowBlurRect {
    fileprivate func equals(_ other: WebCore.ShadowBlurRect) -> Bool {
        x == other.x && y == other.y && width == other.width && height == other.height
    }
}

extension WebCore.ShadowBlurCornerRadii {
    fileprivate func equals(_ other: WebCore.ShadowBlurCornerRadii) -> Bool {
        topLeft.equals(other.topLeft) && topRight.equals(other.topRight) && bottomLeft.equals(other.bottomLeft)
            && bottomRight.equals(other.bottomRight)
    }
}
#endif // USE_CG

#endif // ENABLE_WEBCORE_SWIFT
