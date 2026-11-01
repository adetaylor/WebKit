// Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && USE_CORE_IMAGE

import CoreImage
import CoreImage.CIFilterBuiltins
import WebCore_Internal.FEDropShadowParameters
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatSize

// FEDropShadowCoreImageApplier::apply(): the input's alpha, blurred, moved by the offset and filled with the shadow
// color, under the input. C++ resolves the shadow color (with the shadow opacity) in the operating color space.
func feDropShadowApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDropShadowParameters,
    _ shadowColor: WebCore.FilterColorComponents,
    _ operatingColorSpaceIsSRGB: Bool,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    let stdDeviation = context.resolvedSize(WebCore.FloatSize(parameters.stdDeviationX, parameters.stdDeviationY))
    let blurRadius = context.scaledByFilterScale(stdDeviation)

    let offset = context.resolvedSize(WebCore.FloatSize(parameters.dx, parameters.dy))
    let absoluteOffset = context.scaledByFilterScale(offset)

    let colorSpace = CGColorSpace(name: operatingColorSpaceIsSRGB ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)
    let shadowCIColor = colorSpace.flatMap {
        CIColor(
            red: CGFloat(shadowColor.red),
            green: CGFloat(shadowColor.green),
            blue: CGFloat(shadowColor.blue),
            alpha: CGFloat(shadowColor.alpha),
            colorSpace: $0
        )
    }

    // Extract alpha.
    let alphaFilter = CIFilter(name: "CIColorMatrix")
    alphaFilter?.setValue(inputImage, forKey: kCIInputImageKey)
    alphaFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
    alphaFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
    alphaFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
    alphaFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
    alphaFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

    // CIGaussianBlurXY is private: it has no typed builtin. The C++ messaged nil filters and images without effect.
    let blurFilter = CIFilter(name: "CIGaussianBlurXY")
    blurFilter?.setValue(alphaFilter?.outputImage, forKey: kCIInputImageKey)
    blurFilter?.setValue(blurRadius.width(), forKey: "inputSigmaX")
    blurFilter?.setValue(blurRadius.height(), forKey: "inputSigmaY")

    let translation = CGAffineTransform(translationX: CGFloat(absoluteOffset.width()), y: CGFloat(-absoluteOffset.height()))
    let shadowImage = blurFilter?.outputImage?.transformed(by: translation)

    let compositeFilter = CIFilter.sourceInCompositing()
    compositeFilter.inputImage = shadowCIColor.map { CIImage(color: $0) }
    compositeFilter.backgroundImage = shadowImage

    let shadowedImage = compositeFilter.outputImage.map { inputImage.composited(over: $0) }
    result.setCIImage(shadowedImage?.cropped(to: context.coreImageRect(result.absoluteImageRect)))
    return true
}

#endif // ENABLE_WEBCORE_SWIFT && USE_CORE_IMAGE
