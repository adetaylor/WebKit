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

import WebCore_Private.Core.FECompositeParameters
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.GraphicsTypes
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntPoint
import WebCore_Private.Core.IntRect

// FEComposite::calculateImageRect(): from the second input's image rect and the union of both.
func feCompositeImageRect(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FECompositeParameters,
    secondInputImageRect: WebCore.FloatRect?,
    unitedInputImageRects: WebCore.FloatRect,
    _ primitiveSubregion: WebCore.FloatRect
) -> WebCore.FloatRect {
    switch parameters.operation {
    case .FECOMPOSITE_OPERATOR_IN, .FECOMPOSITE_OPERATOR_ATOP:
        // For In and Atop the first FilterImage just influences the result of the second FilterImage. So just use the
        // rect of the second FilterImage here.
        guard let secondInputImageRect else {
            preconditionFailure()
        }
        return context.clipToMaxEffectRect(secondInputImageRect, primitiveSubregion)
    case .FECOMPOSITE_OPERATOR_ARITHMETIC:
        // Arithmetic may influence the entire filter primitive region. So we can't optimize the paint region here.
        return context.maxEffectRect(primitiveSubregion)
    default:
        // Take the union of both input effects.
        return context.clipToMaxEffectRect(unitedInputImageRects, primitiveSubregion)
    }
}

// FECompositeSoftwareApplier::apply(): the operators other than arithmetic, as two draws of the inputs into the result.
func feCompositeApplySoftware(
    _ parameters: borrowing WebCore.FECompositeParameters,
    _ input: inout FilterImageImpl,
    _ input2: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }
    let inputImage = input.imageBuffer()
    let inputImage2 = input2.imageBuffer()
    guard let inputImage = inputImage.get(), let inputImage2 = inputImage2.get() else {
        return false
    }
    return drawComposite(
        parameters,
        resultImage,
        result.absoluteImageRect,
        inputImage,
        input.absoluteImageRect,
        inputImage2,
        input2.absoluteImageRect
    )
}

// feCompositeApplySoftware() with both inputs the same image, which can't be passed `inout` twice.
func feCompositeApplySoftwareWithSameInputs(
    _ parameters: borrowing WebCore.FECompositeParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }
    let inputImage = input.imageBuffer()
    let inputImage2 = input.imageBuffer()
    guard let inputImage = inputImage.get(), let inputImage2 = inputImage2.get() else {
        return false
    }
    let inputRect = input.absoluteImageRect
    return drawComposite(parameters, resultImage, result.absoluteImageRect, inputImage, inputRect, inputImage2, inputRect)
}

// The two draws, given the absolute image rects of the result and the inputs.
private func drawComposite(
    _ parameters: borrowing WebCore.FECompositeParameters,
    _ resultImage: WebCore.ImageBuffer,
    _ resultRect: WebCore.IntRect,
    _ inputImage: WebCore.ImageBuffer,
    _ inputRect: WebCore.IntRect,
    _ inputImage2: WebCore.ImageBuffer,
    _ inputRect2: WebCore.IntRect
) -> Bool {
    let resultLocation = resultRect.location()
    let inputImageRect = WebCore.FloatRect(inputRect - resultLocation)
    let inputImageRect2 = WebCore.FloatRect(inputRect2 - resultLocation)
    let drawing = WebCore.ImageBufferDrawing(resultImage)

    switch parameters.operation {
    case .FECOMPOSITE_OPERATOR_UNKNOWN:
        return false

    case .FECOMPOSITE_OPERATOR_OVER:
        let context = drawing.context()
        context.drawImageBuffer(inputImage2, inputImageRect2, .SourceOver)
        context.drawImageBuffer(inputImage, inputImageRect, .SourceOver)

    case .FECOMPOSITE_OPERATOR_IN:
        // Applies only to the intersected region.
        var destinationRect = inputRect
        destinationRect.intersect(inputRect2)
        destinationRect.intersect(resultRect)
        if destinationRect.isEmpty() {
            break
        }
        let adjustedDestinationRect = WebCore.FloatRect(destinationRect - resultLocation)
        let sourceRect = WebCore.FloatRect(destinationRect - inputRect.location())
        let source2Rect = WebCore.FloatRect(destinationRect - inputRect2.location())
        let context = drawing.context()
        context.drawImageBuffer(inputImage2, adjustedDestinationRect, source2Rect, .SourceOver, .Normal)
        context.drawImageBuffer(inputImage, adjustedDestinationRect, sourceRect, .SourceIn, .Normal)

    case .FECOMPOSITE_OPERATOR_OUT:
        let context = drawing.context()
        context.drawImageBuffer(inputImage, inputImageRect, .SourceOver)
        context.drawImageBuffer(inputImage2, inputImageRect2, .DestinationOut)

    case .FECOMPOSITE_OPERATOR_ATOP:
        let context = drawing.context()
        context.drawImageBuffer(inputImage2, inputImageRect2, .SourceOver)
        context.drawImageBuffer(inputImage, inputImageRect, .SourceAtop)

    case .FECOMPOSITE_OPERATOR_XOR:
        let context = drawing.context()
        context.drawImageBuffer(inputImage2, inputImageRect2, .SourceOver)
        context.drawImageBuffer(inputImage, inputImageRect, .XOR)

    case .FECOMPOSITE_OPERATOR_ARITHMETIC:
        assertionFailure()
        return false

    case .FECOMPOSITE_OPERATOR_LIGHTER:
        let context = drawing.context()
        context.drawImageBuffer(inputImage2, inputImageRect2, .SourceOver)
        context.drawImageBuffer(inputImage, inputImageRect, .PlusLighter)

    @unknown default:
        break
    }

    return true
}

#endif // ENABLE_WEBCORE_SWIFT
