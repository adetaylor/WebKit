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

// The safe Span overload Swift synthesizes for ComponentTransferFunctionView.tableValuesSpan() calls Cxx's
// Span(_unsafeCxxSpan:). Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import IOSurface
import WebCore_Private.Core.FEComponentTransferParameters
import WebCore_Private.Core.FilterCoreImageSwiftBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.SourceGraphicParameters

// FEComponentTransferCoreImageApplier::apply().
func feComponentTransferApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: WebCore.FEComponentTransferParametersView,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    let redType = parameters.red().type()
    let greenType = parameters.green().type()
    let blueType = parameters.blue().type()
    let alphaType = parameters.alpha().type()
    let linear = WebCore.ComponentTransferType.FECOMPONENTTRANSFER_TYPE_LINEAR
    let resultImage: CIImage?
    if redType == linear && greenType == linear && blueType == linear && alphaType == linear {
        resultImage = applyLinearComponentTransfer(parameters, inputImage)
    } else if componentTransferTableByteCount(parameters) > componentTransferKernelTableByteCount {
        return applyComponentTransferInSoftware(context, parameters, &input, &result)
    } else {
        resultImage = applyComponentTransferKernel(parameters, inputImage)
    }
    guard let resultImage else {
        return false
    }

    result.setCIImage(resultImage.cropped(to: context.coreImageRect(result.absoluteImageRect)))
    return true
}

// The kernel gets the tables of the four functions in one data argument. It is always 4 KB long, so that it has the same
// layout for every apply. Longer tables are applied in software.
private let componentTransferKernelTableByteCount = 4096

private func componentTransferTableByteCount(_ parameters: WebCore.FEComponentTransferParametersView) -> Int {
    tableByteCount(parameters.red()) + tableByteCount(parameters.green()) + tableByteCount(parameters.blue())
        + tableByteCount(parameters.alpha())
}

// The bytes appendTransferFunction() adds to the table argument for `function`.
private func tableByteCount(_ function: WebCore.ComponentTransferFunctionView) -> Int {
    switch function.type() {
    case .FECOMPONENTTRANSFER_TYPE_TABLE, .FECOMPONENTTRANSFER_TYPE_DISCRETE:
        let tableValues: Span<Float> = function.tableValuesSpan()
        return tableValues.count * MemoryLayout<Float>.size
    default:
        return 0
    }
}

// Tables too long for the kernel: renders the input, applies the functions to its pixels as the software path does,
// and gives Core Image the result's image buffer, at the result's place in the absolute enclosing filter region.
private func applyComponentTransferInSoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: WebCore.FEComponentTransferParametersView,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let inputImageBuffer = renderedFilterResultImageBuffer(
        &input,
        absoluteFilterRegion: context.absoluteEnclosingFilterRegion,
        showDebugOverlay: false
    )
    guard inputImageBuffer.get() != nil, feComponentTransferApplySoftware(parameters, &input, &result) else {
        return false
    }

    let resultImageBuffer = result.imageBuffer()
    guard let imageBuffer = resultImageBuffer.get() else {
        return false
    }
    var image: CIImage?
    if let surface = WebCore.FilterCoreImageSwiftBridge.ioSurface(imageBuffer) {
        let colorSpace = WebCore.FilterCoreImageSwiftBridge.platformColorSpace(result.colorSpace)
        image = CIImage(ioSurface: surface, options: [.colorSpace: colorSpace as Any])
    } else {
        image = WebCore.SourceGraphicBridge.copyPlatformImage(imageBuffer).map { CIImage(cgImage: $0) }
    }
    guard var image else {
        return false
    }

    let offset = context.flippedRectRelativeToAbsoluteEnclosingFilterRegion(result.absoluteImageRect).location()
    if !offset.isZero() {
        image = image.transformed(by: CGAffineTransform(translationX: CGFloat(offset.x()), y: CGFloat(offset.y())))
    }
    result.setCIImage(image)
    return true
}

// FEComponentTransferCoreImageApplier::applyLinear(): every channel is linear.
private func applyLinearComponentTransfer(
    _ parameters: WebCore.FEComponentTransferParametersView,
    _ inputImage: CIImage
) -> CIImage? {
    let filter = CIFilter.colorPolynomial()
    filter.inputImage = inputImage
    filter.redCoefficients = linearCoefficients(parameters.red())
    filter.greenCoefficients = linearCoefficients(parameters.green())
    filter.blueCoefficients = linearCoefficients(parameters.blue())
    filter.alphaCoefficients = linearCoefficients(parameters.alpha())
    return filter.outputImage
}

private func linearCoefficients(_ function: WebCore.ComponentTransferFunctionView) -> CIVector {
    CIVector(x: CGFloat(function.intercept()), y: CGFloat(function.slope()), z: 0, w: 0)
}

// FEComponentTransferCoreImageApplier::applyOther(): the kernel below, with the four functions in its constants and their
// tables one after the other in its table buffer.
private func applyComponentTransferKernel(
    _ parameters: WebCore.FEComponentTransferParametersView,
    _ inputImage: CIImage
) -> CIImage? {
    guard let kernel = componentTransferKernel else {
        return nil
    }

    var constants = ComponentTransferKernelWriter()
    var tables = ComponentTransferKernelWriter()
    appendTransferFunction(parameters.red(), constants: &constants, tables: &tables)
    appendTransferFunction(parameters.green(), constants: &constants, tables: &tables)
    appendTransferFunction(parameters.blue(), constants: &constants, tables: &tables)
    appendTransferFunction(parameters.alpha(), constants: &constants, tables: &tables)

    tables.padWithZeros(toCount: componentTransferKernelTableByteCount)
    let arguments: [Any] = [inputImage, constants.data, tables.data]
    let roiCallback: CIKernelROICallback = { _, destinationRect in destinationRect }
    return kernel.apply(extent: inputImage.extent, roiCallback: roiCallback, arguments: arguments)
}

// The kernel's TransferType.
private enum ComponentTransferKernelType: UInt32 {
    case identity = 0
    case table = 1
    case discrete = 2
    case linear = 3
    case gamma = 4
}

// Appends the kernel's TransferFunction { TransferType functionType; unsigned tableLength; unsigned tableStart; float
// params[3]; } for `function` to `constants`, and its table, if it has one, to `tables`. An empty table is the identity, as
// in software: the kernel never indexes a table of no entries.
private func appendTransferFunction(
    _ function: WebCore.ComponentTransferFunctionView,
    constants: inout ComponentTransferKernelWriter,
    tables: inout ComponentTransferKernelWriter
) {
    var type = ComponentTransferKernelType.identity
    var tableLength: UInt32 = 0
    var tableStart: UInt32 = 0
    var parameters: (Float, Float, Float) = (0, 0, 0)

    switch function.type() {
    case .FECOMPONENTTRANSFER_TYPE_UNKNOWN, .FECOMPONENTTRANSFER_TYPE_IDENTITY:
        break
    case .FECOMPONENTTRANSFER_TYPE_LINEAR:
        type = .linear
        parameters = (function.slope(), function.intercept(), 0)
    case .FECOMPONENTTRANSFER_TYPE_GAMMA:
        type = .gamma
        parameters = (function.amplitude(), function.exponent(), function.offset())
    case .FECOMPONENTTRANSFER_TYPE_TABLE, .FECOMPONENTTRANSFER_TYPE_DISCRETE:
        let tableValues: Span<Float> = function.tableValuesSpan()
        if tableValues.isEmpty {
            break
        }
        type = function.type() == .FECOMPONENTTRANSFER_TYPE_TABLE ? .table : .discrete
        // Sizes in C++ unsigned, as the kernel reads them.
        tableLength = UInt32(truncatingIfNeeded: tableValues.count)
        tableStart = UInt32(truncatingIfNeeded: tables.count / 4)
        for index in tableValues.indices {
            tables.append(tableValues[index])
        }
    @unknown default:
        break
    }

    constants.append(type.rawValue)
    constants.append(tableLength)
    constants.append(tableStart)
    constants.append(parameters.0)
    constants.append(parameters.1)
    constants.append(parameters.2)
}

// Little-endian bytes of a kernel argument, laid out as the C++ structs were.
private struct ComponentTransferKernelWriter {
    private var bytes: [UInt8] = []

    var count: Int {
        bytes.count
    }

    var data: Data {
        Data(bytes)
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func padWithZeros(toCount count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: max(0, count - bytes.count)))
    }

    mutating func append(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}

// The kernel source is the C++ applier's string, byte for byte, including the comment C++ needed at its start and the
// indentation of its end.
private let componentTransferKernelSource = " /* NOLINT */\n" + componentTransferKernelBody + "        "

private let componentTransferKernelBody = #"""
    extern "C" {
    namespace coreimage {

    enum class TransferType : uint32_t {
        Identity,
        Table,
        Discrete,
        Linear,
        Gamma,
    };

    enum ParamIndex {
        LinearSlope = 0,
        LinearIntercept = 1,
        GammaAmplitude = 0,
        GammaExponent = 1,
        GammaOffset = 2,
    };

    struct TransferFunction {
        TransferType functionType;
        unsigned tableLength; // For table and discrete, number of entries in table.
        unsigned tableStart; // For table and discrete, start of table in the table buffer.

        float params[3];
    };

    struct ComponentTransferConstants {
        TransferFunction data[4];
    };

    float applyTransferFunction(float component, constant TransferFunction& function, constant float* tables)
    {
        switch (function.functionType) {
        case TransferType::Identity:
            return component;

        case TransferType::Table: {
            constant float* tableStart = tables + function.tableStart;
            int tableLength = function.tableLength;
            int n = tableLength - 1;

            int k = clamp((int)(component * n), 0, n);
            float v1 = tableStart[k];
            float v2 = tableStart[min(k + 1, n)];
            return v1 + ((component * n) - k) * (v2 - v1);
        }
        case TransferType::Discrete: {
            constant float* tableStart = tables + function.tableStart;
            int n = function.tableLength;
            int k = clamp((int)(component * n), 0, n - 1);
            return tableStart[k];
        }
        case TransferType::Linear:
            return component * function.params[ParamIndex::LinearSlope] + function.params[ParamIndex::LinearIntercept];

        case TransferType::Gamma:
            return function.params[ParamIndex::GammaAmplitude] * pow(component, function.params[ParamIndex::GammaExponent]) + function.params[ParamIndex::GammaOffset];
        }

        return component;
    }

    [[stitchable]] float4 componentTransfer(sampler src,
        constant ComponentTransferConstants* constants,
        constant float* tables,
        destination dest)
    {
        float2 samplePosition = src.transform(dest.coord());
        float4 srcPixel = unpremultiply(src.sample(samplePosition));

        float4 resultPixel = { };

        resultPixel.r = applyTransferFunction(srcPixel.r, constants->data[0], tables);
        resultPixel.g = applyTransferFunction(srcPixel.g, constants->data[1], tables);
        resultPixel.b = applyTransferFunction(srcPixel.b, constants->data[2], tables);
        resultPixel.a = applyTransferFunction(srcPixel.a, constants->data[3], tables);

        return premultiply(clamp(resultPixel, 0, 1));
    }

    } // namespace coreimage {
    } // extern "C"


    """#

// Compiled on first use; nil if that fails.
private let componentTransferKernel: CIKernel? = {
    guard let kernels = try? CIKernel.kernels(withMetalString: componentTransferKernelSource) else {
        return nil
    }
    return kernels.first
}()

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
