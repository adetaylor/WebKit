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

#if ENABLE_WEBCORE_SWIFT
#if USE_CORE_IMAGE

import CoreGraphics
import CoreImage
import WebCore_Internal.FEDisplacementMapParameters
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatSize
import WebCore_Internal.IntRect

// The C++ applier's kernel string, byte for byte, including the comment that C++ needed at its start.
// FIXME: Why not a CIColorKernel?
private let displacementMapKernelSource =
    " /* NOLINT */\n" + #"""
        extern "C" {
        namespace coreimage {

        [[stitchable]] float4 displacement_map(sampler src, sampler map,
            float2 scale, float2 channelIndex, destination dest)
        {
            unsigned xChannelIndex = (unsigned)channelIndex.x;
            unsigned yChannelIndex = (unsigned)channelIndex.y;

            float2 sc = dest.coord();
            float2 mapCoord = map.transform(sc);
            float4 mapPixel = map.sample(mapCoord);
            // According to spec (https://drafts.csswg.org/filter-effects/#feDisplacementMapElement) we should unpremultiply mapPixel,
            // but that doesn't match implementations: https://github.com/w3c/fxtf-drafts/issues/113

            float2 offset = {
                scale.x * (mapPixel[xChannelIndex] - 0.5),
                scale.y * (mapPixel[yChannelIndex] - 0.5)
            };

            float2 positionInInputTexture = sc + offset;
            float2 srcPosition = src.transform(positionInInputTexture);

            return src.sample(srcPosition);
        }

        } // namespace coreimage
        } // extern "C"
        """# + "\n\n        "

// Compiled on first use; nil if that fails, which is not retried.
private let displacementMapKernel: CIKernel? = {
    guard let kernels = try? CIKernel.kernels(withMetalString: displacementMapKernelSource) else {
        return nil
    }
    return kernels.first
}()

func feDisplacementMapApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDisplacementMapParameters,
    _ input: borrowing FilterImageImpl,
    _ displacementInput: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    // §16.4: when in2 is tainted, act as a pass-through of in.
    if parameters.in2IsTainted {
        result.setCIImage(inputImage)
        return true
    }

    guard let mapImage = displacementInput.ciImage, let kernel = displacementMapKernel else {
        return false
    }

    let extent = context.coreImageRect(result.absoluteImageRect)
    let scale = context.scaledByFilterScale(context.resolvedSize(WebCore.FloatSize(parameters.scale, parameters.scale)))
    let channelXIndex = min(max(Int32(parameters.xChannelSelector.rawValue) - 1, 0), 3)
    let channelYIndex = min(max(Int32(parameters.yChannelSelector.rawValue) - 1, 0), 3)

    let arguments: [Any] = [
        inputImage,
        mapImage,
        // Flip the y scale because CI coordinates are flipped.
        CIVector(x: CGFloat(scale.width()), y: CGFloat(-scale.height())),
        CIVector(x: CGFloat(channelXIndex), y: CGFloat(channelYIndex)),
    ]
    let outputImage = kernel.apply(extent: extent, roiCallback: { _, destinationRect in destinationRect }, arguments: arguments)
    result.setCIImage(outputImage?.cropped(to: extent))
    return true
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
