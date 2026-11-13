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

// The safe Span overloads Swift synthesizes for the views' span accessors call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferFormat
import WebCore_Private.Core.PixelBufferSwiftBridge
import WebCore_Private.Core.PixelFormat

// The Swift side of ImageBufferBackend::getPixelBuffer(), putPixelBuffer() and convertToLuminanceMaskUint8()
// (ImageBufferBackend.cpp), which hand over views that don't overlap.

@_expose(Cxx)
func pixelTransferGetPixelBuffer(
    _ geometry: borrowing WebCore.PixelTransferGeometry,
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    _ source: borrowing WebCore.PixelBytes,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ destination: inout WebCore.MutablePixelBytes
) {
    let sourceBytes: Span<UInt8> = source.span()
    var destinationBytes: MutableSpan<UInt8> = destination.mutableSpan()
    PixelTransfer.get(
        geometry,
        source: sourceBytes,
        sourceFormat: sourceFormat,
        destination: &destinationBytes,
        destinationFormat: destinationFormat
    )
}

@_expose(Cxx)
func pixelTransferPutPixelBuffer(
    _ geometry: borrowing WebCore.PixelTransferGeometry,
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    _ source: borrowing WebCore.PixelBytes,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ destination: inout WebCore.MutablePixelBytes
) {
    let sourceBytes: Span<UInt8> = source.span()
    var destinationBytes: MutableSpan<UInt8> = destination.mutableSpan()
    PixelTransfer.put(
        geometry,
        source: sourceBytes,
        sourceFormat: sourceFormat,
        destination: &destinationBytes,
        destinationFormat: destinationFormat
    )
}

@_expose(Cxx)
func luminanceMaskApply(_ pixels: inout WebCore.MutablePixelBytes) {
    var bytes: MutableSpan<UInt8> = pixels.mutableSpan()
    LuminanceMask.apply(&bytes)
}

// Copies a rect of pixels between an ImageBufferBackend's bytes and a pixel buffer, clipped to both, converting the
// pixel format. The geometry can come from another process (RemoteImageBuffer), so the rect arithmetic wraps on
// overflow as IntRect's does, and every offset into the bytes is computed in Int and stays inside them.
enum PixelTransfer {
    // getPixelBuffer(): the source is the backend, and the destination a pixel buffer that holds the whole source rect,
    // with rows of the rect's width. Destination pixels outside the backend become zero.
    static func get(
        _ geometry: borrowing WebCore.PixelTransferGeometry,
        source: Span<UInt8>,
        sourceFormat: WebCore.PixelBufferFormat,
        destination: inout MutableSpan<UInt8>,
        destinationFormat: WebCore.PixelBufferFormat
    ) {
        let sourceRect = PixelTransferRect(
            x: geometry.sourceX,
            y: geometry.sourceY,
            width: geometry.sourceWidth,
            height: geometry.sourceHeight
        )
        let backendRect = PixelTransferRect(x: 0, y: 0, width: geometry.backendWidth, height: geometry.backendHeight)
        let sourceRectClipped = backendRect.intersection(sourceRect)
        let destinationX = sourceRect.x < 0 ? 0 &- sourceRect.x : 0
        let destinationY = sourceRect.y < 0 ? 0 &- sourceRect.y : 0

        if sourceRectClipped.width != sourceRect.width || sourceRectClipped.height != sourceRect.height {
            destination.update(repeating: 0)
        }

        let destinationBytesPerPixel = bytesPerPixel(destinationFormat.pixelFormat)
        let destinationBytesPerRow = bytesPerRow(width: sourceRect.width, bytesPerPixel: destinationBytesPerPixel)
        guard
            let destinationOffset = byteOffset(
                x: destinationX,
                y: destinationY,
                bytesPerRow: destinationBytesPerRow,
                bytesPerPixel: destinationBytesPerPixel
            ),
            destinationOffset >= 0, destinationOffset <= destination.count, !sourceRectClipped.isEmpty
        else {
            return
        }

        let sourceBytesPerPixel = bytesPerPixel(sourceFormat.pixelFormat)
        let sourceBytesPerRow = Int(geometry.backendBytesPerRow)
        let sourceOffset = offsetInside(
            source.count,
            x: sourceRectClipped.x,
            y: sourceRectClipped.y,
            bytesPerRow: sourceBytesPerRow,
            bytesPerPixel: sourceBytesPerPixel
        )
        withMutableSubspan(of: &destination, destinationOffset..<destination.count) { destinationRows in
            PixelConversion.convert(
                source: source.extracting(sourceOffset..<source.count),
                sourceFormat: sourceFormat,
                sourceBytesPerRow: sourceBytesPerRow,
                destination: &destinationRows,
                destinationFormat: destinationFormat,
                destinationBytesPerRow: destinationBytesPerRow,
                width: Int(sourceRectClipped.width),
                height: Int(sourceRectClipped.height)
            )
        }
    }

    // putPixelBuffer(): the source is a pixel buffer with rows of its width, the destination the backend.
    static func put(
        _ geometry: borrowing WebCore.PixelTransferGeometry,
        source: Span<UInt8>,
        sourceFormat: WebCore.PixelBufferFormat,
        destination: inout MutableSpan<UInt8>,
        destinationFormat: WebCore.PixelBufferFormat
    ) {
        let sourceRect = PixelTransferRect(
            x: geometry.sourceX,
            y: geometry.sourceY,
            width: geometry.sourceWidth,
            height: geometry.sourceHeight
        )
        let pixelBufferRect = PixelTransferRect(x: 0, y: 0, width: geometry.pixelBufferWidth, height: geometry.pixelBufferHeight)
        let backendRect = PixelTransferRect(x: 0, y: 0, width: geometry.backendWidth, height: geometry.backendHeight)
        let sourceRectClipped = pixelBufferRect.intersection(sourceRect)
        var destinationRect = sourceRectClipped
        destinationRect.x &+= geometry.destinationX
        destinationRect.y &+= geometry.destinationY
        if sourceRect.x < 0 {
            destinationRect.x &-= sourceRect.x
        }
        if sourceRect.y < 0 {
            destinationRect.y &-= sourceRect.y
        }
        let unclippedDestinationRect = destinationRect
        destinationRect = destinationRect.intersection(backendRect)
        guard !destinationRect.isEmpty else {
            return
        }

        // Clipping the destination on the left or top moves the source origin by as much. The move is less than the
        // clipped source rect's size, so the origin stays inside the pixel buffer.
        let sourceX = sourceRectClipped.x &+ (destinationRect.x &- unclippedDestinationRect.x)
        let sourceY = sourceRectClipped.y &+ (destinationRect.y &- unclippedDestinationRect.y)
        let sourceBytesPerPixel = bytesPerPixel(sourceFormat.pixelFormat)
        let sourceBytesPerRow = bytesPerRow(width: geometry.pixelBufferWidth, bytesPerPixel: sourceBytesPerPixel)
        let sourceOffset = offsetInside(
            source.count,
            x: sourceX,
            y: sourceY,
            bytesPerRow: sourceBytesPerRow,
            bytesPerPixel: sourceBytesPerPixel
        )
        let destinationBytesPerPixel = bytesPerPixel(destinationFormat.pixelFormat)
        let destinationBytesPerRow = Int(geometry.backendBytesPerRow)
        let destinationOffset = offsetInside(
            destination.count,
            x: destinationRect.x,
            y: destinationRect.y,
            bytesPerRow: destinationBytesPerRow,
            bytesPerPixel: destinationBytesPerPixel
        )
        withMutableSubspan(of: &destination, destinationOffset..<destination.count) { destinationRows in
            PixelConversion.convert(
                source: source.extracting(sourceOffset..<source.count),
                sourceFormat: sourceFormat,
                sourceBytesPerRow: sourceBytesPerRow,
                destination: &destinationRows,
                destinationFormat: destinationFormat,
                destinationBytesPerRow: destinationBytesPerRow,
                width: Int(destinationRect.width),
                height: Int(destinationRect.height)
            )
        }
    }
}

// An IntRect with IntRect's arithmetic, which wraps on overflow.
private struct PixelTransferRect {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32

    var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    // IntRect::intersect(): an empty rect at the origin if the two don't intersect.
    func intersection(_ other: PixelTransferRect) -> PixelTransferRect {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let right = min(x &+ width, other.x &+ other.width)
        let bottom = min(y &+ height, other.y &+ other.height)
        guard left < right, top < bottom else {
            return PixelTransferRect(x: 0, y: 0, width: 0, height: 0)
        }
        return PixelTransferRect(x: left, y: top, width: right &- left, height: bottom &- top)
    }
}

// PixelBuffer::bytesPerPixel(), which isn't inlined into Swift.
private func bytesPerPixel(_ pixelFormat: WebCore.PixelFormat) -> Int {
    switch pixelFormat {
    case .RGBX8, .RGBA8, .BGRX8, .BGRA8:
        return 4
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .RGBA16F:
        return 8
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case .RGBA16:
        return 8
    #endif
    #if ENABLE_PIXEL_FORMAT_RGB10
    case .RGB10:
        return 4
    #endif
    #if ENABLE_PIXEL_FORMAT_RGB10A8
    case .RGB10A8:
        return 4
    #endif
    @unknown default:
        return 4
    }
}

// The offset of pixel (x, y) in rows `bytesPerRow` apart. Nil on overflow.
private func byteOffset(x: Int32, y: Int32, bytesPerRow: Int, bytesPerPixel: Int) -> Int? {
    guard let rowOffset = Int(y).checkedMultiplied(by: bytesPerRow), let columnOffset = Int(x).checkedMultiplied(by: bytesPerPixel) else {
        return nil
    }
    return rowOffset.checkedAdding(columnOffset)
}

// The offset of a pixel of a clipped rect, which is inside the bytes unless they are shorter than the size and stride
// they were described with. Traps if it isn't.
private func offsetInside(_ byteCount: Int, x: Int32, y: Int32, bytesPerRow: Int, bytesPerPixel: Int) -> Int {
    guard let offset = byteOffset(x: x, y: y, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel), offset >= 0, offset <= byteCount
    else {
        preconditionFailure("Pixel bytes are shorter than their size and stride")
    }
    return offset
}

// Rows of a pixel buffer, whose byte count fits in 32 bits. It is computed in 32 bits, which only wraps for widths
// whose rows can't be in any pixel buffer.
private func bytesPerRow(width: Int32, bytesPerPixel: Int) -> Int {
    Int(UInt32(truncatingIfNeeded: width) &* UInt32(truncatingIfNeeded: bytesPerPixel))
}

// The mask of an image for SVG masking: each pixel's alpha becomes the luminance of its color times its alpha.
enum LuminanceMask {
    // Unpremultiplied RGBA8 pixels, in place.
    static func apply(_ pixels: inout MutableSpan<UInt8>) {
        precondition(pixels.count % 4 == 0)
        var bytes = pixels.mutableBytes
        var offset = 0
        while offset < bytes.byteCount {
            let pixel = bytes.load(fromByteOffset: offset, as: SIMD4<UInt8>.self)
            if pixel[3] != 0 {
                let luma = (Double(pixel[0]) * 0.2125 + Double(pixel[1]) * 0.7154 + Double(pixel[2]) * 0.0721) * (Double(pixel[3]) / 255.0)
                bytes.storeBytes(of: clampedByte(luma), toByteOffset: offset &+ 3, as: UInt8.self)
            }
            offset &+= 4
        }
    }

    // JSC::Uint8ClampedAdaptor::toNativeFromDouble(), which PixelBuffer::set() stored with.
    private static func clampedByte(_ value: Double) -> UInt8 {
        if !(value >= 0) {
            return 0
        }
        if value > 255 {
            return 255
        }
        return UInt8(value.rounded(.toNearestOrEven))
    }
}

#endif // ENABLE_WEBCORE_SWIFT
