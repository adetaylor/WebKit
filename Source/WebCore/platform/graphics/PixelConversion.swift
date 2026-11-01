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

#if USE_SKIA
private import Cxx
import WebCore_Internal.PixelBufferConversion
#endif
import WebCore_Internal.AlphaPremultiplication
import WebCore_Internal.ColorSpace
import WebCore_Internal.IntSize
import WebCore_Internal.PixelBuffer
import WebCore_Internal.PixelBufferFormat
import WebCore_Internal.PixelFormat

// Pixel format conversion of images in byte spans, whose consecutive rows start `bytesPerRow` apart. C++ reaches it
// through convertImagePixels() and copyRows() (PixelBufferConversion.h).
enum PixelConversion {
    // Converts the top-left `size` pixels of the source image into the destination image. The source and the
    // destination must not overlap. Like convertImagePixels(), traps if either span is too small for `size`, and
    // zero-fills the destination pixels if it can't convert (an unsupported format, or a vImage failure).
    static func convert(
        source: Span<UInt8>,
        sourceFormat: borrowing WebCore.PixelBufferFormat,
        sourceBytesPerRow: Int,
        destination: inout MutableSpan<UInt8>,
        destinationFormat: borrowing WebCore.PixelBufferFormat,
        destinationBytesPerRow: Int,
        size: WebCore.IntSize
    ) {
        convertPixels(
            source: source,
            sourceFormat: sourceFormat,
            sourceBytesPerRow: sourceBytesPerRow,
            destination: &destination,
            destinationFormat: destinationFormat,
            destinationBytesPerRow: destinationBytesPerRow,
            width: Int(size.width()),
            height: Int(size.height())
        )
    }

    static func convert(
        source: Span<UInt8>,
        sourceFormat: borrowing WebCore.PixelBufferFormat,
        sourceBytesPerRow: Int,
        destination: inout MutableSpan<UInt8>,
        destinationFormat: borrowing WebCore.PixelBufferFormat,
        destinationBytesPerRow: Int,
        width: Int,
        height: Int
    ) {
        convertPixels(
            source: source,
            sourceFormat: sourceFormat,
            sourceBytesPerRow: sourceBytesPerRow,
            destination: &destination,
            destinationFormat: destinationFormat,
            destinationBytesPerRow: destinationBytesPerRow,
            width: width,
            height: height
        )
    }

    // Converts an image in place, from one format to another with the same bytes per pixel.
    static func convertInPlace(
        _ bytes: inout MutableSpan<UInt8>,
        bytesPerRow: Int,
        from sourceFormat: borrowing WebCore.PixelBufferFormat,
        to destinationFormat: borrowing WebCore.PixelBufferFormat,
        size: WebCore.IntSize
    ) {
        convertPixels(
            source: nil,
            sourceFormat: sourceFormat,
            sourceBytesPerRow: bytesPerRow,
            destination: &bytes,
            destinationFormat: destinationFormat,
            destinationBytesPerRow: bytesPerRow,
            width: Int(size.width()),
            height: Int(size.height())
        )
    }

    static func convertInPlace(
        _ bytes: inout MutableSpan<UInt8>,
        bytesPerRow: Int,
        from sourceFormat: borrowing WebCore.PixelBufferFormat,
        to destinationFormat: borrowing WebCore.PixelBufferFormat,
        width: Int,
        height: Int
    ) {
        convertPixels(
            source: nil,
            sourceFormat: sourceFormat,
            sourceBytesPerRow: bytesPerRow,
            destination: &bytes,
            destinationFormat: destinationFormat,
            destinationBytesPerRow: bytesPerRow,
            width: width,
            height: height
        )
    }

    // Copies `rows` rows of `rowBytes` bytes. False, with nothing copied, if they aren't all inside the spans, or if
    // consecutive rows overlap. The source and the destination must not overlap.
    static func copyRows(
        source: Span<UInt8>,
        sourceBytesPerRow: Int,
        destination: inout MutableSpan<UInt8>,
        destinationBytesPerRow: Int,
        rows: Int,
        rowBytes: Int
    ) -> Bool {
        guard rows >= 0, rowBytes >= 0 else {
            return false
        }
        if rows == 0 || rowBytes == 0 {
            return true
        }
        guard rows == 1 || (sourceBytesPerRow >= rowBytes && destinationBytesPerRow >= rowBytes),
            let sourceBytes = requiredByteCount(rows: rows, rowBytes: rowBytes, bytesPerRow: sourceBytesPerRow),
            sourceBytes <= source.count,
            let destinationBytes = requiredByteCount(rows: rows, rowBytes: rowBytes, bytesPerRow: destinationBytesPerRow),
            destinationBytes <= destination.count
        else {
            return false
        }
        copyValidatedRows(
            source: source,
            sourceBytesPerRow: sourceBytesPerRow,
            destination: &destination,
            destinationBytesPerRow: destinationBytesPerRow,
            rows: rows,
            rowBytes: rowBytes
        )
        return true
    }

    // Zeroes `rows` rows of `rowBytes` bytes. False, with nothing zeroed, if they aren't all inside the span.
    static func zeroRows(_ bytes: inout MutableSpan<UInt8>, bytesPerRow: Int, rows: Int, rowBytes: Int) -> Bool {
        guard rows >= 0, rowBytes >= 0, let requiredBytes = requiredByteCount(rows: rows, rowBytes: rowBytes, bytesPerRow: bytesPerRow),
            requiredBytes <= bytes.count
        else {
            return false
        }
        zeroValidatedRows(&bytes, bytesPerRow: bytesPerRow, rows: rows, rowBytes: rowBytes)
        return true
    }
}

enum ConversionAlphaFormat {
    case opaque
    case unpremultiplied
    case premultiplied

    // Whether the color components already have the alpha applied to them.
    var isAlphaApplied: Bool {
        self != .unpremultiplied
    }
}

private func isSupportedConversionFormat(_ pixelFormat: WebCore.PixelFormat) -> Bool {
    switch pixelFormat {
    case .RGBX8, .RGBA8, .BGRX8, .BGRA8:
        return true
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .RGBA16F:
        return true
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case .RGBA16:
        return true
    #endif
    default:
        return false
    }
}

// What the conversion needs to know about a format, looked up once per conversion: PixelFormat.h's pixelFormatIsOpaque()
// and pixelComponentOrder() and PixelBuffer.h's bytesPerPixelComponent(), for every format.
private struct PixelFormatTraits {
    let pixelFormat: WebCore.PixelFormat
    let alphaFormat: ConversionAlphaFormat
    let bytesPerPixel: Int
    let bytesPerComponent: Int
    let componentOrder: WebCore.PixelComponentOrder
    let isSupported: Bool

    @inline(__always)
    init(_ format: borrowing WebCore.PixelBufferFormat) {
        pixelFormat = format.pixelFormat
        let isOpaque: Bool
        switch pixelFormat {
        case .RGBX8:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (true, 1, .RGB, true)
        case .RGBA8:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (false, 1, .RGB, true)
        case .BGRX8:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (true, 1, .BGR, true)
        case .BGRA8:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (false, 1, .BGR, true)
        #if ENABLE_PIXEL_FORMAT_RGBA16F
        case .RGBA16F:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (false, 2, .RGB, true)
        #endif
        #if ENABLE_PIXEL_FORMAT_RGBA16
        case .RGBA16:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (false, 2, .RGB, true)
        #endif
        #if ENABLE_PIXEL_FORMAT_RGB10
        case .RGB10:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (true, 1, .RGB, false)
        #endif
        #if ENABLE_PIXEL_FORMAT_RGB10A8
        case .RGB10A8:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (false, 1, .RGB, false)
        #endif
        @unknown default:
            (isOpaque, bytesPerComponent, componentOrder, isSupported) = (false, 1, .RGB, false)
        }
        bytesPerPixel = 4 &* bytesPerComponent
        alphaFormat = isOpaque ? .opaque : (format.alphaFormat == .Premultiplied ? .premultiplied : .unpremultiplied)
        assert(isSupported == isSupportedConversionFormat(pixelFormat))
    }
}

// The rows the conversion reads and writes have to be inside the buffer the view describes.
private func hasEnoughBytesForConversion(byteCount: Int, bytesPerRow: Int, bytesPerPixel: Int, width: Int, height: Int) -> Bool {
    guard bytesPerRow >= 0, let rowBytes = width.checkedMultiplied(by: bytesPerPixel),
        let requiredBytes = requiredByteCount(rows: height, rowBytes: rowBytes, bytesPerRow: bytesPerRow)
    else {
        return false
    }
    return requiredBytes <= byteCount
}

// Whether the contents can be copied verbatim, i.e. the two formats store the same components at
// the same offsets, and the components already relate to the alpha the way the destination
// describes. An opaque destination drops the alpha of the source, which gives the right color only
// if the source has applied it to its color components already.
private func canCopyPixels(
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    _ source: PixelFormatTraits,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ destination: PixelFormatTraits
) -> Bool {
    #if USE_SKIA
    // Skia has no native BGRX color type, so the component a BGRX8 destination has in place of
    // alpha is not ignored. Only contents that are opaque themselves can be copied into it.
    if destination.pixelFormat == .BGRX8 && source.alphaFormat != .opaque {
        return false
    }
    #endif
    guard source.bytesPerComponent == destination.bytesPerComponent, source.componentOrder == destination.componentOrder,
        source.alphaFormat == destination.alphaFormat || (source.alphaFormat == .premultiplied && destination.alphaFormat == .opaque)
    else {
        return false
    }
    return sourceFormat.colorSpace == destinationFormat.colorSpace
}

private func copyValidatedRows(
    source: Span<UInt8>,
    sourceBytesPerRow: Int,
    destination: inout MutableSpan<UInt8>,
    destinationBytesPerRow: Int,
    rows: Int,
    rowBytes: Int
) {
    if sourceBytesPerRow == rowBytes && destinationBytesPerRow == rowBytes {
        copyBytes(from: source, at: 0, to: &destination, at: 0, count: rows &* rowBytes)
        return
    }
    for row in 0..<rows {
        copyBytes(from: source, at: row &* sourceBytesPerRow, to: &destination, at: row &* destinationBytesPerRow, count: rowBytes)
    }
}

private func zeroValidatedRows(_ bytes: inout MutableSpan<UInt8>, bytesPerRow: Int, rows: Int, rowBytes: Int) {
    if bytesPerRow == rowBytes {
        withMutableSubspan(of: &bytes, 0..<rows &* rowBytes) { $0.update(repeating: 0) }
        return
    }
    for row in 0..<rows {
        let start = row &* bytesPerRow
        withMutableSubspan(of: &bytes, start..<start &+ rowBytes) { $0.update(repeating: 0) }
    }
}

// convertImagePixels(): a nil source means that the destination also holds the source, with the source format.
private func convertPixels(
    source: Span<UInt8>?,
    sourceFormat: borrowing WebCore.PixelBufferFormat,
    sourceBytesPerRow: Int,
    destination: inout MutableSpan<UInt8>,
    destinationFormat: borrowing WebCore.PixelBufferFormat,
    destinationBytesPerRow: Int,
    width: Int,
    height: Int
) {
    // Empty and negative sizes convert nothing.
    guard width > 0, height > 0 else {
        return
    }

    // We currently only support converting between RGBA8, BGRA8, RGBX8, BGRX8, and (where enabled) RGBA16F and RGBA16.
    let sourceTraits = PixelFormatTraits(sourceFormat)
    let destinationTraits = PixelFormatTraits(destinationFormat)
    assert(sourceTraits.isSupported)
    assert(destinationTraits.isSupported)
    precondition(source != nil || sourceTraits.bytesPerPixel == destinationTraits.bytesPerPixel)

    let sourceByteCount = source?.count ?? destination.count
    precondition(
        hasEnoughBytesForConversion(
            byteCount: sourceByteCount,
            bytesPerRow: sourceBytesPerRow,
            bytesPerPixel: sourceTraits.bytesPerPixel,
            width: width,
            height: height
        ),
        "Source buffer is too small for the requested conversion"
    )
    precondition(
        hasEnoughBytesForConversion(
            byteCount: destination.count,
            bytesPerRow: destinationBytesPerRow,
            bytesPerPixel: destinationTraits.bytesPerPixel,
            width: width,
            height: height
        ),
        "Destination buffer is too small for the requested conversion"
    )

    let destinationRowBytes = width &* destinationTraits.bytesPerPixel
    if sourceTraits.isSupported && destinationTraits.isSupported {
        if canCopyPixels(sourceFormat, sourceTraits, destinationFormat, destinationTraits) {
            // In place, the source rows are the destination rows.
            if let source {
                copyValidatedRows(
                    source: source,
                    sourceBytesPerRow: sourceBytesPerRow,
                    destination: &destination,
                    destinationBytesPerRow: destinationBytesPerRow,
                    rows: height,
                    rowBytes: destinationRowBytes
                )
            }
            return
        }

        let image = ConversionImage(
            width: width,
            height: height,
            sourceBytesPerRow: sourceBytesPerRow,
            sourceByteCount: sourceByteCount,
            source: sourceTraits,
            destinationBytesPerRow: destinationBytesPerRow,
            destination: destinationTraits
        )
        if platformConvertPixels(source: source, sourceFormat, destination: &destination, destinationFormat, image) {
            return
        }
    }

    zeroValidatedRows(&destination, bytesPerRow: destinationBytesPerRow, rows: height, rowBytes: destinationRowBytes)
}

// A conversion whose spans have been checked to hold the source and destination rows.
private struct ConversionImage {
    let width: Int
    let height: Int
    let sourceBytesPerRow: Int
    let sourceByteCount: Int
    let source: PixelFormatTraits
    let destinationBytesPerRow: Int
    let destination: PixelFormatTraits
}

#if USE_ACCELERATE && USE_CG

// The common conversions are a few vImage calls on small images, so their path is inlined into one function.
@inline(__always)
private func platformConvertPixels(
    source: Span<UInt8>?,
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    destination: inout MutableSpan<UInt8>,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ image: ConversionImage
) -> Bool {
    guard
        let sourceGeometry = VImageGeometry(
            width: image.width,
            height: image.height,
            rowBytes: image.sourceBytesPerRow,
            bytesPerPixel: image.source.bytesPerPixel,
            byteCount: image.sourceByteCount
        ),
        let destinationGeometry = VImageGeometry(
            width: image.width,
            height: image.height,
            rowBytes: image.destinationBytesPerRow,
            bytesPerPixel: image.destination.bytesPerPixel,
            byteCount: destination.count
        )
    else {
        return false
    }

    if image.source.bytesPerComponent == image.destination.bytesPerComponent {
        // A borrowed value can't be read inside `&&`.
        if sourceFormat.colorSpace == destinationFormat.colorSpace {
            convertMatchingSize(
                source: source,
                sourceGeometry,
                destination: &destination,
                destinationGeometry,
                image
            )
            return true
        }
    }

    return vImageConvertAnyToAny(
        source: source,
        sourceFormat,
        sourceGeometry,
        destination: &destination,
        destinationFormat,
        destinationGeometry
    )
}

@inline(__always)
private func convertMatchingSize(
    source: Span<UInt8>?,
    _ sourceGeometry: VImageGeometry,
    destination: inout MutableSpan<UInt8>,
    _ destinationGeometry: VImageGeometry,
    _ image: ConversionImage
) {
    let swapComponentOrder = image.source.componentOrder != image.destination.componentOrder

    if image.source.alphaFormat == .opaque {
        // The component an opaque source has in place of alpha holds no meaningful value, so it must
        // not be carried over. Insert an opaque alpha and possibly reorder.
        vImagePermuteInsertingOpaqueAlpha(
            source: source,
            sourceGeometry,
            destination: &destination,
            destinationGeometry,
            swapComponentOrder: swapComponentOrder
        )
        return
    }

    var alphaConvertedIntoDestination = false
    if image.source.alphaFormat.isAlphaApplied != image.destination.alphaFormat.isAlphaApplied {
        let unpremultiply = !image.destination.alphaFormat.isAlphaApplied
        var converted = false
        #if arch(arm64)
        if image.source.bytesPerComponent == 1 {
            converted = convertSmallImageAlpha(
                unpremultiply: unpremultiply,
                source: source,
                sourceGeometry,
                destination: &destination,
                destinationGeometry
            )
        }
        #endif
        if !converted {
            vImageConvertAlpha(
                vImageAlphaLayout(image.source.pixelFormat),
                unpremultiply: unpremultiply,
                source: source,
                sourceGeometry,
                destination: &destination,
                destinationGeometry
            )
        }
        alphaConvertedIntoDestination = true
    }

    if swapComponentOrder {
        if alphaConvertedIntoDestination {
            vImageSwapFirstAndThirdComponents(source: nil, destinationGeometry, destination: &destination, destinationGeometry)
        } else {
            vImageSwapFirstAndThirdComponents(source: source, sourceGeometry, destination: &destination, destinationGeometry)
        }
    }
}

private func vImageAlphaLayout(_ pixelFormat: WebCore.PixelFormat) -> VImageAlphaLayout {
    switch pixelFormat {
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .RGBA16F:
        return .rgba16F
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case .RGBA16:
        return .rgba16U
    #endif
    default:
        assert(pixelFormat == .RGBA8 || pixelFormat == .BGRA8)
        return .alphaLast8888
    }
}

#if arch(arm64)
// Small images of 8-bit pixels in consecutive rows. False if the image isn't one.
private func convertSmallImageAlpha(
    unpremultiply: Bool,
    source: Span<UInt8>?,
    _ sourceGeometry: VImageGeometry,
    destination: inout MutableSpan<UInt8>,
    _ destinationGeometry: VImageGeometry
) -> Bool {
    let width = Int(sourceGeometry.width)
    let pixelCount = width &* Int(sourceGeometry.height)
    guard pixelCount <= 16384, width &* 4 == sourceGeometry.rowBytes, sourceGeometry.rowBytes == destinationGeometry.rowBytes else {
        return false
    }

    let byteCount = pixelCount &* 4
    if !unpremultiply {
        var destinationBytes = destination.mutableBytes
        premultiplyPixels(source?.bytes, &destinationBytes, byteCount: byteCount)
        return true
    }

    var destinationBytes = destination.mutableBytes
    let offset = unpremultiplyBinaryAlphaPixels(source?.bytes, &destinationBytes, byteCount: byteCount)
    guard offset != byteCount,
        let remainingGeometry = VImageGeometry(
            width: (byteCount &- offset) / 4,
            height: 1,
            rowBytes: byteCount &- offset,
            bytesPerPixel: 4,
            byteCount: byteCount &- offset
        )
    else {
        return true
    }
    withMutableSubspan(of: &destination, offset..<byteCount) { remainingDestination in
        vImageConvertAlpha(
            .alphaLast8888,
            unpremultiply: true,
            source: source?.extracting(offset..<byteCount),
            remainingGeometry,
            destination: &remainingDestination,
            remainingGeometry
        )
    }
    return true
}
#endif // arch(arm64)

#else // USE_ACCELERATE && USE_CG

private func platformConvertPixels(
    source: Span<UInt8>?,
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    destination: inout MutableSpan<UInt8>,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ image: ConversionImage
) -> Bool {
    #if USE_SKIA
    let size = WebCore.IntSize(Int32(image.width), Int32(image.height))
    let convertedBySkia =
        if let source {
            WebCore.convertImagePixelsSkia(
                sourceFormat,
                UInt32(image.sourceBytesPerRow),
                source,
                destinationFormat,
                UInt32(image.destinationBytesPerRow),
                &destination,
                size
            )
        } else {
            WebCore.convertImagePixelsSkiaInPlace(sourceFormat, destinationFormat, UInt32(image.destinationBytesPerRow), &destination, size)
        }
    if convertedBySkia {
        return true
    }
    #endif

    // FIXME: We don't currently support converting pixel data between different color spaces in the non-accelerated path.
    // This could be added using conversion functions from ColorConversion.h.
    guard sourceFormat.colorSpace == destinationFormat.colorSpace else {
        return false
    }

    // Without ACCELERATE and CG there are no 16-bits-per-component formats, so every supported format
    // is 8 bits per component and 4 bytes per pixel, which is what the conversion loop assumes.
    guard image.source.bytesPerPixel == 4, image.destination.bytesPerPixel == 4 else {
        return false
    }

    var destinationBytes = destination.mutableBytes
    convertPixelsUnaccelerated(
        source: source?.bytes,
        sourceBytesPerRow: image.sourceBytesPerRow,
        sourceAlphaFormat: image.source.alphaFormat,
        destination: &destinationBytes,
        destinationBytesPerRow: image.destinationBytesPerRow,
        destinationAlphaFormat: image.destination.alphaFormat,
        swapComponentOrder: image.source.componentOrder != image.destination.componentOrder,
        width: image.width,
        height: image.height
    )
    return true
}

#endif // USE_ACCELERATE && USE_CG

// copyRowsInternal(): rows `sourceBytesPerRow` and `destinationBytesPerRow` apart, possibly overlapping. Stops after
// the last row whose successor would start outside a span, and traps on a row that ends outside a span.
func copyRowsAsCopyRowsInternal(
    source: Span<UInt8>,
    sourceBytesPerRow: Int,
    destination: inout MutableSpan<UInt8>,
    destinationBytesPerRow: Int,
    rows: Int,
    rowBytes: Int
) {
    if sourceBytesPerRow == destinationBytesPerRow && rowBytes == sourceBytesPerRow {
        guard let count = rows.checkedMultiplied(by: rowBytes) else {
            preconditionFailure()
        }
        precondition(count <= source.count && count <= destination.count)
        copyBytes(from: source, at: 0, to: &destination, at: 0, count: count)
        return
    }
    var sourceOffset = 0
    var destinationOffset = 0
    for _ in 0..<rows {
        precondition(rowBytes <= source.count &- sourceOffset && rowBytes <= destination.count &- destinationOffset)
        copyBytes(from: source, at: sourceOffset, to: &destination, at: destinationOffset, count: rowBytes)
        if sourceBytesPerRow > source.count &- sourceOffset
            || destinationBytesPerRow > destination.count &- destinationOffset
        {
            break
        }
        sourceOffset &+= sourceBytesPerRow
        destinationOffset &+= destinationBytesPerRow
    }
}

#endif // ENABLE_WEBCORE_SWIFT
