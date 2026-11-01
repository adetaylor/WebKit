// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif

// Pixel loops over raw byte spans. Every SIMD load and store is bounds checked, once per vector. A nil source means
// that the destination also holds the source: the conversion is in place.

@inline(__always)
func loadPixelBytes<T: ConvertibleFromBytes>(
    _ source: RawSpan?,
    _ destination: borrowing MutableRawSpan,
    at offset: Int,
    as type: T.Type
) -> T {
    if let source {
        return source.load(fromByteOffset: offset, as: type)
    }
    return destination.load(fromByteOffset: offset, as: type)
}

// Copies the `count` bytes of `source` that start at `sourceOffset` to the `count` bytes of `destination` that start at
// `destinationOffset`, as memcpy does. Traps unless both ranges are inside their spans.
//
// This is the one bulk byte copy of WebCore's Swift, and its only `unsafe` one: the Swift standard library has no
// safe bulk copy into a MutableSpan, and safe loops run at 1.08-1.55x memcpy.
func copyBytes(
    from source: Span<UInt8>,
    at sourceOffset: Int,
    to destination: inout MutableSpan<UInt8>,
    at destinationOffset: Int,
    count: Int
) {
    // Every operand is non-negative before the subtractions, so they can't overflow.
    precondition(
        count >= 0 && sourceOffset >= 0 && destinationOffset >= 0 && count <= source.count &- sourceOffset
            && count <= destination.count &- destinationOffset
    )
    // An empty span can have no base address.
    if count == 0 {
        return
    }
    source.withUnsafeBytes { sourceBuffer in
        destination.withUnsafeMutableBytes { destinationBuffer in
            // Both ranges were checked above. copyMemory is memmove, so even overlapping spans would be copied correctly.
            unsafe destinationBuffer.baseAddress.unsafelyUnwrapped.advanced(by: destinationOffset)
                .copyMemory(
                    from: sourceBuffer.baseAddress.unsafelyUnwrapped.advanced(by: sourceOffset),
                    byteCount: count
                )
        }
    }
}

// Calls `body` with the bytes of `bytes` in `bounds`, as a MutableRawSpan of their own. Traps unless `bounds` is inside
// `bytes`. The Swift standard library has no stable way to take a mutable sub-span, so this forms one from the span's
// buffer pointer.
@inline(__always)
func withMutableSubspan<Result>(
    of bytes: inout MutableRawSpan,
    _ bounds: Range<Int>,
    _ body: (inout MutableRawSpan) -> Result
) -> Result {
    precondition(bounds.lowerBound >= 0 && bounds.upperBound <= bytes.byteCount)
    return bytes.withUnsafeMutableBytes { buffer in
        // `bounds` was checked above, so if it isn't empty, `buffer` has a base address. (Unwrapping it shows the compiler
        // that the sub-span holds bounds.count bytes.) The sub-span can't outlive this call.
        var subspan = unsafe UnsafeMutableRawBufferPointer(
            start: bounds.isEmpty
                ? buffer.baseAddress?.advanced(by: bounds.lowerBound)
                : buffer.baseAddress.unsafelyUnwrapped.advanced(by: bounds.lowerBound),
            count: bounds.count
        )
        .mutableBytes
        return body(&subspan)
    }
}

// The same for the elements of `span` in `bounds`.
@inline(__always)
func withMutableSubspan<Result>(
    of span: inout MutableSpan<UInt8>,
    _ bounds: Range<Int>,
    _ body: (inout MutableSpan<UInt8>) -> Result
) -> Result {
    var bytes = span.mutableBytes
    return withMutableSubspan(of: &bytes, bounds) { subspanBytes in
        var subspan = MutableSpan<UInt8>(mutating: &subspanBytes)
        return body(&subspan)
    }
}

#if arch(arm64)

// (c * a + 127) / 255 for 8 components, as vImagePremultiplyData_ARGB8888() computes it: with p = c * a + 128,
// (p + (p >> 8)) >> 8. The two are equal for every c and a.
@inline(__always)
private func premultiplyComponents(_ components: SIMD8<UInt8>, _ alpha: SIMD8<UInt8>) -> SIMD8<UInt8> {
    let product = vmlal_u8(vdupq_n_u16(128), components, alpha)
    return vaddhn_u16(product, vshlq_u16(product, vdupq_n_s16(-8)))
}

@inline(__always)
private func premultiplyComponents(_ components: SIMD16<UInt8>, _ alpha: SIMD16<UInt8>) -> SIMD16<UInt8> {
    vcombine_u8(
        premultiplyComponents(vget_low_u8(components), vget_low_u8(alpha)),
        premultiplyComponents(vget_high_u8(components), vget_high_u8(alpha))
    )
}

// 16 pixels, alpha in the last byte of each.
private typealias SixteenPixels = (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)

// Each block of 16 pixels is a 64-byte span, so the four loads and stores at constant offsets need no checks of
// their own. (Loading a SIMD64 and taking its quarters compiles to lane-by-lane moves.)
@inline(__always)
private func loadSixteenPixels(_ bytes: RawSpan) -> SixteenPixels {
    (
        bytes.load(fromByteOffset: 0, as: SIMD16<UInt8>.self), bytes.load(fromByteOffset: 16, as: SIMD16<UInt8>.self),
        bytes.load(fromByteOffset: 32, as: SIMD16<UInt8>.self), bytes.load(fromByteOffset: 48, as: SIMD16<UInt8>.self)
    )
}

@inline(__always)
private func loadSixteenPixels(_ bytes: borrowing MutableRawSpan) -> SixteenPixels {
    (
        bytes.load(fromByteOffset: 0, as: SIMD16<UInt8>.self), bytes.load(fromByteOffset: 16, as: SIMD16<UInt8>.self),
        bytes.load(fromByteOffset: 32, as: SIMD16<UInt8>.self), bytes.load(fromByteOffset: 48, as: SIMD16<UInt8>.self)
    )
}

@inline(__always)
private func storeSixteenPixels(_ pixels: SixteenPixels, _ bytes: inout MutableRawSpan) {
    bytes.storeBytes(of: pixels.0, toByteOffset: 0, as: SIMD16<UInt8>.self)
    bytes.storeBytes(of: pixels.1, toByteOffset: 16, as: SIMD16<UInt8>.self)
    bytes.storeBytes(of: pixels.2, toByteOffset: 32, as: SIMD16<UInt8>.self)
    bytes.storeBytes(of: pixels.3, toByteOffset: 48, as: SIMD16<UInt8>.self)
}

@inline(__always)
private func premultiply16Pixels(_ pixels: SixteenPixels) -> SixteenPixels {
    let even0 = vuzp1q_u8(pixels.0, pixels.1)
    let odd0 = vuzp2q_u8(pixels.0, pixels.1)
    let even1 = vuzp1q_u8(pixels.2, pixels.3)
    let odd1 = vuzp2q_u8(pixels.2, pixels.3)
    let alpha = vuzp2q_u8(odd0, odd1)
    let component0 = premultiplyComponents(vuzp1q_u8(even0, even1), alpha)
    let component1 = premultiplyComponents(vuzp1q_u8(odd0, odd1), alpha)
    let component2 = premultiplyComponents(vuzp2q_u8(even0, even1), alpha)
    let components02Low = vzip1q_u8(component0, component2)
    let components02High = vzip2q_u8(component0, component2)
    let components13Low = vzip1q_u8(component1, alpha)
    let components13High = vzip2q_u8(component1, alpha)
    return (
        vzip1q_u8(components02Low, components13Low), vzip2q_u8(components02Low, components13Low),
        vzip1q_u8(components02High, components13High), vzip2q_u8(components02High, components13High)
    )
}

@inline(__always)
private func premultiplyPixel(_ pixel: SIMD4<UInt8>) -> SIMD4<UInt8> {
    let alpha = UInt32(pixel[3])
    var result = SIMD4<UInt8>(truncatingIfNeeded: (SIMD4<UInt32>(truncatingIfNeeded: pixel) &* alpha &+ 127) / 255)
    result[3] = pixel[3]
    return result
}

// Premultiplies `byteCount / 4` consecutive 8-bit pixels whose alpha is in the last byte.
func premultiplyPixels(_ source: RawSpan?, _ destination: inout MutableRawSpan, byteCount: Int) {
    var offset = 0
    while offset &+ 64 <= byteCount {
        withMutableSubspan(of: &destination, offset..<offset &+ 64) { block in
            let pixels = if let source { loadSixteenPixels(source.extracting(offset..<offset &+ 64)) } else { loadSixteenPixels(block) }
            storeSixteenPixels(premultiply16Pixels(pixels), &block)
        }
        offset &+= 64
    }
    while offset &+ 4 <= byteCount {
        let pixel = loadPixelBytes(source, destination, at: offset, as: SIMD4<UInt8>.self)
        destination.storeBytes(of: premultiplyPixel(pixel), toByteOffset: offset, as: SIMD4<UInt8>.self)
        offset &+= 4
    }
}

// Unpremultiplies 16 consecutive 8-bit pixels (alpha in the last byte) at a time, for as long as every alpha is 0 or
// 255: that zeroes the color components or keeps them. Returns the offset of the first 16 pixels with another alpha,
// or of the last pixels when fewer than 16 remain; the caller unpremultiplies the rest.
func unpremultiplyBinaryAlphaPixels(_ source: RawSpan?, _ destination: inout MutableRawSpan, byteCount: Int) -> Int {
    let alphaIndices = SIMD16<UInt8>(3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15)
    var offset = 0
    while offset &+ 64 <= byteCount {
        let stored = withMutableSubspan(of: &destination, offset..<offset &+ 64) { block in
            let pixels = if let source { loadSixteenPixels(source.extracting(offset..<offset &+ 64)) } else { loadSixteenPixels(block) }
            let alpha = vuzp2q_u8(vuzp2q_u8(pixels.0, pixels.1), vuzp2q_u8(pixels.2, pixels.3))
            let binaryAlpha = vorrq_u8(vceqq_u8(alpha, vdupq_n_u8(0)), vceqq_u8(alpha, vdupq_n_u8(255)))
            if vminvq_u8(binaryAlpha) != 255 {
                return false
            }
            let result = (
                vandq_u8(pixels.0, vqtbl1q_u8(pixels.0, alphaIndices)), vandq_u8(pixels.1, vqtbl1q_u8(pixels.1, alphaIndices)),
                vandq_u8(pixels.2, vqtbl1q_u8(pixels.2, alphaIndices)), vandq_u8(pixels.3, vqtbl1q_u8(pixels.3, alphaIndices))
            )
            storeSixteenPixels(result, &block)
            return true
        }
        if !stored {
            break
        }
        offset &+= 64
    }
    return offset
}

#endif // arch(arm64)

#endif // ENABLE_WEBCORE_SWIFT
