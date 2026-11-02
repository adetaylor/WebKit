// Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
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

#if ENABLE_WEBCORE_SWIFT

import WebCore_Private.Core.AffineTransform
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntPoint
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelFormat
import WebCore_Private.Core.RenderingMode

// FETileSoftwareApplier::apply(): the input drawn into a new image of the tile rect (filter coordinates scaled by the
// filter scale), and the result filled with that image repeated. False if the image can't be created.
func feTileApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let resultImageBuffer = result.imageBuffer()
    let inputImageBuffer = input.imageBuffer()
    guard let resultImage = resultImageBuffer.get(), let inputImage = inputImageBuffer.get() else {
        return false
    }

    let tileRect = context.scaledByFilterScale(context.maxEffectRect(input.primitiveSubregion))
    let maxResultRect = context.scaledByFilterScale(context.maxEffectRect(result.primitiveSubregion))

    let tileImageBuffer = WebCore.ImageBuffer.create(
        tileRect.size(),
        result.renderingMode,
        .Unspecified,
        1,
        WebCore.GraphicsContextSwiftBridge.sRGBColorSpace(),
        .BGRA8,
        nil
    )
    guard let tileImage = tileImageBuffer.get() else {
        return false
    }

    let tileLocation = tileRect.location()
    let tileDrawing = WebCore.ImageBufferDrawing(tileImage)
    let tileContext = tileDrawing.context()
    tileContext.translate(WebCore.FloatSize(-tileLocation.x(), -tileLocation.y()))
    tileContext.drawImageBuffer(inputImage, WebCore.FloatPoint(input.absoluteImageRect.location()), .SourceOver)

    // AffineTransform().translate(tileRect.location() - maxResultRect.location()): the identity's translation is 0 plus
    // the offset.
    let patternOffset = WebCore.FloatSize(tileLocation.x() - maxResultRect.x(), tileLocation.y() - maxResultRect.y())
    let patternTransform = WebCore.AffineTransform(1, 0, 0, 1, 0 + Double(patternOffset.width()), 0 + Double(patternOffset.height()))

    let resultDrawing = WebCore.ImageBufferDrawing(resultImage)
    let resultContext = resultDrawing.context()
    resultContext.setFillPattern(tileImage, patternTransform)
    resultContext.fillRect(WebCore.FloatRect(WebCore.FloatPoint(), WebCore.FloatSize(result.absoluteImageRect.size())))
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
