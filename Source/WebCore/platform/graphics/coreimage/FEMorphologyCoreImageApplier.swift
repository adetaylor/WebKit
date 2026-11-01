// Copyright (C) 2025-2026 Apple Inc. All rights reserved.
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
#if USE_CORE_IMAGE

import CoreImage
import WebCore_Internal.FEMorphologyParameters
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatSize

func feMorphologyApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEMorphologyParameters,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    let radius = context.resolvedSize(WebCore.FloatSize(parameters.radiusX, parameters.radiusY))
    let scaledRadius = context.scaledByFilterScale(radius)
    let radiusX = scaledRadius.width()
    let radiusY = scaledRadius.height()
    if radiusX <= 0 && radiusY <= 0 {
        result.setCIImage(inputImage)
        return true
    }

    // Core Image expects kernel size (width/height), not radius: kernel size = 2 * radius + 1. The C++ converted it to
    // int and set it as an int NSNumber.
    let kernelWidth = Int32(arm64Truncating: 2 * radiusX + 1)
    let kernelHeight = Int32(arm64Truncating: 2 * radiusY + 1)

    let filterName = parameters.type == .Erode ? "CIMorphologyRectangleMinimum" : "CIMorphologyRectangleMaximum"
    guard let filter = CIFilter(name: filterName) else {
        return false
    }
    filter.setValue(inputImage, forKey: kCIInputImageKey)
    filter.setValue(kernelWidth, forKey: "inputWidth")
    filter.setValue(kernelHeight, forKey: "inputHeight")
    result.setCIImage(filter.outputImage)
    return true
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
