// Copyright (C) Research In Motion Limited 2011. All rights reserved.
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
// Copyright (C) 2024 Igalia S.L.
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

import WebCore_Internal.Color
import WebCore_Internal.ColorSpace
import WebCore_Internal.FEDropShadowParameters
import WebCore_Internal.FilterGraphicsBridge
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatPoint
import WebCore_Internal.FloatRect
import WebCore_Internal.FloatSize
import WebCore_Internal.GraphicsContextSwiftBridge
import WebCore_Internal.ImageBuffer
import WebCore_Internal.ImageBufferAllocator
import WebCore_Internal.IntPoint
import WebCore_Internal.IntRect
import WebCore_Internal.IntSize
import WebCore_Internal.PixelBuffer
import WebCore_Internal.PixelBufferFormat
import WebCore_Internal.PixelBufferSwiftBridge
import WebCore_Internal.ShadowBlurSwiftBridge
#if USE_SKIA
import WebCore_Internal.FilterSkiaBridge
#endif

// FEDropShadow::calculateImageRect(): the input rect, its shadow's, and the blur around both.
func feDropShadowImageRect(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDropShadowParameters,
    _ inputImageRect: WebCore.FloatRect,
    _ primitiveSubregion: WebCore.FloatRect
) -> WebCore.FloatRect {
    var imageRect = inputImageRect
    var imageRectWithOffset = imageRect
    imageRectWithOffset.move(context.resolvedSize(WebCore.FloatSize(parameters.dx, parameters.dy)))
    imageRect.unite(imageRectWithOffset)

    let kernelSize = feGaussianBlurUnscaledKernelSize(
        context.resolvedSize(WebCore.FloatSize(parameters.stdDeviationX, parameters.stdDeviationY))
    )

    // Three times half the box size, since the box blur runs three times.
    imageRect.inflateX(Float(3 * kernelSize.width()) * 0.5)
    imageRect.inflateY(Float(3 * kernelSize.height()) * 0.5)
    return context.clipToMaxEffectRect(imageRect, primitiveSubregion)
}

// FEDropShadow::calculateOutsets().
@_expose(Cxx)
func feDropShadowOutsets(_ offset: WebCore.FloatSize, _ stdDeviation: WebCore.FloatSize) -> WebCore.FilterOutsets {
    let outsetSize = feGaussianBlurOutsetSize(stdDeviation)
    let width = Float(outsetSize.width())
    let height = Float(outsetSize.height())

    // std::max<int>(0, outset - offset) converts the float difference to int as arm64 does.
    return WebCore.FilterOutsets(
        top: max(0, Int32(arm64Truncating: height - offset.height())),
        right: max(0, Int32(arm64Truncating: width + offset.width())),
        bottom: max(0, Int32(arm64Truncating: height + offset.height())),
        left: max(0, Int32(arm64Truncating: width - offset.width()))
    )
}

// FEDropShadowSoftwareApplier::apply(): the input drawn at the offset with the shadow opacity, blurred by ShadowBlur,
// filled with the shadow color, and the input drawn over it.
func feDropShadowApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDropShadowParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }

    let stdDeviation = context.resolvedSize(WebCore.FloatSize(parameters.stdDeviationX, parameters.stdDeviationY))
    let scaledStdDeviation = context.scaledByFilterScale(stdDeviation)
    let blurRadius = WebCore.FloatSize(2 * scaledStdDeviation.width(), 2 * scaledStdDeviation.height())

    let offset = context.resolvedSize(WebCore.FloatSize(parameters.dx, parameters.dy))
    let absoluteOffset = context.scaledByFilterScale(offset)

    let inputImageRect = WebCore.FloatRect(input.absoluteImageRect(relativeTo: result))
    var inputImageRectWithOffset = inputImageRect
    inputImageRectWithOffset.move(absoluteOffset)

    guard let inputImage = input.imageBuffer().get() else {
        return false
    }

    let drawing = WebCore.ImageBufferDrawing(resultImage)
    let resultContext = drawing.context()
    resultContext.setAlpha(parameters.shadowOpacity)
    resultContext.drawImageBuffer(inputImage, inputImageRectWithOffset, .SourceOver)
    resultContext.setAlpha(1)

    if !feDropShadowBlur(resultImage, blurRadius, absoluteOffset, parameters.shadowColor, result.colorSpace) {
        return false
    }

    let shadowRect = WebCore.FloatRect(WebCore.FloatPoint(), WebCore.FloatSize(result.absoluteImageRect.size()))
    resultContext.setCompositeOperation(.SourceIn, .Normal)
    resultContext.fillRect(shadowRect, parameters.shadowColor)
    resultContext.setCompositeOperation(.DestinationOver, .Normal)
    resultContext.drawImageBuffer(inputImage, inputImageRect, .SourceOver)
    return true
}

// Blurs the image in place with ShadowBlur's layer blur, as a ShadowBlur of the radius, offset and color would. False if
// its pixels can't be read.
private func feDropShadowBlur(
    _ image: WebCore.ImageBuffer,
    _ blurRadius: WebCore.FloatSize,
    _ offset: WebCore.FloatSize,
    _ color: borrowing WebCore.Color,
    _ colorSpace: borrowing WebCore.ColorSpace
) -> Bool {
    let shadow = shadowBlurState(
        WebCore.ShadowBlurSize(width: blurRadius.width(), height: blurRadius.height()),
        WebCore.ShadowBlurSize(width: offset.width(), height: offset.height()),
        color.isVisible(),
        false,
        false
    )

    let format = WebCore.PixelBufferFormat(alphaFormat: .Premultiplied, pixelFormat: .RGBA8, colorSpace: copy colorSpace)
    let shadowArea = WebCore.IntRect(WebCore.IntPoint(), image.truncatedLogicalSize())
    let shadowData = image.getPixelBuffer(format, shadowArea, WebCore.ImageBufferAllocator())
    guard let pixelBuffer = shadowData.get() else {
        return false
    }

    let size = WebCore.FilterGraphicsBridge.size(pixelBuffer)
    var access = WebCore.PixelBufferAccess(pixelBuffer)
    var bytes: MutableSpan<UInt8> = access.mutableSpan()
    shadow.blur(&bytes, size.width(), size.height(), 4 &* size.width())
    WebCore.FilterGraphicsBridge.putPixelBuffer(image, pixelBuffer, shadowArea)
    return true
}

#if USE_SKIA
// FEDropShadowSkiaApplier::apply(): Skia draws the drop shadow (FilterSkiaBridge.cpp).
func feDropShadowApplySkia(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDropShadowParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let resultImage = result.imageBuffer()
    let sourceImage = input.imageBuffer()
    guard let resultImage = resultImage.get(), let sourceImage = sourceImage.get() else {
        return false
    }
    let offset = context.scaledByFilterScale(context.resolvedSize(WebCore.FloatSize(parameters.dx, parameters.dy)))
    let sigma = context.scaledByFilterScale(context.resolvedSize(WebCore.FloatSize(parameters.stdDeviationX, parameters.stdDeviationY)))
    let inputOffsetWithinResult = input.absoluteImageRect(relativeTo: result).location()
    return WebCore.FilterSkiaBridge.drawDropShadow(resultImage, sourceImage, offset, sigma, parameters, inputOffsetWithinResult)
}
#endif

#endif // ENABLE_WEBCORE_SWIFT
