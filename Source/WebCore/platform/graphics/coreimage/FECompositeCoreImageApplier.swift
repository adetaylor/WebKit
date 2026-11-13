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

import CoreGraphics
import CoreImage
import WebCore_Private.Core.FECompositeParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.IntRect

// The C++ applier's kernel string, byte for byte, including the comment that C++ needed at its start.
// FIXME: Why not a CIColorKernel?
private let compositeArithmeticKernelSource =
    " /* NOLINT */\n" + #"""
        extern "C" {
        namespace coreimage {

        [[stitchable]] float4 composite_arithmetic(sampler front, sampler back,
            vector_float4 constants,
            destination dest)
        {
            float2 destPosition = dest.coord();

            float2 frontPosition = front.transform(destPosition);
            float4 frontPixel = front.sample(frontPosition);

            float2 backPosition = back.transform(destPosition);
            float4 backPixel = back.sample(backPosition);

            float4 resultPixel = clamp(constants.x * frontPixel * backPixel + constants.y * frontPixel + constants.z * backPixel + constants.w, 0, 1);
            resultPixel = clamp(resultPixel, 0, resultPixel.a);
            return resultPixel;
        }

        } // namespace coreimage
        } // extern "C"
        """# + "\n\n        "

// Compiled on first use; nil if that fails, which is not retried.
private let compositeArithmeticKernel: CIKernel? = {
    guard let kernels = try? CIKernel.kernels(withMetalString: compositeArithmeticKernelSource) else {
        return nil
    }
    return kernels.first
}()

// FECompositeCoreImageApplier::apply().
func feCompositeApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FECompositeParameters,
    _ input: borrowing FilterImageImpl,
    _ input2: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage1 = input.ciImage, let inputImage2 = input2.ciImage else {
        return false
    }

    let extent = context.coreImageRect(result.absoluteImageRect)

    let resultImage: CIImage?
    if parameters.operation == .FECOMPOSITE_OPERATOR_ARITHMETIC {
        resultImage = coreImageCompositeArithmetic(inputImage1, inputImage2, extent, parameters)
    } else {
        resultImage = coreImageCompositeBuiltIn(inputImage1, inputImage2, parameters)
    }

    guard let resultImage = resultImage?.cropped(to: extent) else {
        return false
    }

    result.setCIImage(resultImage)
    return true
}

private func coreImageCompositeBuiltIn(
    _ frontImage: CIImage,
    _ backImage: CIImage,
    _ parameters: borrowing WebCore.FECompositeParameters
) -> CIImage? {
    let kernel: CIBlendKernel
    switch parameters.operation {
    case .FECOMPOSITE_OPERATOR_UNKNOWN:
        return nil
    case .FECOMPOSITE_OPERATOR_OVER:
        kernel = .sourceOver
    case .FECOMPOSITE_OPERATOR_IN:
        kernel = .sourceIn
    case .FECOMPOSITE_OPERATOR_OUT:
        kernel = .sourceOut
    case .FECOMPOSITE_OPERATOR_ATOP:
        kernel = .sourceAtop
    case .FECOMPOSITE_OPERATOR_XOR:
        kernel = .exclusiveOr
    case .FECOMPOSITE_OPERATOR_ARITHMETIC:
        assertionFailure()
        return nil
    case .FECOMPOSITE_OPERATOR_LIGHTER:
        kernel = .componentAdd
    @unknown default:
        return nil
    }

    return kernel.apply(foreground: frontImage, background: backImage)
}

private func coreImageCompositeArithmetic(
    _ frontImage: CIImage,
    _ backImage: CIImage,
    _ extent: CGRect,
    _ parameters: borrowing WebCore.FECompositeParameters
) -> CIImage? {
    guard let kernel = compositeArithmeticKernel else {
        return nil
    }

    let arguments: [Any] = [
        frontImage,
        backImage,
        CIVector(x: CGFloat(parameters.k1), y: CGFloat(parameters.k2), z: CGFloat(parameters.k3), w: CGFloat(parameters.k4)),
    ]
    return kernel.apply(extent: extent, roiCallback: { _, destinationRect in destinationRect }, arguments: arguments)
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
