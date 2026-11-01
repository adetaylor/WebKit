// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) 2010 Igalia, S.L.
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2015-2026 Apple Inc. All rights reserved.
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
//
// Copyright (C) 2024 Igalia S.L.
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

// The safe Span overloads Swift synthesizes for PixelBufferAccess call Cxx's Span(_unsafeCxxSpan:). Xcode builds don't
// find it unless this file imports Cxx.
private import Cxx
import WebCore_Internal.AlphaPremultiplication
import WebCore_Internal.FEConvolveMatrixParameters
import WebCore_Internal.FEGaussianBlurParameters
import WebCore_Internal.FilterGraphicsBridge
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatRect
import WebCore_Internal.FloatSize
import WebCore_Internal.IntPoint
import WebCore_Internal.IntRect
import WebCore_Internal.IntSize
import WebCore_Internal.PixelBuffer
import WebCore_Internal.PixelBufferSwiftBridge
#if !USE_ACCELERATE
import wtf.Core.NumberOfCores
#endif
#if USE_SKIA
import WebCore_Internal.FilterSkiaBridge
#endif

// FEGaussianBlur::effectiveStdDeviation(): FastAndLowQuality caps the deviation at 20.
@_expose(Cxx)
func feGaussianBlurEffectiveStdDeviation(
    _ parameters: borrowing WebCore.FEGaussianBlurParameters,
    _ fastAndLowQuality: Bool
) -> WebCore.FloatSize {
    if fastAndLowQuality {
        return WebCore.FloatSize(min(parameters.stdDeviationX, 20), min(parameters.stdDeviationY, 20))
    }
    return WebCore.FloatSize(parameters.stdDeviationX, parameters.stdDeviationY)
}

// The box size of a standard deviation, at least 2 and at most 500: a bigger radius barely changes the result but
// inflates the absolute paint rect too much (Firefox limits it the same way).
private func clampedToKernelSize(_ value: Float) -> Int32 {
    // 3 / 4.f * sqrtf(2 * std::numbers::pi_v<float>). Float.pi is pi rounded toward zero; Float(Double.pi) is pi rounded
    // to nearest, as std::numbers::pi_v<float> is.
    let gaussianKernelFactor: Float = 0.75 * (2 * Float(Double.pi)).squareRoot()
    let maxKernelSize: UInt32 = 500
    let size = max(2, UInt32(arm64Truncating: (value * gaussianKernelFactor + 0.5).rounded(.down)))
    return Int32(min(size, maxKernelSize))
}

// FEGaussianBlur::calculateUnscaledKernelSize(): the box size of each nonzero deviation.
@_expose(Cxx)
func feGaussianBlurUnscaledKernelSize(_ stdDeviation: WebCore.FloatSize) -> WebCore.IntSize {
    assert(stdDeviation.width() >= 0 && stdDeviation.height() >= 0)
    var kernelSize = WebCore.IntSize()
    if stdDeviation.width() != 0 {
        kernelSize.setWidth(clampedToKernelSize(stdDeviation.width()))
    }
    if stdDeviation.height() != 0 {
        kernelSize.setHeight(clampedToKernelSize(stdDeviation.height()))
    }
    return kernelSize
}

// FEGaussianBlur::calculateOutsetSize(): three times half the box size, since the box blur runs three times.
@_expose(Cxx)
func feGaussianBlurOutsetSize(_ stdDeviation: WebCore.FloatSize) -> WebCore.IntSize {
    let kernelSize = feGaussianBlurUnscaledKernelSize(stdDeviation)
    return WebCore.IntSize(3 * kernelSize.width() / 2, 3 * kernelSize.height() / 2)
}

// FEGaussianBlur::calculateOutsets().
@_expose(Cxx)
func feGaussianBlurOutsets(_ stdDeviation: WebCore.FloatSize) -> WebCore.FilterOutsets {
    let outsetSize = feGaussianBlurOutsetSize(stdDeviation)
    return WebCore.FilterOutsets(top: outsetSize.height(), right: outsetSize.width(), bottom: outsetSize.height(), left: outsetSize.width())
}

// FEGaussianBlur::calculateImageRect().
func feGaussianBlurImageRect(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEGaussianBlurParameters,
    _ inputImageRect: WebCore.FloatRect,
    _ primitiveSubregion: WebCore.FloatRect
) -> WebCore.FloatRect {
    // Edge modes other than 'none' do not inflate the affected paint rect.
    if parameters.edgeMode != .None {
        return WebCore.FloatRect(WebCore.enclosingIntRect(inputImageRect))
    }

    let stdDeviation = feGaussianBlurEffectiveStdDeviation(parameters, context.fastAndLowQuality)
    let kernelSize = feGaussianBlurUnscaledKernelSize(context.resolvedSize(stdDeviation))

    var imageRect = inputImageRect
    imageRect.inflateX(Float(3 * kernelSize.width()) * 0.5)
    imageRect.inflateY(Float(3 * kernelSize.height()) * 0.5)
    return context.clipToMaxEffectRect(imageRect, primitiveSubregion)
}

// FEGaussianBlurSoftwareApplier::apply(): three box blurs in each direction, which approximate a Gaussian blur.
func feGaussianBlurApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEGaussianBlurParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let destination = result.pixelBuffer(.Premultiplied).get() else {
        return false
    }

    let effectDrawingRect = result.absoluteImageRect(relativeTo: input)
    if !input.copyPixelBuffer(into: destination, sourceRect: effectDrawingRect) {
        // Without the input's pixels, the blur is of transparent black.
        destination.zeroFill()
    }

    let stdDeviation = feGaussianBlurEffectiveStdDeviation(parameters, context.fastAndLowQuality)
    if stdDeviation.width() == 0 && stdDeviation.height() == 0 {
        return true
    }

    let kernelSize = feGaussianBlurUnscaledKernelSize(context.scaledByFilterScale(context.resolvedSize(stdDeviation)))
    let paintSize = result.absoluteImageRect.size()
    guard let temporary = WebCore.FEGaussianBlurBridge.createScratchPixelBuffer(destination, paintSize).get() else {
        return false
    }

    let blur = BoxBlur(
        kernelSizeX: Int(kernelSize.width()),
        kernelSizeY: Int(kernelSize.height()),
        width: Int(paintSize.width()),
        height: Int(paintSize.height()),
        isAlphaImage: result.isAlphaImage,
        edgeMode: parameters.edgeMode
    )

    #if USE_ACCELERATE
    let accelerated = blur.kernelSizeX == blur.kernelSizeY && (blur.edgeMode == .None || blur.edgeMode == .Duplicate)
    #else
    let accelerated = false
    #endif
    if !accelerated && blur.isAlphaImage {
        // The alpha-only blur writes only the alpha channel of the temporary buffer.
        temporary.zeroFill()
    }

    // No writes through FilterImageImpl or the pixel buffers past this point.
    var destinationAccess = WebCore.PixelBufferAccess(destination)
    var image: MutableSpan<UInt8> = destinationAccess.mutableSpan()
    var temporaryAccess = WebCore.PixelBufferAccess(temporary)
    var temporaryBytes: MutableSpan<UInt8> = temporaryAccess.mutableSpan()

    #if USE_ACCELERATE
    if accelerated {
        vImageBoxBlur(&image, &temporaryBytes, kernelSize: blur.kernelSizeX, width: blur.width, height: blur.height)
        return true
    }
    #else
    let jobs = blur.jobCount(processorCores: Int(WTF.numberOfProcessorCores()))
    if jobs > 1 {
        let applied = blur.applyInParallel(&image, &temporaryBytes, jobs: jobs)
        precondition(applied)
        return true
    }
    #endif

    blur.apply(&image, &temporaryBytes)
    return true
}

// FEGaussianBlurSoftwareApplier's box blurs without Accelerate (or with kernels it can't take): three passes of a box
// of kernelSizeX pixels along the rows and three of kernelSizeY along the columns, alternating, from the image to the
// temporary buffer and back. The alpha-only blur keeps every pixel's color channels as they are in its destination.
private struct BoxBlur {
    let kernelSizeX: Int
    let kernelSizeY: Int
    let width: Int
    let height: Int
    let isAlphaImage: Bool
    let edgeMode: WebCore.EdgeModeType

    // FEGaussianBlurSoftwareApplier::boxBlurUnaccelerated(): the result ends in `image`.
    func apply(_ image: inout MutableSpan<UInt8>, _ temporary: inout MutableSpan<UInt8>) {
        var kernelSizeX = kernelSizeX
        var kernelSizeY = kernelSizeY
        var deltaX = (left: 0, right: 0)
        var deltaY = (left: 0, right: 0)
        let rowBytes = 4 * width
        var resultIsInTemporary = false

        for blurIteration in 0..<3 {
            if kernelSizeX != 0 {
                kernelPosition(blurIteration, &kernelSizeX, &deltaX)
                let pass = BoxBlurPass(
                    divisor: kernelSizeX,
                    deltaLeft: deltaX.left,
                    deltaRight: deltaX.right,
                    stride: 4,
                    strideLine: rowBytes,
                    effectWidth: width,
                    effectHeight: height
                )
                run(pass, &image, &temporary, &resultIsInTemporary)
            }
            if kernelSizeY != 0 {
                kernelPosition(blurIteration, &kernelSizeY, &deltaY)
                let pass = BoxBlurPass(
                    divisor: kernelSizeY,
                    deltaLeft: deltaY.left,
                    deltaRight: deltaY.right,
                    stride: rowBytes,
                    strideLine: 4,
                    effectWidth: height,
                    effectHeight: width
                )
                run(pass, &image, &temporary, &resultIsInTemporary)
            }
        }

        if resultIsInTemporary {
            let byteCount = image.count
            copyBytes(from: temporary.span, at: 0, to: &image, at: 0, count: byteCount)
        }
    }

    private func run(
        _ pass: BoxBlurPass,
        _ image: inout MutableSpan<UInt8>,
        _ temporary: inout MutableSpan<UInt8>,
        _ resultIsInTemporary: inout Bool
    ) {
        if resultIsInTemporary {
            var destination = image.mutableBytes
            pass.apply(temporary.bytes, &destination, isAlphaImage: isAlphaImage, edgeMode: edgeMode)
        } else {
            var destination = temporary.mutableBytes
            pass.apply(image.bytes, &destination, isAlphaImage: isAlphaImage, edgeMode: edgeMode)
        }
        resultIsInTemporary.toggle()
    }

    // FEGaussianBlurSoftwareApplier::applyPlatform()'s job count without Accelerate: jobs of at least 100 x 100 pixels
    // plus their margin rows, at most one per processor core (WTF::ParallelJobs's generic backend), and 1 when it isn't
    // worth splitting.
    func jobCount(processorCores: Int) -> Int {
        let minimalRectDimension = 100 * 100
        let optimalThreadNumber = (width * height) / (minimalRectDimension + extraHeight * width)
        if optimalThreadNumber <= 1 {
            return 1
        }
        return min(optimalThreadNumber, max(1, processorCores))
    }

    // How far three passes of the vertical box reach above or below a row, rounded up.
    var extraHeight: Int {
        Int(Int32(arm64Truncating: Float(3 * kernelSizeY) * 0.5))
    }

    // FEGaussianBlurSoftwareApplier::applyPlatform() without Accelerate: `jobs` blocks of rows (as WTF::ParallelJobs
    // splits them), each blurred concurrently with up to extraHeight rows of the image above and below it, which is as
    // far as the blur reaches, so each block's own rows come out as the whole image's would. The temporary buffer holds
    // the image the jobs read. False, with nothing done, if the buffers are too small.
    func applyInParallel(_ image: inout MutableSpan<UInt8>, _ temporary: inout MutableSpan<UInt8>, jobs: Int) -> Bool {
        let rowBytes = 4 * width
        guard let byteCount = height.checkedMultiplied(by: rowBytes), byteCount <= image.count, byteCount <= temporary.count else {
            return false
        }
        copyBytes(from: image.span, at: 0, to: &temporary, at: 0, count: byteCount)

        let source: Span<UInt8> = temporary.span
        let blur = self
        let extraHeight = extraHeight
        let height = height
        return parallelRows(height: height, jobs: jobs, rowBytes: rowBytes, into: &image) { rows, output in
            let startY = rows.lowerBound == 0 ? 0 : max(0, rows.lowerBound - extraHeight)
            let endY = rows.upperBound == height ? height : min(height, rows.upperBound + extraHeight)
            let blockBytes = (endY - startY) * rowBytes
            var blockImage = ContiguousArray<UInt8>(repeating: 0, count: blockBytes)
            var blockTemporary = ContiguousArray<UInt8>(repeating: 0, count: blockBytes)
            var blockImageSpan = blockImage.mutableSpan
            copyBytes(from: source, at: startY * rowBytes, to: &blockImageSpan, at: 0, count: blockBytes)
            var blockTemporarySpan = blockTemporary.mutableSpan
            BoxBlur(
                kernelSizeX: blur.kernelSizeX,
                kernelSizeY: blur.kernelSizeY,
                width: blur.width,
                height: endY - startY,
                isAlphaImage: blur.isAlphaImage,
                edgeMode: blur.edgeMode
            )
            .apply(&blockImageSpan, &blockTemporarySpan)

            copyBytes(
                from: blockImageSpan.span,
                at: (rows.lowerBound - startY) * rowBytes,
                to: &output,
                at: 0,
                count: rows.count * rowBytes
            )
        }
    }
}

// FEGaussianBlurSoftwareApplier::kernelPosition(): the box of pass `blurIteration` for a kernel of `radius` pixels, as
// pixels to the left of and from a pixel; see the feGaussianBlur element in the SVG specification. An even kernel's
// box is off center in the first pass, the other way in the second, and one pixel wider and centered in the third.
private func kernelPosition(_ blurIteration: Int, _ radius: inout Int, _ delta: inout (left: Int, right: Int)) {
    switch blurIteration {
    case 0:
        if radius % 2 == 0 {
            delta.left = radius / 2 - 1
            delta.right = radius - delta.left
        } else {
            delta.left = radius / 2
            delta.right = radius - delta.left
        }
    case 1:
        if radius % 2 == 0 {
            delta.left += 1
            delta.right -= 1
        }
    case 2:
        if radius % 2 == 0 {
            delta.right += 1
            radius += 1
        }
    default:
        break
    }
}

// One box blur pass (FEGaussianBlurSoftwareApplier::boxBlur()) over effectHeight lines of effectWidth pixels, lines
// strideLine bytes apart and pixels stride bytes apart within a line: rows for the horizontal passes, columns for the
// vertical ones. Each pixel becomes the sum of the pixels in [x - deltaLeft, x + deltaRight) of its line divided by
// `divisor`. EdgeModeType::None leaves out the pixels past the line's ends; the other edge modes (Wrap is unsupported)
// repeat the end pixels.
private struct BoxBlurPass {
    let divisor: Int
    let deltaLeft: Int
    let deltaRight: Int
    let stride: Int
    let strideLine: Int
    let effectWidth: Int
    let effectHeight: Int

    func apply(_ source: RawSpan, _ destination: inout MutableRawSpan, isAlphaImage: Bool, edgeMode: WebCore.EdgeModeType) {
        guard effectWidth > 0, effectHeight > 0 else {
            return
        }
        // Every byte the pass touches lies in both buffers.
        let lastPixel = (effectHeight - 1).checkedMultiplied(by: strideLine)
            .flatMap { line in (effectWidth - 1).checkedMultiplied(by: stride).flatMap { line.checkedAdding($0) } }
            .flatMap { $0.checkedAdding(4) }
        precondition(divisor > 0 && deltaLeft >= 0 && deltaRight > 0)
        precondition(lastPixel.map { $0 <= source.byteCount && $0 <= destination.byteCount } ?? false)

        let average = BoxAverage(divisor: divisor)
        if isAlphaImage {
            applyAlphaOnly(source, &destination, average)
        } else if edgeMode == .None {
            applyWithoutEdges(source, &destination, average)
        } else {
            applyDuplicatingEdges(source, &destination, average)
        }
    }

    // Only the alpha channel, without edges whatever the edge mode.
    private func applyAlphaOnly(_ source: RawSpan, _ destination: inout MutableRawSpan, _ average: BoxAverage) {
        let maxKernelSize = min(deltaRight, effectWidth)
        let ranges = WindowRanges(self)
        for y in 0..<effectHeight {
            let line = y &* strideLine &+ 3
            var sum: UInt32 = 0
            for i in 0..<maxKernelSize {
                sum &+= UInt32(source.load(fromByteOffset: line &+ i &* stride, as: UInt8.self))
            }
            var offset = line
            let leftOffset = deltaLeft &* stride
            let rightOffset = deltaRight &* stride
            for _ in 0..<ranges.entering {
                destination.storeBytes(of: average.scalar(sum), toByteOffset: offset, as: UInt8.self)
                sum &+= UInt32(source.load(fromByteOffset: offset &+ rightOffset, as: UInt8.self))
                offset &+= stride
            }
            for _ in 0..<ranges.sliding {
                destination.storeBytes(of: average.scalar(sum), toByteOffset: offset, as: UInt8.self)
                sum &-= UInt32(source.load(fromByteOffset: offset &- leftOffset, as: UInt8.self))
                sum &+= UInt32(source.load(fromByteOffset: offset &+ rightOffset, as: UInt8.self))
                offset &+= stride
            }
            for _ in 0..<ranges.covering {
                destination.storeBytes(of: average.scalar(sum), toByteOffset: offset, as: UInt8.self)
                offset &+= stride
            }
            for _ in 0..<ranges.leaving {
                destination.storeBytes(of: average.scalar(sum), toByteOffset: offset, as: UInt8.self)
                sum &-= UInt32(source.load(fromByteOffset: offset &- leftOffset, as: UInt8.self))
                offset &+= stride
            }
        }
    }

    private func applyWithoutEdges(_ source: RawSpan, _ destination: inout MutableRawSpan, _ average: BoxAverage) {
        let maxKernelSize = min(deltaRight, effectWidth)
        let ranges = WindowRanges(self)
        let leftOffset = deltaLeft &* stride
        let rightOffset = deltaRight &* stride
        for y in 0..<effectHeight {
            let line = y &* strideLine
            var sum = SIMD4<UInt32>()
            for i in 0..<maxKernelSize {
                sum &+= pixel(source, line &+ i &* stride)
            }
            var offset = line
            for _ in 0..<ranges.entering {
                destination.storeBytes(of: average.vector(sum), toByteOffset: offset, as: SIMD4<UInt8>.self)
                sum &+= pixel(source, offset &+ rightOffset)
                offset &+= stride
            }
            for _ in 0..<ranges.sliding {
                destination.storeBytes(of: average.vector(sum), toByteOffset: offset, as: SIMD4<UInt8>.self)
                sum &+= pixel(source, offset &+ rightOffset) &- pixel(source, offset &- leftOffset)
                offset &+= stride
            }
            for _ in 0..<ranges.covering {
                destination.storeBytes(of: average.vector(sum), toByteOffset: offset, as: SIMD4<UInt8>.self)
                offset &+= stride
            }
            for _ in 0..<ranges.leaving {
                destination.storeBytes(of: average.vector(sum), toByteOffset: offset, as: SIMD4<UInt8>.self)
                sum &-= pixel(source, offset &- leftOffset)
                offset &+= stride
            }
        }
    }

    private func applyDuplicatingEdges(_ source: RawSpan, _ destination: inout MutableRawSpan, _ average: BoxAverage) {
        for y in 0..<effectHeight {
            let line = y &* strideLine
            let edgeValueLeft = pixel(source, line)
            let edgeValueRight = pixel(source, line &+ (effectWidth &- 1) &* stride)

            var sum = SIMD4<UInt32>()
            for i in -deltaLeft..<deltaRight {
                if i < 0 {
                    sum &+= edgeValueLeft
                } else if i >= effectWidth {
                    sum &+= edgeValueRight
                } else {
                    sum &+= pixel(source, line &+ i &* stride)
                }
            }

            for x in 0..<effectWidth {
                let pixelByteOffset = line &+ x &* stride
                destination.storeBytes(of: average.vector(sum), toByteOffset: pixelByteOffset, as: SIMD4<UInt8>.self)
                if x < deltaLeft {
                    sum &-= edgeValueLeft
                } else {
                    sum &-= pixel(source, pixelByteOffset &- deltaLeft &* stride)
                }
                if x &+ deltaRight >= effectWidth {
                    sum &+= edgeValueRight
                } else {
                    sum &+= pixel(source, pixelByteOffset &+ deltaRight &* stride)
                }
            }
        }
    }

    @inline(__always)
    private func pixel(_ source: RawSpan, _ offset: Int) -> SIMD4<UInt32> {
        SIMD4<UInt32>(truncatingIfNeeded: source.load(fromByteOffset: offset, as: SIMD4<UInt8>.self))
    }
}

// The pixels x of a line, in order, by which ends of the box [x - deltaLeft, x + deltaRight) are inside the line:
// `entering` pixels where only a pixel enters the box on the right, then either `sliding` pixels where one leaves on the
// left and one enters or `covering` pixels where the box covers the whole line, then `leaving` pixels where one only
// leaves on the left.
private struct WindowRanges {
    let entering: Int
    let sliding: Int
    let covering: Int
    let leaving: Int

    init(_ pass: BoxBlurPass) {
        let width = pass.effectWidth
        // A pixel leaves on the left from x = deltaLeft on, and one enters on the right before x = width - deltaRight.
        let leavingStart = min(pass.deltaLeft, width)
        let enteringEnd = max(0, min(width - pass.deltaRight, width))
        entering = min(leavingStart, enteringEnd)
        sliding = max(0, enteringEnd - leavingStart)
        covering = max(0, leavingStart - enteringEnd)
        leaving = width - max(leavingStart, enteringEnd)
    }
}

// sum / divisor for the box sums, which are at most 255 * divisor: multiplying by ceil(2^32 / divisor) and keeping the
// high 32 bits of the product gives exactly that for sums below 2^18 and divisors up to 2^14 (kernels are at most 501
// pixels), and costs less than dividing.
private struct BoxAverage {
    let reciprocal: UInt64

    init(divisor: Int) {
        reciprocal = ((1 << 32) + UInt64(divisor) - 1) / UInt64(divisor)
    }

    @inline(__always)
    func scalar(_ sum: UInt32) -> UInt8 {
        UInt8(truncatingIfNeeded: (UInt64(sum) &* reciprocal) &>> 32)
    }

    @inline(__always)
    func vector(_ sum: SIMD4<UInt32>) -> SIMD4<UInt8> {
        SIMD4<UInt8>(truncatingIfNeeded: (SIMD4<UInt64>(truncatingIfNeeded: sum) &* reciprocal) &>> 32)
    }
}

#if USE_SKIA
// FEGaussianBlurSkiaApplier::apply(): Skia draws the blur (FilterSkiaBridge.cpp).
func feGaussianBlurApplySkia(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEGaussianBlurParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let resultImage = result.imageBuffer()
    let sourceImage = input.imageBuffer()
    guard let resultImage = resultImage.get(), let sourceImage = sourceImage.get() else {
        return false
    }
    let filterScale = context.filterScale
    let sigma = WebCore.FloatSize(parameters.stdDeviationX * filterScale.width(), parameters.stdDeviationY * filterScale.height())
    let inputOffsetWithinResult = input.absoluteImageRect(relativeTo: result).location()
    return WebCore.FilterSkiaBridge.drawBlur(resultImage, sourceImage, sigma, inputOffsetWithinResult)
}
#endif

#endif // ENABLE_WEBCORE_SWIFT
