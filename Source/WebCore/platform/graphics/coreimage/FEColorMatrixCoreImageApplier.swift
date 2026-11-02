// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

// The safe Span overload Swift synthesizes for valueSpan() calls Cxx's Span(_unsafeCxxSpan:). Xcode builds don't find it
// unless this file imports Cxx.
private import Cxx
import CoreImage
import CoreImage.CIFilterBuiltins
import WebCore_Private.Core.FEColorMatrixParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.IntRect

// FEColorMatrixCoreImageApplier::supportsCoreImageRendering().
@_expose(Cxx)
func feColorMatrixSupportsCoreImage(_ parameters: WebCore.FEColorMatrixParametersView) -> Bool {
    parameters.type() != .FECOLORMATRIX_TYPE_UNKNOWN
}

// FEColorMatrixCoreImageApplier::apply(): CIColorMatrix with the normalized values, clamped to [0, 1] and cropped to the
// result.
func feColorMatrixApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: WebCore.FEColorMatrixParametersView,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    let type = parameters.type()
    let values: Span<Float> = parameters.valueSpan()
    // Fails for a list with fewer values than the type reads, which the IPC decoder and the DOM reject.
    guard values.count >= feColorMatrixRequiredValueCount(type) else {
        return false
    }

    let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
    let vectors: (red: CIVector, green: CIVector, blue: CIVector, alpha: CIVector, bias: CIVector)
    switch type {
    case .FECOLORMATRIX_TYPE_SATURATE, .FECOLORMATRIX_TYPE_HUEROTATE:
        let amount = feColorMatrixNormalizedFloat(values[0])
        let c = type == .FECOLORMATRIX_TYPE_SATURATE ? feColorMatrixSaturateComponents(amount) : feColorMatrixHueRotateComponents(amount)
        vectors = (
            CIVector(x: CGFloat(c.0), y: CGFloat(c.1), z: CGFloat(c.2), w: 0),
            CIVector(x: CGFloat(c.3), y: CGFloat(c.4), z: CGFloat(c.5), w: 0),
            CIVector(x: CGFloat(c.6), y: CGFloat(c.7), z: CGFloat(c.8), w: 0),
            CIVector(x: 0, y: 0, z: 0, w: 1),
            zero
        )

    case .FECOLORMATRIX_TYPE_MATRIX:
        func value(_ index: Int) -> CGFloat {
            normalizedValue(values, index)
        }
        vectors = (
            CIVector(x: value(0), y: value(1), z: value(2), w: value(3)),
            CIVector(x: value(5), y: value(6), z: value(7), w: value(8)),
            CIVector(x: value(10), y: value(11), z: value(12), w: value(13)),
            CIVector(x: value(15), y: value(16), z: value(17), w: value(18)),
            CIVector(x: value(4), y: value(9), z: value(14), w: value(19))
        )

    case .FECOLORMATRIX_TYPE_LUMINANCETOALPHA:
        // ColorMatrix.h's luminanceToAlphaColorMatrix(), whose floats C++ passed as CGFloats.
        let red: Float = 0.2126
        let green: Float = 0.7152
        let blue: Float = 0.0722
        vectors = (zero, zero, zero, CIVector(x: CGFloat(red), y: CGFloat(green), z: CGFloat(blue), w: 0), zero)

    case .FECOLORMATRIX_TYPE_UNKNOWN:
        assertionFailure()
        return false

    @unknown default:
        return false
    }

    let colorMatrix = CIFilter.colorMatrix()
    colorMatrix.inputImage = inputImage
    colorMatrix.rVector = vectors.red
    colorMatrix.gVector = vectors.green
    colorMatrix.bVector = vectors.blue
    colorMatrix.aVector = vectors.alpha
    colorMatrix.biasVector = vectors.bias

    let clamp = CIFilter.colorClamp()
    clamp.inputImage = colorMatrix.outputImage
    clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

    result.setCIImage(clamp.outputImage?.cropped(to: context.coreImageRect(result.absoluteImageRect)))
    return true
}

// A value of FEColorMatrix::normalizedFloats(), as C++ passed it to CIVector.
private func normalizedValue(_ values: Span<Float>, _ index: Int) -> CGFloat {
    CGFloat(feColorMatrixNormalizedFloat(values[index]))
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
