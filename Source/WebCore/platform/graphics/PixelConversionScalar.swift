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

// The conversion loop of ports without Accelerate. Both formats are 8 bits per component and 4 bytes per pixel, with
// the alpha (or the ignored component in its place) in the last byte.

// Same as vImagePremultiplyData_ARGB8888: (src * alpha + 127) / 255
@inline(__always)
private func premultiply(_ component: UInt8, _ alpha: UInt8) -> UInt8 {
    UInt8(truncatingIfNeeded: (UInt32(component) &* UInt32(alpha) &+ 127) / 255)
}

// Same as vImageUnpremultiplyData_RGBA8888: (MIN(src_color, alpha) * 255 + alpha/2) / alpha
@inline(__always)
private func unpremultiply(_ component: UInt8, _ alpha: UInt8) -> UInt8 {
    UInt8(truncatingIfNeeded: (UInt32(min(component, alpha)) &* 255 &+ UInt32(alpha / 2)) / UInt32(alpha))
}

@inline(__always)
private func convertPixel(
    _ pixel: SIMD4<UInt8>,
    from sourceAlphaFormat: ConversionAlphaFormat,
    to destinationAlphaFormat: ConversionAlphaFormat,
    swapComponentOrder: Bool
) -> SIMD4<UInt8> {
    let alpha = sourceAlphaFormat == .opaque ? 255 : pixel[3]
    var components = SIMD3(pixel[0], pixel[1], pixel[2])
    switch (sourceAlphaFormat.isAlphaApplied, destinationAlphaFormat.isAlphaApplied) {
    case (false, false):
        break
    case (true, true):
        if alpha == 0 {
            components = .zero
        }
    case (true, false):
        if alpha == 0 {
            components = .zero
        } else if alpha != 255 {
            components = SIMD3(
                unpremultiply(components[0], alpha),
                unpremultiply(components[1], alpha),
                unpremultiply(components[2], alpha)
            )
        }
    case (false, true):
        if alpha == 0 {
            components = .zero
        } else if alpha != 255 {
            components = SIMD3(premultiply(components[0], alpha), premultiply(components[1], alpha), premultiply(components[2], alpha))
        }
    }
    if swapComponentOrder {
        components = SIMD3(components[2], components[1], components[0])
    }
    // An opaque destination gets 255 in place of alpha, which holds no meaningful value in an opaque source.
    return SIMD4(components, destinationAlphaFormat == .opaque ? 255 : alpha)
}

// The caller has checked that `height` rows of `width` pixels are inside both spans.
func convertPixelsUnaccelerated(
    source: RawSpan?,
    sourceBytesPerRow: Int,
    sourceAlphaFormat: ConversionAlphaFormat,
    destination: inout MutableRawSpan,
    destinationBytesPerRow: Int,
    destinationAlphaFormat: ConversionAlphaFormat,
    swapComponentOrder: Bool,
    width: Int,
    height: Int
) {
    let rowBytes = width &* 4
    for y in 0..<height {
        let sourceRowStart = y &* sourceBytesPerRow
        let destinationRowStart = y &* destinationBytesPerRow
        var x = 0
        while x < rowBytes {
            let pixel = loadPixelBytes(source, destination, at: sourceRowStart &+ x, as: SIMD4<UInt8>.self)
            let converted = convertPixel(
                pixel,
                from: sourceAlphaFormat,
                to: destinationAlphaFormat,
                swapComponentOrder: swapComponentOrder
            )
            destination.storeBytes(of: converted, toByteOffset: destinationRowStart &+ x, as: SIMD4<UInt8>.self)
            x &+= 4
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT
