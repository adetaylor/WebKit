// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
// Copyright (C) 2010 Sencha, Inc. All rights reserved.
// Copyright (C) 2010 Igalia S.L. All rights reserved.
// Copyright (C) Research In Motion Limited 2011. All rights reserved.
// Copyright (C) 2013 Digia Plc. and/or its subsidiary(-ies).
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

#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif
import wtf.Core.MathExtras

// ShadowBlur's blur: two passes (horizontal, then vertical) of three box blurs. The first box blur reads the alpha
// channel and writes the red one, the second reads red and writes green, the third reads green and writes alpha.

// Indexed by step: the channel a step reads is at index step, the one it writes at index step + 1.
@inline(__always)
private func shadowBlurChannel(_ index: Int) -> Int {
    switch index {
    case 0: 3
    case 1: 0
    case 2: 1
    default: 3
    }
}

// The left and right lobes of each step's box.
private struct ShadowBlurLobes {
    var left: (Int32, Int32, Int32)
    var right: (Int32, Int32, Int32)

    @inline(__always)
    func leftLobe(_ step: Int) -> Int32 {
        switch step {
        case 0: left.0
        case 1: left.1
        default: left.2
        }
    }

    @inline(__always)
    func rightLobe(_ step: Int) -> Int32 {
        switch step {
        case 0: right.0
        case 1: right.1
        default: right.2
        }
    }
}

private func shadowBlurLobes(_ blurRadius: Float, _ shadowsIgnoreTransforms: Bool) -> ShadowBlurLobes {
    let diameter: Int32
    if shadowsIgnoreTransforms {
        // Canvas shadow. FIXME: we should adjust the blur radius higher up.
        let truncated = WTF.truncateFloatToInt32((Float(2) / 3 * blurRadius).rounded(.down))
        diameter = 2 < truncated ? truncated : 2
    } else {
        // http://dev.w3.org/csswg/css3-background/#box-shadow
        // Approximate a Gaussian blur with a standard deviation equal to half the blur radius,
        // which http://www.w3.org/TR/SVG/filters.html#feGaussianBlurElement tell us how to do.
        // However, shadows rendered according to that spec will extend a little further than m_blurRadius,
        // so we apply a fudge factor to bring the radius down slightly.
        let stdDev = blurRadius / 2
        let gaussianKernelFactor = 0.75 * (2 * Float(Double.pi)).squareRoot()
        let fudgeFactor: Float = 0.88
        let truncated = WTF.truncateFloatToInt32((stdDev * gaussianKernelFactor * fudgeFactor + 0.5).rounded(.down))
        diameter = 2 < truncated ? truncated : 2
    }

    if diameter & 1 != 0 {
        // if d is odd, use three box-blurs of size 'd', centered on the output pixel.
        let lobeSize = (diameter - 1) / 2
        return ShadowBlurLobes(left: (lobeSize, lobeSize, lobeSize), right: (lobeSize, lobeSize, lobeSize))
    }
    // if d is even, two box-blurs of size 'd' (the first one centered on the pixel boundary
    // between the output pixel and the one to the left, the second one centered on the pixel
    // boundary between the output pixel and the one to the right) and one box blur of size 'd+1' centered on the output pixel
    let lobeSize = diameter / 2
    return ShadowBlurLobes(left: (lobeSize, lobeSize - 1, lobeSize), right: (lobeSize - 1, lobeSize, lobeSize))
}

// Instead of integer division, we use 17.15 for fixed-point division.
@inline(__always)
private func shadowBlurReciprocal(_ pixelCount: Int32) -> Int32 {
    ((1 << 15) &+ pixelCount &- 1) / pixelCount
}

@inline(__always)
private func shadowBlurAverage(_ sum: Int32, _ reciprocal: Int32) -> UInt8 {
    UInt8(truncatingIfNeeded: (sum &* reciprocal) >> 15)
}

// Blurs `image`, `height` rows of `width` pixels, `rowStride` bytes apart, as ShadowBlur::blurLayerImage does.
func shadowBlurLayerImage(
    _ image: inout MutableSpan<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ rowStride: Int32,
    _ radiusWidth: Float,
    _ radiusHeight: Float,
    _ shadowsIgnoreTransforms: Bool
) {
    // Both of ShadowBlur's callers pass rows of 4 * width bytes, height of them.
    if width > 0 && height > 0 && Int(rowStride) == 4 * Int(width) && image.count == Int(height) * Int(rowStride) {
        var bytes = image.mutableBytes
        shadowBlurRows(&bytes, Int(width), Int(height), radiusWidth, radiusHeight, shadowsIgnoreTransforms)
        return
    }
    shadowBlurLayerImageLiteral(&image, width, height, rowStride, radiusWidth, radiusHeight, shadowsIgnoreTransforms)
}

// MARK: Any geometry

// A std::span of `image`: an offset and a count with size_t's arithmetic, checked as std::span's operations are.
private struct ShadowBlurSpan {
    var offset: UInt
    var count: UInt

    static var empty: ShadowBlurSpan { ShadowBlurSpan(offset: 0, count: 0) }

    @inline(__always)
    func subspan(_ start: UInt) -> ShadowBlurSpan {
        precondition(start <= count)
        return ShadowBlurSpan(offset: offset &+ start, count: count &- start)
    }

    @inline(__always)
    func index(_ position: UInt) -> Int {
        precondition(position < count)
        return Int(bitPattern: offset &+ position)
    }
}

@inline(__always)
private func shadowBlurSize(_ value: Int32) -> UInt {
    UInt(bitPattern: Int(value))
}

// ShadowBlur::blurLayerImage statement by statement, for any arguments.
func shadowBlurLayerImageLiteral(
    _ image: inout MutableSpan<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ rowStride: Int32,
    _ radiusWidth: Float,
    _ radiusHeight: Float,
    _ shadowsIgnoreTransforms: Bool
) {
    var lobes = shadowBlurLobes(radiusWidth, shadowsIgnoreTransforms)

    // First pass is horizontal.
    var stride: UInt = 4
    var delta = rowStride
    var final = height
    var dim = width
    let imageData = ShadowBlurSpan(offset: 0, count: UInt(image.count))

    // Two stages: horizontal and vertical
    var pass = 0
    while pass < 2 {
        var pixels = imageData

        if pass == 0 && radiusWidth == 0 {
            final = 0 // Do no work if horizonal blur is zero.
        }

        var j: Int32 = 0
        while j < final {
            // For each step, we blur the alpha in a channel and store the result
            // in another channel for the subsequent step.
            // We use sliding window algorithm to accumulate the alpha values.
            // This is much more efficient than computing the sum of each pixels
            // covered by the box kernel size for each x.
            var step = 0
            while step < 3 {
                let side1 = lobes.leftLobe(step)
                let side2 = lobes.rightLobe(step)
                let pixelCount = side1 &+ 1 &+ side2
                let invCount = shadowBlurReciprocal(pixelCount)
                var ofs = 1 &+ side2
                let channel = UInt(shadowBlurChannel(step))
                let alpha1 = Int32(image[pixels.index(channel)])
                let alpha2 = Int32(image[pixels.index(shadowBlurSize(dim &- 1) &* stride &+ channel)])

                var ptr = pixels.subspan(UInt(shadowBlurChannel(step + 1)))

                // If either dimension is 1 pixel long, prev would go outside the bounds of pixels,
                // so make it an empty subspan.
                var prev = stride &+ channel < pixels.count ? pixels.subspan(stride &+ channel) : .empty

                // if image to be blurred is smaller than the box kernel size, next would go outside
                // the bounds of pixels, so make it an empty subspan.
                let nextStart = shadowBlurSize(ofs) &* stride &+ channel
                var next = nextStart < pixels.count ? pixels.subspan(nextStart) : .empty

                var sum = side1 &* alpha1 &+ alpha1
                var limit = dim < side2 &+ 1 ? dim : side2 &+ 1

                var i: Int32 = 1
                while i < limit && prev.count >= stride {
                    sum &+= Int32(image[prev.index(0)])
                    i &+= 1
                    prev = prev.subspan(stride)
                }

                if limit <= side2 {
                    sum &+= (side2 &- limit &+ 1) &* alpha2
                }

                limit = side1 < dim ? side1 : dim
                i = 0
                while i < limit && ptr.count >= stride && next.count >= stride {
                    image[ptr.index(0)] = shadowBlurAverage(sum, invCount)
                    sum &+= (ofs < dim ? Int32(image[next.index(0)]) : alpha2) &- alpha1
                    ptr = ptr.subspan(stride)
                    next = next.subspan(stride)
                    i &+= 1
                    ofs &+= 1
                }

                prev = pixels.subspan(channel)
                while ofs < dim && ptr.count >= stride && prev.count >= stride && next.count >= stride {
                    image[ptr.index(0)] = shadowBlurAverage(sum, invCount)
                    sum &+= Int32(image[next.index(0)]) &- Int32(image[prev.index(0)])
                    ptr = ptr.subspan(stride)
                    prev = prev.subspan(stride)
                    next = next.subspan(stride)
                    i &+= 1
                    ofs &+= 1
                }

                while i < dim && ptr.count >= stride && prev.count >= stride {
                    image[ptr.index(0)] = shadowBlurAverage(sum, invCount)
                    sum &+= alpha2 &- Int32(image[prev.index(0)])
                    ptr = ptr.subspan(stride)
                    prev = prev.subspan(stride)
                    i &+= 1
                }
                step += 1
            }
            j &+= 1
            pixels = pixels.subspan(shadowBlurSize(delta))
        }

        // Last pass is vertical.
        stride = shadowBlurSize(rowStride)
        delta = 4
        final = width
        dim = height

        if radiusHeight == 0 {
            break
        }

        if radiusWidth != radiusHeight {
            lobes = shadowBlurLobes(radiusHeight, shadowsIgnoreTransforms)
        }
        pass += 1
    }
}

// MARK: The callers' geometry

// How many times each of the four loops of a step runs on one line. In the literal form, each loop also stops when one
// of its spans has fewer than `stride` bytes left; these are those limits computed in advance.
private struct ShadowBlurLineCounts: Equatable {
    var first: Int
    var second: Int
    var third: Int
    var fourth: Int
}

// How many times a loop that needs `stride` bytes runs over a span that starts `start` bytes into a line of `length`
// bytes and advances by `stride`.
@inline(__always)
private func shadowBlurGuardedCount(_ length: Int, _ start: Int, _ stride: Int) -> Int {
    if start >= length {
        return 0
    }
    let room = length &- start &- stride
    if room < 0 {
        return 0
    }
    return room / stride &+ 1
}

@inline(__always)
private func shadowBlurLineCounts(
    _ length: Int,
    _ stride: Int,
    _ channel: Int,
    _ nextChannel: Int,
    _ side1: Int,
    _ side2: Int,
    _ dim: Int
) -> ShadowBlurLineCounts {
    let firstLimit = dim < side2 &+ 1 ? dim : side2 &+ 1
    let first = max(0, min(firstLimit &- 1, shadowBlurGuardedCount(length, stride &+ channel, stride)))
    let nextCount = shadowBlurGuardedCount(length, (side2 &+ 1) &* stride &+ channel, stride)
    let pointerCount = shadowBlurGuardedCount(length, nextChannel, stride)
    let second = max(0, min(min(side1 < dim ? side1 : dim, pointerCount), nextCount))
    let previousCount = shadowBlurGuardedCount(length, channel, stride)
    let third = max(
        0,
        min(min(dim &- (side2 &+ 1 &+ second), pointerCount &- second), min(previousCount, nextCount &- second))
    )
    let fourth = max(0, min(min(dim &- second &- third, pointerCount &- second &- third), previousCount &- third))
    return ShadowBlurLineCounts(first: first, second: second, third: third, fourth: fourth)
}

@inline(__always)
private func shadowBlurLoad(_ bytes: borrowing MutableRawSpan, _ offset: Int) -> Int32 {
    Int32(bytes.load(fromByteOffset: offset, as: UInt8.self))
}

// One step on one line, a row or a column, from `base`, with its loop counts.
@inline(never)
private func shadowBlurLine(
    _ bytes: inout MutableRawSpan,
    _ base: Int,
    _ stride: Int,
    _ channel: Int,
    _ nextChannel: Int,
    _ side1: Int32,
    _ side2: Int32,
    _ dim: Int,
    _ counts: ShadowBlurLineCounts
) {
    let invCount = shadowBlurReciprocal(side1 &+ 1 &+ side2)
    let alpha1 = shadowBlurLoad(bytes, base &+ channel)
    let alpha2 = shadowBlurLoad(bytes, base &+ (dim &- 1) &* stride &+ channel)

    var sum = side1 &* alpha1 &+ alpha1
    var previous = base &+ stride &+ channel
    var k = 0
    while k < counts.first {
        sum &+= shadowBlurLoad(bytes, previous)
        previous &+= stride
        k &+= 1
    }
    if dim <= Int(side2) {
        sum &+= (side2 &- Int32(truncatingIfNeeded: dim) &+ 1) &* alpha2
    }

    var output = base &+ nextChannel
    var ofs = Int(side2) &+ 1
    var next = base &+ ofs &* stride &+ channel
    k = 0
    while k < counts.second {
        bytes.storeBytes(of: shadowBlurAverage(sum, invCount), toByteOffset: output, as: UInt8.self)
        sum &+= (ofs < dim ? shadowBlurLoad(bytes, next) : alpha2) &- alpha1
        output &+= stride
        next &+= stride
        ofs &+= 1
        k &+= 1
    }

    previous = base &+ channel
    k = 0
    while k < counts.third {
        bytes.storeBytes(of: shadowBlurAverage(sum, invCount), toByteOffset: output, as: UInt8.self)
        sum &+= shadowBlurLoad(bytes, next) &- shadowBlurLoad(bytes, previous)
        output &+= stride
        next &+= stride
        previous &+= stride
        k &+= 1
    }

    k = 0
    while k < counts.fourth {
        bytes.storeBytes(of: shadowBlurAverage(sum, invCount), toByteOffset: output, as: UInt8.self)
        sum &+= alpha2 &- shadowBlurLoad(bytes, previous)
        output &+= stride
        previous &+= stride
        k &+= 1
    }
}

#if arch(arm64)

// One channel of 16 consecutive pixels, as four vectors of 32-bit lanes.
private struct ShadowBlurLanes {
    var lanes0: SIMD4<Int32>
    var lanes1: SIMD4<Int32>
    var lanes2: SIMD4<Int32>
    var lanes3: SIMD4<Int32>

    @inline(__always)
    init(repeating value: Int32) {
        let lanes = vdupq_n_s32(value)
        lanes0 = lanes
        lanes1 = lanes
        lanes2 = lanes
        lanes3 = lanes
    }

    @inline(__always)
    init(_ lanes0: SIMD4<Int32>, _ lanes1: SIMD4<Int32>, _ lanes2: SIMD4<Int32>, _ lanes3: SIMD4<Int32>) {
        self.lanes0 = lanes0
        self.lanes1 = lanes1
        self.lanes2 = lanes2
        self.lanes3 = lanes3
    }

    // `indices` picks the channel's byte of each pixel into the low byte of a lane, and zeroes the others.
    @inline(__always)
    init(_ bytes: borrowing MutableRawSpan, _ offset: Int, _ indices: SIMD16<UInt8>) {
        // One check for the 64 bytes; the loads at constant offsets need none of their own.
        let block = bytes.bytes.extracting(offset..<offset &+ 64)
        lanes0 = vreinterpretq_s32_u8(vqtbl1q_u8(block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self), indices))
        lanes1 = vreinterpretq_s32_u8(vqtbl1q_u8(block.load(fromByteOffset: 16, as: SIMD16<UInt8>.self), indices))
        lanes2 = vreinterpretq_s32_u8(vqtbl1q_u8(block.load(fromByteOffset: 32, as: SIMD16<UInt8>.self), indices))
        lanes3 = vreinterpretq_s32_u8(vqtbl1q_u8(block.load(fromByteOffset: 48, as: SIMD16<UInt8>.self), indices))
    }

    @inline(__always)
    static func &+ (left: ShadowBlurLanes, right: ShadowBlurLanes) -> ShadowBlurLanes {
        ShadowBlurLanes(
            vaddq_s32(left.lanes0, right.lanes0),
            vaddq_s32(left.lanes1, right.lanes1),
            vaddq_s32(left.lanes2, right.lanes2),
            vaddq_s32(left.lanes3, right.lanes3)
        )
    }

    @inline(__always)
    static func &- (left: ShadowBlurLanes, right: ShadowBlurLanes) -> ShadowBlurLanes {
        ShadowBlurLanes(
            vsubq_s32(left.lanes0, right.lanes0),
            vsubq_s32(left.lanes1, right.lanes1),
            vsubq_s32(left.lanes2, right.lanes2),
            vsubq_s32(left.lanes3, right.lanes3)
        )
    }

    @inline(__always)
    static func &* (left: ShadowBlurLanes, right: Int32) -> ShadowBlurLanes {
        let factor = vdupq_n_s32(right)
        return ShadowBlurLanes(
            vmulq_s32(left.lanes0, factor),
            vmulq_s32(left.lanes1, factor),
            vmulq_s32(left.lanes2, factor),
            vmulq_s32(left.lanes3, factor)
        )
    }

    // Stores the low byte of `(lane * reciprocal) >> 15` into the channel `indices` picks, keeping the other bytes.
    @inline(__always)
    func storeAverage(_ bytes: inout MutableRawSpan, _ offset: Int, _ reciprocal: Int32, _ indices: SIMD16<UInt8>) {
        let factor = vdupq_n_s32(reciprocal)
        let shift = vdupq_n_s32(-15)
        let averages0 = vreinterpretq_u8_s32(vshlq_s32(vmulq_s32(lanes0, factor), shift))
        let averages1 = vreinterpretq_u8_s32(vshlq_s32(vmulq_s32(lanes1, factor), shift))
        let averages2 = vreinterpretq_u8_s32(vshlq_s32(vmulq_s32(lanes2, factor), shift))
        let averages3 = vreinterpretq_u8_s32(vshlq_s32(vmulq_s32(lanes3, factor), shift))
        withMutableSubspan(of: &bytes, offset..<offset &+ 64) { block in
            let pixels0 = block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self)
            block.storeBytes(of: vqtbx1q_u8(pixels0, averages0, indices), toByteOffset: 0, as: SIMD16<UInt8>.self)
            let pixels1 = block.load(fromByteOffset: 16, as: SIMD16<UInt8>.self)
            block.storeBytes(of: vqtbx1q_u8(pixels1, averages1, indices), toByteOffset: 16, as: SIMD16<UInt8>.self)
            let pixels2 = block.load(fromByteOffset: 32, as: SIMD16<UInt8>.self)
            block.storeBytes(of: vqtbx1q_u8(pixels2, averages2, indices), toByteOffset: 32, as: SIMD16<UInt8>.self)
            let pixels3 = block.load(fromByteOffset: 48, as: SIMD16<UInt8>.self)
            block.storeBytes(of: vqtbx1q_u8(pixels3, averages3, indices), toByteOffset: 48, as: SIMD16<UInt8>.self)
        }
    }
}

// For ShadowBlurLanes(_:_:_:): the channel's byte of each of 4 pixels, then three zeroes.
@inline(__always)
private func shadowBlurReadIndices(_ channel: Int) -> SIMD16<UInt8> {
    let first = UInt8(truncatingIfNeeded: channel)
    var indices = SIMD16<UInt8>(repeating: 255)
    indices[0] = first
    indices[4] = first &+ 4
    indices[8] = first &+ 8
    indices[12] = first &+ 12
    return indices
}

// For storeAverage(_:_:_:_:): each lane's low byte at the channel of its pixel; out of range elsewhere, which keeps the
// byte in memory.
@inline(__always)
private func shadowBlurWriteIndices(_ channel: Int) -> SIMD16<UInt8> {
    var indices = SIMD16<UInt8>(repeating: 255)
    indices[channel] = 0
    indices[channel &+ 4] = 4
    indices[channel &+ 8] = 8
    indices[channel &+ 12] = 12
    return indices
}

// The same step as shadowBlurLine(), on the 16 columns from `offset` (a byte offset in the first row), row by row: every
// row they read or write is one 64-byte block. The columns must have the same loop counts.
@inline(__always)
private func shadowBlurColumns(
    _ bytes: inout MutableRawSpan,
    _ offset: Int,
    _ rowStride: Int,
    _ readIndices: SIMD16<UInt8>,
    _ writeIndices: SIMD16<UInt8>,
    _ side1: Int32,
    _ side2: Int32,
    _ dim: Int,
    _ counts: ShadowBlurLineCounts
) {
    let invCount = shadowBlurReciprocal(side1 &+ 1 &+ side2)
    let alpha1 = ShadowBlurLanes(bytes, offset, readIndices)
    let alpha2 = ShadowBlurLanes(bytes, offset &+ (dim &- 1) &* rowStride, readIndices)

    var sum = alpha1 &* (side1 &+ 1)
    var first = offset &+ rowStride
    var k = 0
    while k < counts.first {
        sum = sum &+ ShadowBlurLanes(bytes, first, readIndices)
        first &+= rowStride
        k &+= 1
    }
    if dim <= Int(side2) {
        sum = sum &+ alpha2 &* (side2 &- Int32(truncatingIfNeeded: dim) &+ 1)
    }

    // The three output loops of shadowBlurLine() in one: each adds the pixel entering the box, or alpha2, and removes
    // the one leaving it, or alpha1.
    let nextCount = counts.second &+ counts.third
    let total = nextCount &+ counts.fourth
    var output = offset
    var ofs = Int(side2) &+ 1
    var next = offset &+ ofs &* rowStride
    var previous = offset
    k = 0
    while k < total {
        sum.storeAverage(&bytes, output, invCount, writeIndices)
        let entering = k < nextCount && ofs < dim ? ShadowBlurLanes(bytes, next, readIndices) : alpha2
        let leaving = k < counts.second ? alpha1 : ShadowBlurLanes(bytes, previous, readIndices)
        sum = sum &+ entering &- leaving
        output &+= rowStride
        if k < nextCount {
            next &+= rowStride
            ofs &+= 1
        }
        if k >= counts.second {
            previous &+= rowStride
        }
        k &+= 1
    }
}

#endif // arch(arm64)

// The blur of `height` rows of `width` pixels with no padding. Each line runs the literal form's loops with the counts
// its span checks allow, computed in advance, so it writes the same bytes. The vertical pass runs one step at a time
// over all columns, 16 columns at a time where it can; that changes nothing, because columns don't share bytes and a step
// doesn't write the channel it reads.
private func shadowBlurRows(
    _ bytes: inout MutableRawSpan,
    _ width: Int,
    _ height: Int,
    _ radiusWidth: Float,
    _ radiusHeight: Float,
    _ shadowsIgnoreTransforms: Bool
) {
    let rowStride = 4 &* width
    let total = bytes.byteCount
    var lobes = shadowBlurLobes(radiusWidth, shadowsIgnoreTransforms)

    if radiusWidth != 0 {
        var row = 0
        while row < height {
            let base = row &* rowStride
            var step = 0
            while step < 3 {
                let channel = shadowBlurChannel(step)
                let nextChannel = shadowBlurChannel(step &+ 1)
                let side1 = lobes.leftLobe(step)
                let side2 = lobes.rightLobe(step)
                let counts = shadowBlurLineCounts(total &- base, 4, channel, nextChannel, Int(side1), Int(side2), width)
                shadowBlurLine(&bytes, base, 4, channel, nextChannel, side1, side2, width, counts)
                step &+= 1
            }
            row &+= 1
        }
    }

    if radiusHeight == 0 {
        return
    }

    if radiusWidth != radiusHeight {
        lobes = shadowBlurLobes(radiusHeight, shadowsIgnoreTransforms)
    }

    var step = 0
    while step < 3 {
        let channel = shadowBlurChannel(step)
        let nextChannel = shadowBlurChannel(step &+ 1)
        let side1 = lobes.leftLobe(step)
        let side2 = lobes.rightLobe(step)
        // Columns differ from each other by less than a row, so their counts only depend on whether a span of the step
        // starts at the image's first byte: every column but the first has the second's.
        let firstCounts = shadowBlurLineCounts(total, rowStride, channel, nextChannel, Int(side1), Int(side2), height)
        let counts =
            width > 1
            ? shadowBlurLineCounts(total &- 4, rowStride, channel, nextChannel, Int(side1), Int(side2), height) : firstCounts
        var column = 0
        if firstCounts != counts {
            shadowBlurLine(&bytes, 0, rowStride, channel, nextChannel, side1, side2, height, firstCounts)
            column = 1
        }
        #if arch(arm64)
        if width &- column >= 16 {
            let readIndices = shadowBlurReadIndices(channel)
            let writeIndices = shadowBlurWriteIndices(nextChannel)
            // The last block can overlap the one before it: running a column twice in a step writes the same bytes.
            while column < width {
                let first = min(column, width &- 16)
                shadowBlurColumns(&bytes, 4 &* first, rowStride, readIndices, writeIndices, side1, side2, height, counts)
                column &+= 16
            }
        }
        #endif
        while column < width {
            shadowBlurLine(&bytes, 4 &* column, rowStride, channel, nextChannel, side1, side2, height, counts)
            column &+= 1
        }
        step &+= 1
    }
}

#endif // ENABLE_WEBCORE_SWIFT
