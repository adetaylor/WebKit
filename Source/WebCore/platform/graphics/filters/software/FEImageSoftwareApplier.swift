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

import WebCore_Internal.FEImageParameters
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatPoint
import WebCore_Internal.FloatRect
import WebCore_Internal.FloatSize
import WebCore_Internal.GraphicsContextSwiftBridge
import WebCore_Internal.ImageBuffer
import WebCore_Internal.IntPoint
import WebCore_Internal.IntRect

// FEImageSoftwareApplier::apply(): all of the source image drawn into its place in the result. NativeImage sources are
// drawn by C++ (FEImageBridge.cpp).
func feImageApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEImageParameters,
    _ source: WebCore.FEImageSource,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }

    let sourceImageRect = parameters.sourceImageRect
    if sourceImageRect.isEmpty() {
        return true
    }

    switch source.kind {
    case .NativeImage:
        var imageRect = context.scaledByFilterScale(sourceImageRect)
        imageRect.moveBy(negatedLocation(result.absoluteImageRect))
        source.drawNativeImage(resultImage, WebCore.roundedIntRect(imageRect))
        return true
    case .ImageBuffer:
        var destinationRect = sourceImageRect
        destinationRect.moveBy(result.primitiveSubregion.location())
        destinationRect.scale(context.filterScale)
        destinationRect.moveBy(negatedLocation(result.absoluteImageRect))
        let sourceImageBuffer = source.imageBuffer()
        guard let imageBuffer = sourceImageBuffer.get() else {
            return true
        }
        let bufferBounds = WebCore.FloatRect(WebCore.FloatPoint(), imageBuffer.logicalSize())
        let drawing = WebCore.ImageBufferDrawing(resultImage)
        drawing.context().drawImageBuffer(imageBuffer, destinationRect, bufferBounds, .SourceOver, .Normal)
        return true
    case .None:
        assertionFailure()
        return false
    @unknown default:
        return false
    }
}

// -rect.location() as a FloatPoint, the negation wrapping on overflow.
private func negatedLocation(_ rect: WebCore.IntRect) -> WebCore.FloatPoint {
    let location = rect.location()
    return WebCore.FloatPoint(WebCore.IntPoint(0 &- location.x(), 0 &- location.y()))
}

#endif // ENABLE_WEBCORE_SWIFT
