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
import CoreImage.CIFilterBuiltins
import WebCore_Private.Core.FEBlendParameters
import WebCore_Private.Core.GraphicsTypes

// FEBlendCoreImageApplier::apply(): the first input blended over the second one.
func feBlendApplyCoreImage(
    _ parameters: borrowing WebCore.FEBlendParameters,
    _ input: borrowing FilterImageImpl,
    _ input2: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }
    guard let inputImage2 = input2.ciImage else {
        return false
    }

    let filter: (any CIFilter & CICompositeOperation)?
    switch parameters.mode {
    case .Normal:
        filter = CIFilter.sourceOverCompositing()
    case .Multiply:
        filter = CIFilter.multiplyBlendMode()
    case .Screen:
        filter = CIFilter.screenBlendMode()
    case .Darken:
        filter = CIFilter.darkenBlendMode()
    case .Lighten:
        filter = CIFilter.lightenBlendMode()
    case .Overlay:
        filter = CIFilter.overlayBlendMode()
    case .ColorDodge:
        filter = CIFilter.colorDodgeBlendMode()
    case .ColorBurn:
        filter = CIFilter.colorBurnBlendMode()
    case .HardLight:
        filter = CIFilter.hardLightBlendMode()
    case .SoftLight:
        filter = CIFilter.softLightBlendMode()
    case .Difference:
        filter = CIFilter.differenceBlendMode()
    case .Exclusion:
        filter = CIFilter.exclusionBlendMode()
    case .Hue:
        filter = CIFilter.hueBlendMode()
    case .Saturation:
        filter = CIFilter.saturationBlendMode()
    case .Color:
        filter = CIFilter.colorBlendMode()
    case .Luminosity:
        filter = CIFilter.luminosityBlendMode()
    case .PlusDarker, .PlusLighter:
        // These are not supported by SVG. The C++ messaged the nil filter without effect.
        assertionFailure()
        filter = nil
    @unknown default:
        filter = nil
    }

    filter?.inputImage = inputImage
    filter?.backgroundImage = inputImage2
    result.setCIImage(filter?.outputImage)
    return true
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
