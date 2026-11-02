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
import WebCore_Private.Core.FEGaussianBlurParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatSize

// FEGaussianBlurCoreImageApplier::apply(). Edge modes aren't supported.
func feGaussianBlurApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEGaussianBlurParameters,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    let stdDeviation = feGaussianBlurEffectiveStdDeviation(parameters, context.fastAndLowQuality)
    let absoluteStdDeviation = context.scaledByFilterScale(stdDeviation)

    // CIGaussianBlurXY is private: it has no typed builtin. The C++ messaged a nil filter without effect.
    let filter = CIFilter(name: "CIGaussianBlurXY")
    filter?.setValue(inputImage, forKey: kCIInputImageKey)
    filter?.setValue(absoluteStdDeviation.width(), forKey: "inputSigmaX")
    filter?.setValue(absoluteStdDeviation.height(), forKey: "inputSigmaY")

    result.setCIImage(filter?.outputImage?.cropped(to: context.coreImageRect(result.absoluteImageRect)))
    return true
}

#endif // ENABLE_WEBCORE_SWIFT && USE_CORE_IMAGE
