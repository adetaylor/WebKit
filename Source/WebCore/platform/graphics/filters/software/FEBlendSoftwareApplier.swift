// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies)
// Copyright (C) 2014 Adobe Systems Incorporated. All rights reserved.
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

import WebCore_Internal.FEBlendParameters
import WebCore_Internal.FilterGraphicsBridge
import WebCore_Internal.FloatPoint
import WebCore_Internal.FloatRect
import WebCore_Internal.GraphicsContextSwiftBridge
import WebCore_Internal.ImageBuffer
import WebCore_Internal.IntRect

// FEBlendSoftwareApplier::apply(): the second input, then the first blended over it with the blend mode.
func feBlendApplySoftware(
    _ parameters: borrowing WebCore.FEBlendParameters,
    _ input: inout FilterImageImpl,
    _ input2: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }
    let inputImageBuffer = input.imageBuffer()
    let inputImageBuffer2 = input2.imageBuffer()
    return drawBlend(
        parameters,
        resultImage,
        inputImageBuffer,
        input.absoluteImageRect(relativeTo: result),
        inputImageBuffer2,
        input2.absoluteImageRect(relativeTo: result)
    )
}

// feBlendApplySoftware() with both inputs the same image, which can't be passed `inout` twice.
func feBlendApplySoftwareWithSameInputs(
    _ parameters: borrowing WebCore.FEBlendParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }
    let inputImageBuffer = input.imageBuffer()
    let inputImageBuffer2 = input.imageBuffer()
    let inputImageRect = input.absoluteImageRect(relativeTo: result)
    return drawBlend(parameters, resultImage, inputImageBuffer, inputImageRect, inputImageBuffer2, inputImageRect)
}

private func drawBlend(
    _ parameters: borrowing WebCore.FEBlendParameters,
    _ resultImage: WebCore.ImageBuffer,
    _ inputImageBuffer: borrowing WebCore.RefPtrImageBuffer,
    _ inputImageRect: WebCore.IntRect,
    _ inputImageBuffer2: borrowing WebCore.RefPtrImageBuffer,
    _ inputImageRect2: WebCore.IntRect
) -> Bool {
    guard let inputImage = inputImageBuffer.get(), let inputImage2 = inputImageBuffer2.get() else {
        return false
    }
    let drawing = WebCore.ImageBufferDrawing(resultImage)
    let context = drawing.context()
    context.drawImageBuffer(inputImage2, WebCore.FloatRect(inputImageRect2), .SourceOver)
    context.drawImageBuffer(
        inputImage,
        WebCore.FloatRect(inputImageRect),
        WebCore.FloatRect(WebCore.FloatPoint(), inputImage.logicalSize()),
        .SourceOver,
        parameters.mode
    )
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
