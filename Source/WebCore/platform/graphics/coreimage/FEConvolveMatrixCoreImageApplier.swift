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

import CoreImage
import WebCore_Private.Core.FEConvolveMatrixParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.IntPoint
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize

// FEConvolveMatrixCoreImageApplier::supportsCoreImageRendering().
@_expose(Cxx)
func feConvolveMatrixSupportsCoreImage(_ parameters: WebCore.FEConvolveMatrixParametersView) -> Bool {
    parameters.edgeMode() == .None
}

// FEConvolveMatrixCoreImageApplier::apply().
func feConvolveMatrixApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: WebCore.FEConvolveMatrixParametersView,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard var inputImage = input.ciImage, let kernel = convolveMatrixKernel else {
        return false
    }

    let extent = context.coreImageRect(result.absoluteImageRect)

    let kernelSize = parameters.kernelSize()
    let targetOffset = parameters.targetOffset()
    let preserveAlpha = parameters.preserveAlpha()
    // ConvolveMatrixConstants of the kernel: int2 kernelSize, int2 target (y flipped), float divisor, float bias,
    // uint8_t edgeMode, bool preserveAlpha, padded to the 8-byte alignment of int2.
    var constants = ConvolveMatrixConstantWriter()
    constants.append(kernelSize.width())
    constants.append(kernelSize.height())
    constants.append(targetOffset.x())
    constants.append(kernelSize.height() &- targetOffset.y() &- 1)
    constants.append(parameters.divisor())
    constants.append(parameters.bias())
    constants.append(coreImageEdgeMode(parameters.edgeMode()))
    constants.append(UInt8(preserveAlpha ? 1 : 0))
    constants.padToMultiple(of: 8)

    var kernelValues = ConvolveMatrixConstantWriter()
    let values: Span<Float> = parameters.kernelValues()
    for index in values.indices {
        kernelValues.append(normalizedFloat(values[index]))
    }

    // https://drafts.csswg.org/filter-effects/#element-attrdef-feconvolvematrix-preservealpha
    if preserveAlpha {
        inputImage = inputImage.unpremultiplyingAlpha()
    }

    let arguments: [Any] = [inputImage, constants.data, kernelValues.data]
    let roiCallback: CIKernelROICallback = { _, destinationRect in destinationRect }
    guard let outputImage = kernel.apply(extent: extent, roiCallback: roiCallback, arguments: arguments) else {
        return false
    }

    result.setCIImage(outputImage.cropped(to: extent))
    return true
}

// The EdgeMode of the kernel.
private func coreImageEdgeMode(_ edgeMode: WebCore.EdgeModeType) -> UInt8 {
    switch edgeMode {
    case .Duplicate:
        return 0
    case .Wrap:
        return 1
    case .None:
        return 2
    case .Unknown:
        assertionFailure()
        return 2
    @unknown default:
        return 2
    }
}

// WTF::normalizedFloat(): denormals become the smallest normal float of the same sign.
private func normalizedFloat(_ value: Float) -> Float {
    if value > 0 && value < Float.leastNormalMagnitude {
        return Float.leastNormalMagnitude
    }
    if value < 0 && value > -Float.leastNormalMagnitude {
        return -Float.leastNormalMagnitude
    }
    return value
}

// Little-endian bytes of a kernel argument, laid out as the C++ struct was.
private struct ConvolveMatrixConstantWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data {
        Data(bytes)
    }

    mutating func append(_ value: Int32) {
        append(UInt32(bitPattern: value))
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func append(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func append(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func padToMultiple(of alignment: Int) {
        while !bytes.count.isMultiple(of: alignment) {
            bytes.append(0)
        }
    }
}

// The kernel source is the C++ applier's string, byte for byte, including the comment that C++ needed at its start and
// the indentation of its end.
private let convolveMatrixKernelSource = " /* NOLINT */\n" + convolveMatrixKernelBody + "        "

private let convolveMatrixKernelBody = #"""
    extern "C" {
    namespace coreimage {

    enum EdgeMode : uint8_t {
        EdgeModeDuplicate,
        EdgeModeWrap,
        EdgeModeNone,
    };

    struct ConvolveMatrixConstants {
        vector_int2 kernelSize;
        vector_int2 target;
        float divisor;
        float bias;
        EdgeMode edgeMode;
        bool preserveAlpha;
    };

    [[stitchable]] float4 convolve(sampler src,
        constant ConvolveMatrixConstants* constants,
        constant float* convolveKernel,
        destination dest)
    {
        float2 srcPosition = src.transform(dest.coord());
        float4 srcPixel = src.sample(srcPosition);

        int2 kernelSize = constants->kernelSize;
        int2 target = constants->target;

        float4 pixelSum = 0;

        // FIXME: Edge mode not supported yet.
        for (int row = 0; row < kernelSize.y; ++row) {
            for (int col = 0; col < kernelSize.x; ++col) {

                int flippedRow = kernelSize.y - row - 1;
                int flippedCol = kernelSize.x - col - 1;

                float2 sampleOffset = { (float)flippedCol - target.x, (float)flippedRow - target.y };
                float2 samplePosition = srcPosition + sampleOffset;

                float4 nearbyPixel = src.sample(samplePosition);
                nearbyPixel *= convolveKernel[kernelSize.x * flippedRow + col];
                pixelSum += nearbyPixel;
            }
        }

        float alpha = constants->preserveAlpha ? srcPixel.a : clamp(pixelSum.a / constants->divisor + constants->bias, 0.f, 1.f);
        float4 resultPixel = pixelSum / constants->divisor + constants->bias * alpha;

        resultPixel.a = alpha;

        if (constants->preserveAlpha)
            resultPixel = premultiply(clamp(resultPixel, 0, 1));
        else
            resultPixel = premultiply(clamp(resultPixel, 0, alpha));

        return resultPixel;
    }

    } // namespace coreimage
    } // extern "C"

    """#

// Compiled on first use; nil if that fails.
private let convolveMatrixKernel: CIKernel? = {
    guard let kernels = try? CIKernel.kernels(withMetalString: convolveMatrixKernelSource) else {
        return nil
    }
    return kernels.first
}()

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
