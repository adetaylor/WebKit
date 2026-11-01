// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) 2010 Zoltan Herczeg <zherczeg@webkit.org>
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

// The safe Span overloads Swift synthesizes for FEConvolveMatrixParametersView.kernelValues() and PixelBufferAccess call
// Cxx's Span(_unsafeCxxSpan:). Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Internal.AlphaPremultiplication
import WebCore_Internal.ColorSpace
import WebCore_Internal.FEConvolveMatrixParameters
import WebCore_Internal.FilterGraphicsBridge
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatRect
import WebCore_Internal.IntPoint
import WebCore_Internal.IntRect
import WebCore_Internal.IntSize
import WebCore_Internal.PixelBuffer
import WebCore_Internal.PixelBufferSwiftBridge

// FEConvolveMatrixSoftwareApplier::apply().
//
// The image is split in the following way:
//
//    +---------------------+
//    |          A          |
//    +---------------------+
//    |   |             |   |
//    | B |      C      | D |
//    |   |             |   |
//    +---------------------+
//    |          E          |
//    +---------------------+
//
// where the kernel of every pixel of region C lies inside the image, so the edge mode doesn't affect C. Each row is
// computed on its own: the rows of B, C and D, or of A and E, which take the edge mode into account. When the kernel is
// larger than the image, every pixel is in A.
func feConvolveMatrixApplySoftware(
    _ parameters: WebCore.FEConvolveMatrixParametersView,
    _ operatingColorSpace: borrowing WebCore.ColorSpace,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let alphaFormat: WebCore.AlphaPremultiplication = parameters.preserveAlpha() ? .Unpremultiplied : .Premultiplied
    guard let destination = result.pixelBuffer(alphaFormat).get() else {
        return false
    }

    let effectDrawingRect = result.absoluteImageRect(relativeTo: input)
    guard let source = input.getPixelBuffer(alphaFormat, sourceRect: effectDrawingRect, colorSpace: operatingColorSpace).get() else {
        return false
    }

    let paintSize = result.absoluteImageRect.size()
    guard let geometry = ConvolveMatrixGeometry(parameters, width: Int(paintSize.width()), height: Int(paintSize.height())) else {
        return false
    }
    if geometry.width <= 0 || geometry.height <= 0 {
        return true
    }

    // FEColorMatrix::normalizedFloats() of the kernel, in the order the taps visit it: the kernel is applied rotated by
    // 180 degrees.
    let kernelValues: Span<Float> = parameters.kernelValues()
    var taps = ContiguousArray<Float>(repeating: 0, count: kernelValues.count)
    for index in kernelValues.indices {
        taps[index] = normalizedFloat(kernelValues[kernelValues.count - 1 - index])
    }

    let sourceAccess = WebCore.PixelBufferAccess(source)
    let sourceBytes: Span<UInt8> = sourceAccess.span()
    var destinationAccess = WebCore.PixelBufferAccess(destination)
    var destinationBytes: MutableSpan<UInt8> = destinationAccess.mutableSpan()
    precondition(sourceBytes.count >= geometry.byteCount && destinationBytes.count >= geometry.byteCount)

    let tapValues = taps.span
    let rowBytes = geometry.rowBytes
    let height = geometry.height
    let completed = parallelRows(height: height, jobs: geometry.jobCount, rowBytes: rowBytes, into: &destinationBytes) { rows, output in
        let sourcePixels = sourceBytes.bytes
        var outputPixels = output.mutableBytes
        for y in rows {
            convolveRow(y, geometry, sourcePixels, tapValues, into: &outputPixels, at: (y - rows.lowerBound) * rowBytes)
        }
    }
    precondition(completed)
    return true
}

private enum ConvolveMatrixEdgeMode {
    case duplicate
    case wrap
    // EdgeModeType::None and EdgeModeType::Unknown: pixels outside the image don't contribute.
    case none
}

private struct ConvolveMatrixGeometry {
    let width: Int
    let height: Int
    let rowBytes: Int
    let byteCount: Int
    let kernelWidth: Int
    let kernelHeight: Int
    let targetX: Int
    let targetY: Int
    let divisor: Float
    let bias: Float
    let preserveAlpha: Bool
    let edgeMode: ConvolveMatrixEdgeMode
    // Region C: the pixels whose kernel lies inside the image. Empty when the kernel is larger than the image.
    let interiorRows: Range<Int>
    let interiorColumns: Range<Int>
    let jobCount: Int

    // Nil for a kernel that FEConvolveMatrix's IPC and DOM validation would have rejected.
    init?(_ parameters: WebCore.FEConvolveMatrixParametersView, width: Int, height: Int) {
        let kernelSize = parameters.kernelSize()
        let targetOffset = parameters.targetOffset()
        kernelWidth = Int(kernelSize.width())
        kernelHeight = Int(kernelSize.height())
        targetX = Int(targetOffset.x())
        targetY = Int(targetOffset.y())
        let kernelValues: Span<Float> = parameters.kernelValues()
        guard kernelWidth > 0, kernelHeight > 0, (0..<kernelWidth).contains(targetX), (0..<kernelHeight).contains(targetY),
            kernelWidth.checkedMultiplied(by: kernelHeight) == kernelValues.count
        else {
            return nil
        }

        // A negative size paints nothing, as in C++.
        self.width = max(width, 0)
        self.height = max(height, 0)
        rowBytes = self.width * 4
        byteCount = rowBytes.checkedMultiplied(by: self.height) ?? .max
        divisor = parameters.divisor()
        bias = parameters.bias() * 255
        preserveAlpha = parameters.preserveAlpha()
        switch parameters.edgeMode() {
        case .Duplicate:
            edgeMode = .duplicate
        case .Wrap:
            edgeMode = .wrap
        default:
            edgeMode = .none
        }

        let clipRight = self.width - kernelWidth
        let clipBottom = self.height - kernelHeight
        if clipRight < 0 || clipBottom < 0 {
            interiorRows = 0..<0
            interiorColumns = 0..<0
            jobCount = 1
            return
        }
        interiorRows = targetY..<targetY + clipBottom + 1
        interiorColumns = targetX..<targetX + clipRight + 1

        // The C++ applier's split of region C into chunks of rows for ConcurrentWorkQueue::apply(). It computed the
        // other regions serially afterwards; here the jobs compute whole rows of every region.
        let minimalRectDimension = 100 * 100
        let iterations = self.width * self.height / minimalRectDimension
        let stride = iterations > 0 ? clipBottom / iterations : 0
        jobCount = stride > 0 ? (clipBottom + stride - 1) / stride : 1
    }
}

// WTF::normalizedFloat(): denormals become the smallest normal float of the same sign.
@inline(__always)
private func normalizedFloat(_ value: Float) -> Float {
    if value > 0 && value < Float.leastNormalMagnitude {
        return Float.leastNormalMagnitude
    }
    if value < 0 && value > -Float.leastNormalMagnitude {
        return -Float.leastNormalMagnitude
    }
    return value
}

// A NaN channel becomes 0, as arm64 converts it.
@inline(__always)
private func clampRGBAValue(_ channel: Float, _ max: UInt8 = 255) -> UInt8 {
    if channel <= 0 {
        return 0
    }
    if channel >= Float(max) {
        return max
    }
    return UInt8(truncatingIfNeeded: Int32(arm64Truncating: channel))
}

@inline(__always)
private func convolveRow(
    _ y: Int,
    _ geometry: ConvolveMatrixGeometry,
    _ source: RawSpan,
    _ taps: Span<Float>,
    into output: inout MutableRawSpan,
    at rowOffset: Int
) {
    guard geometry.interiorRows.contains(y) else {
        for x in 0..<geometry.width {
            outerPixel(x, y, geometry, source, taps, into: &output, at: rowOffset + x * 4)
        }
        return
    }
    for x in 0..<geometry.interiorColumns.lowerBound {
        outerPixel(x, y, geometry, source, taps, into: &output, at: rowOffset + x * 4)
    }
    for x in geometry.interiorColumns {
        interiorPixel(x, y, geometry, source, taps, into: &output, at: rowOffset + x * 4)
    }
    for x in geometry.interiorColumns.upperBound..<geometry.width {
        outerPixel(x, y, geometry, source, taps, into: &output, at: rowOffset + x * 4)
    }
}

// FEConvolveMatrixSoftwareApplier::setInteriorPixels() for one pixel of region C.
@inline(__always)
private func interiorPixel(
    _ x: Int,
    _ y: Int,
    _ geometry: ConvolveMatrixGeometry,
    _ source: RawSpan,
    _ taps: Span<Float>,
    into output: inout MutableRawSpan,
    at offset: Int
) {
    var totals = SIMD4<Float>()
    var tap = 0
    var rowStart = ((y - geometry.targetY) * geometry.width + x - geometry.targetX) * 4
    for _ in 0..<geometry.kernelHeight {
        var pixel = rowStart
        for _ in 0..<geometry.kernelWidth {
            totals += taps[tap] * SIMD4<Float>(source.load(fromByteOffset: pixel, as: SIMD4<UInt8>.self))
            tap += 1
            pixel += 4
        }
        rowStart += geometry.rowBytes
    }
    storePixel(totals, x, y, geometry, source, into: &output, at: offset)
}

// FEConvolveMatrixSoftwareApplier::setOuterPixels() for one pixel of regions A, B, D and E.
@inline(__always)
private func outerPixel(
    _ x: Int,
    _ y: Int,
    _ geometry: ConvolveMatrixGeometry,
    _ source: RawSpan,
    _ taps: Span<Float>,
    into output: inout MutableRawSpan,
    at offset: Int
) {
    var totals = SIMD4<Float>()
    var tap = 0
    for kernelY in y - geometry.targetY..<y - geometry.targetY + geometry.kernelHeight {
        for kernelX in x - geometry.targetX..<x - geometry.targetX + geometry.kernelWidth {
            if let pixel = pixelOffset(kernelX, kernelY, geometry) {
                totals += taps[tap] * SIMD4<Float>(source.load(fromByteOffset: pixel, as: SIMD4<UInt8>.self))
            }
            tap += 1
        }
    }
    storePixel(totals, x, y, geometry, source, into: &output, at: offset)
}

// FEConvolveMatrixSoftwareApplier::getPixelValue(): the byte offset of the source pixel a tap at (x, y) reads, or nil.
@inline(__always)
private func pixelOffset(_ x: Int, _ y: Int, _ geometry: ConvolveMatrixGeometry) -> Int? {
    let width = geometry.width
    let height = geometry.height
    if x >= 0 && x < width && y >= 0 && y < height {
        return (y * width + x) * 4
    }
    switch geometry.edgeMode {
    case .none:
        return nil
    case .duplicate:
        return (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
    case .wrap:
        let wrappedX = x >= 0 ? x % width : (x % width + width) % width
        let wrappedY = y >= 0 ? y % height : (y % height + height) % height
        return (wrappedY * width + wrappedX) * 4
    }
}

// FEConvolveMatrixSoftwareApplier::setDestinationPixels().
@inline(__always)
private func storePixel(
    _ totals: SIMD4<Float>,
    _ x: Int,
    _ y: Int,
    _ geometry: ConvolveMatrixGeometry,
    _ source: RawSpan,
    into output: inout MutableRawSpan,
    at offset: Int
) {
    let channels = totals / geometry.divisor + geometry.bias
    let maxAlpha = geometry.preserveAlpha ? 255 : clampRGBAValue(channels[3])
    let alpha = geometry.preserveAlpha ? source.load(fromByteOffset: (y * geometry.width + x) * 4 + 3, as: UInt8.self) : maxAlpha
    let pixel = SIMD4<UInt8>(
        clampRGBAValue(channels[0], maxAlpha),
        clampRGBAValue(channels[1], maxAlpha),
        clampRGBAValue(channels[2], maxAlpha),
        alpha
    )
    output.storeBytes(of: pixel, toByteOffset: offset, as: SIMD4<UInt8>.self)
}

#endif // ENABLE_WEBCORE_SWIFT
