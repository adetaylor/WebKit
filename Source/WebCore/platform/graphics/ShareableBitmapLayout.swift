// Copyright (C) 2010-2026 Apple Inc. All rights reserved.
// Copyright (C) 2011 Brent Fulgham <bfulgham@webkit.org>
// Copyright (C) 2011 Igalia S.L.
// Copyright (C) 2024 Igalia S.L.
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

#if USE_CG
import CoreGraphics
#endif
// The safe Span overloads Swift synthesizes for the byte views' accessors call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.PixelBufferSwiftBridge
import WebCore_Private.Core.PixelFormat
import WebCore_Private.Core.ShareableBitmapSwiftBridge

// ShareableBitmapCheckedSize mirrors a C++ CheckedUint32, including the value an overflowed one holds, which
// ShareableBitmapConfiguration's accessors return.
extension WebCore.ShareableBitmapCheckedSize {
    fileprivate static var overflowed: Self { Self(value: 0, hasOverflowed: true) }

    // CheckedUint32(value): overflowed, holding the truncated value, when value isn't in 0...UInt32.max.
    fileprivate init(converting value: some BinaryInteger) {
        self.init(value: UInt32(truncatingIfNeeded: value), hasOverflowed: UInt32(exactly: value) == nil)
    }

    // The CheckedUint32 product of this and an int: overflowed, holding 0, when this has overflowed or the exact
    // product isn't in 0...UInt32.max.
    fileprivate func multiplied(by factor: Int32) -> Self {
        guard !hasOverflowed else {
            return .overflowed
        }
        let (product, overflow) = Int64(value).multipliedReportingOverflow(by: Int64(factor))
        guard !overflow, let result = UInt32(exactly: product) else {
            return .overflowed
        }
        return Self(value: result, hasOverflowed: false)
    }
}

private func resolvedPixelFormat(_ request: WebCore.ShareableBitmapLayoutRequest) -> WebCore.PixelFormat {
    if request.hasPixelFormat {
        return request.pixelFormat
    }
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    if request.colorSpaceUsesExtendedRange {
        return .RGBA16F
    }
    #endif
    return .RGBA8
}

private func bytesPerPixel(_ pixelFormat: WebCore.PixelFormat) -> UInt32 {
    #if USE_CG
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    if pixelFormat == .RGBA16F {
        return 8
    }
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    if pixelFormat == .RGBA16 {
        return 8
    }
    #endif
    return 4
    #elseif USE_SKIA || USE_CAIRO
    // Skia bitmaps are kN32_SkColorType and Cairo ones CAIRO_FORMAT_ARGB32, whatever the pixel format.
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    precondition(pixelFormat != .RGBA16F)
    #endif
    return 4
    #else
    #error("ShareableBitmap needs a graphics library")
    #endif
}

// IOSurface::bytesPerRowAlignment() rounding, in size_t. Traps if the size_t sum overflows, which only alignments
// near 2^64 make it do.
private func aligned(_ bytesPerRow: UInt32, to alignment: Int) -> WebCore.ShareableBitmapCheckedSize {
    let mask = UInt(bitPattern: alignment) &- 1
    let (sum, overflow) = UInt(bytesPerRow).addingReportingOverflow(mask)
    precondition(!overflow)
    return WebCore.ShareableBitmapCheckedSize(converting: sum & ~mask)
}

// SkImageInfo::MakeN32Premul(width, height).minRowBytes(): 4 * width, or 0 when that isn't in 0...Int32.max.
private func skiaN32MinRowBytes(width: Int32) -> UInt32 {
    let rowBytes = Int64(width) * 4
    guard rowBytes >= 0, rowBytes <= Int64(Int32.max) else {
        return 0
    }
    return UInt32(rowBytes)
}

// cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width): 4 * width, or -1 for the widths cairo refuses,
// (unsigned)width >= (INT32_MAX - 7) / 32.
private func cairoARGB32Stride(width: Int32) -> Int32 {
    guard UInt32(bitPattern: width) < UInt32((Int32.max - 7) / 32) else {
        return -1
    }
    return width * 4
}

private func bytesPerRow(width: Int32, bytesPerPixel: UInt32, alignment: Int) -> WebCore.ShareableBitmapCheckedSize {
    #if USE_CG
    let bytesPerRow = WebCore.ShareableBitmapCheckedSize(value: bytesPerPixel, hasOverflowed: false).multiplied(by: width)
    #if HAVE_IOSURFACE
    if bytesPerRow.hasOverflowed {
        return bytesPerRow
    }
    return aligned(bytesPerRow.value, to: alignment)
    #else
    return bytesPerRow
    #endif
    #elseif USE_SKIA
    return WebCore.ShareableBitmapCheckedSize(value: skiaN32MinRowBytes(width: width), hasOverflowed: false)
    #elseif USE_CAIRO
    return WebCore.ShareableBitmapCheckedSize(converting: cairoARGB32Stride(width: width))
    #endif
}

#if USE_CG
private func bitmapInfo(_ pixelFormat: WebCore.PixelFormat, isOpaque: Bool) -> UInt32 {
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    if pixelFormat == .RGBA16F {
        let alpha: CGImageAlphaInfo = isOpaque ? .noneSkipLast : .premultipliedLast
        return CGImageComponentInfo.float.rawValue | CGImageByteOrderInfo.order16Host.rawValue | alpha.rawValue
    }
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    if pixelFormat == .RGBA16 {
        let alpha: CGImageAlphaInfo = isOpaque ? .noneSkipLast : .premultipliedLast
        return CGImageByteOrderInfo.order16Little.rawValue | alpha.rawValue
    }
    #endif
    let alpha: CGImageAlphaInfo = isOpaque ? .noneSkipFirst : .premultipliedFirst
    return CGImageByteOrderInfo.order32Host.rawValue | alpha.rawValue
}
#endif

@_expose(Cxx)
func shareableBitmapLayout(_ request: WebCore.ShareableBitmapLayoutRequest) -> WebCore.ShareableBitmapLayout {
    let pixelFormat = resolvedPixelFormat(request)
    let bytesPerPixel = bytesPerPixel(pixelFormat)
    #if USE_CG
    let bitmapInfo = bitmapInfo(pixelFormat, isOpaque: request.isOpaque)
    #else
    let bitmapInfo: UInt32 = 0
    #endif
    return WebCore.ShareableBitmapLayout(
        pixelFormat: pixelFormat,
        bitsPerComponent: bytesPerPixel / 4 * 8,
        bytesPerPixel: bytesPerPixel,
        bytesPerRow: bytesPerRow(width: request.width, bytesPerPixel: bytesPerPixel, alignment: request.bytesPerRowAlignment),
        bitmapInfo: bitmapInfo
    )
}

@_expose(Cxx)
func shareableBitmapSizeInBytes(_ geometry: WebCore.ShareableBitmapGeometry) -> WebCore.ShareableBitmapCheckedSize {
    geometry.bytesPerRow.multiplied(by: geometry.height)
}

// Whether shared memory of memoryByteCount bytes holds a bitmap of this geometry.
@_expose(Cxx)
func shareableBitmapFitsInMemory(_ geometry: WebCore.ShareableBitmapGeometry, memoryByteCount: Int) -> Bool {
    let sizeInBytes = shareableBitmapSizeInBytes(geometry)
    return !sizeInBytes.hasOverflowed && UInt(bitPattern: memoryByteCount) >= UInt(sizeInBytes.value)
}

// Whether createFromImagePixels can copy byteCount bytes of image data into a bitmap of this geometry.
@_expose(Cxx)
func shareableBitmapCheckImagePixels(_ geometry: WebCore.ShareableBitmapGeometry, byteCount: Int) -> WebCore.ShareableBitmapImagePixels {
    let count = UInt(bitPattern: byteCount)
    guard count > 0, count <= UInt(UInt32.max) else {
        return .Unusable
    }
    let sizeInBytes = shareableBitmapSizeInBytes(geometry)
    precondition(!sizeInBytes.hasOverflowed)
    return UInt(sizeInBytes.value) == count ? .Copyable : .SizeMismatch
}

@_expose(Cxx)
func shareableBitmapCopyImagePixels(_ source: borrowing WebCore.PixelBytes, _ destination: inout WebCore.MutablePixelBytes) {
    let sourceSpan: Span<UInt8> = source.span()
    var destinationSpan: MutableSpan<UInt8> = destination.mutableSpan()
    // Traps if the destination is shorter than the source.
    copyBytes(from: sourceSpan, at: 0, to: &destinationSpan, at: 0, count: sourceSpan.count)
}

#if USE_CAIRO
// The stride of a CAIRO_FORMAT_ARGB32 surface over byteCount bytes, or -1, which makes cairo create an error surface,
// when the surface doesn't fit.
@_expose(Cxx)
func shareableBitmapCairoSurfaceStride(width: Int32, height: Int32, byteCount: Int) -> Int32 {
    let stride = cairoARGB32Stride(width: width)
    guard stride >= 0, height >= 0 else {
        return -1
    }
    let required = UInt64(stride) * UInt64(height)
    guard required <= UInt64(UInt(bitPattern: byteCount)) else {
        return -1
    }
    return stride
}
#endif

#endif // ENABLE_WEBCORE_SWIFT
