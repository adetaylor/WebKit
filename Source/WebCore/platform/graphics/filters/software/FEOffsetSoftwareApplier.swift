// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
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

import WebCore_Private.Core.FEOffsetParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize

// FEOffset::calculateImageRect(): the input image rect, moved by the offset.
func feOffsetImageRect(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEOffsetParameters,
    _ inputImageRect: WebCore.FloatRect,
    _ primitiveSubregion: WebCore.FloatRect
) -> WebCore.FloatRect {
    var imageRect = inputImageRect
    imageRect.move(context.resolvedSize(WebCore.FloatSize(parameters.dx, parameters.dy)))
    return context.clipToMaxEffectRect(imageRect, primitiveSubregion)
}

// FEOffset::calculateOutsets(), the negation of a negative offset wrapping on overflow.
@_expose(Cxx)
func feOffsetOutsets(_ offset: WebCore.FloatSize) -> WebCore.FilterOutsets {
    let adjustedOffset = WebCore.expandedIntSize(offset)
    let width = adjustedOffset.width()
    let height = adjustedOffset.height()
    return WebCore.FilterOutsets(
        top: height < 0 ? 0 &- height : 0,
        right: width < 0 ? 0 : width,
        bottom: height < 0 ? 0 : height,
        left: width < 0 ? 0 &- width : 0
    )
}

// FEOffsetSoftwareApplier::apply(): the input drawn at the offset.
func feOffsetApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEOffsetParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let resultImageBuffer = result.imageBuffer()
    let inputImageBuffer = input.imageBuffer()
    guard let resultImage = resultImageBuffer.get(), let inputImage = inputImageBuffer.get() else {
        return false
    }

    var inputImageRect = WebCore.FloatRect(input.absoluteImageRect(relativeTo: result))
    let offset = context.resolvedSize(WebCore.FloatSize(parameters.dx, parameters.dy))
    inputImageRect.move(context.scaledByFilterScale(offset))

    let drawing = WebCore.ImageBufferDrawing(resultImage)
    drawing.context().drawImageBuffer(inputImage, inputImageRect, .SourceOver)
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
