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

// The safe Span overloads Swift synthesizes for the PixelBufferAccess span accessors call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
#if USE_CORE_IMAGE
import CoreImage
#endif
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.ColorSpace
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntPoint
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferFormat
import WebCore_Private.Core.PixelBufferSwiftBridge
import WebCore_Private.Core.PixelFormat
import WebCore_Private.Core.RenderingMode
#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif

// A filter result: its geometry, color space, and its pixels as an image buffer, as premultiplied and unpremultiplied
// pixel buffers, or as a Core Image image. A FilterImageBox (FilterEngine.swift) holds it. Effects receive it `inout`
// where they make or change its buffers, which the engine does only for distinct images. It is never copied: a copy's
// buffers would no longer be the image's.
struct FilterImageImpl {
    // In filter coordinates.
    let primitiveSubregion: WebCore.FloatRect
    let imageRect: WebCore.FloatRect

    // In user-space coordinates.
    let absoluteImageRect: WebCore.IntRect

    var colorSpace: WebCore.ColorSpace { currentColorSpace }

    private var currentColorSpace: WebCore.ColorSpace
    private let allocator: WebCore.FilterImageAllocator
    private var imageBufferSlot = WebCore.RefPtrImageBuffer()
    private var premultipliedPixelBufferSlot = WebCore.RefPtrPixelBuffer()
    private var unpremultipliedPixelBufferSlot = WebCore.RefPtrPixelBuffer()

    #if USE_CORE_IMAGE
    // The result of an effect applied with Core Image. renderedFilterResultImageBuffer() renders the last one.
    var ciImage: CIImage? { currentCIImage }

    private var currentCIImage: CIImage?
    #endif

    let isAlphaImage: Bool
    let isValidPremultiplied: Bool
    let renderingMode: WebCore.RenderingMode

    init(
        _ allocator: WebCore.FilterImageAllocator,
        _ primitiveSubregion: WebCore.FloatRect,
        _ imageRect: WebCore.FloatRect,
        _ absoluteImageRect: WebCore.IntRect,
        _ isAlphaImage: Bool,
        _ isValidPremultiplied: Bool,
        _ renderingMode: WebCore.RenderingMode,
        _ colorSpace: consuming WebCore.ColorSpace
    ) {
        self.primitiveSubregion = primitiveSubregion
        self.imageRect = imageRect
        self.absoluteImageRect = absoluteImageRect
        self.isAlphaImage = isAlphaImage
        self.isValidPremultiplied = isValidPremultiplied
        self.renderingMode = renderingMode
        self.currentColorSpace = colorSpace
        self.allocator = allocator
    }

    init(
        _ allocator: WebCore.FilterImageAllocator,
        _ primitiveSubregion: WebCore.FloatRect,
        _ imageRect: WebCore.FloatRect,
        _ absoluteImageRect: WebCore.IntRect,
        _ imageBuffer: WebCore.ImageBuffer
    ) {
        self.primitiveSubregion = primitiveSubregion
        self.imageRect = imageRect
        self.absoluteImageRect = absoluteImageRect
        self.isAlphaImage = false
        self.isValidPremultiplied = true
        self.renderingMode = imageBuffer.renderingMode()
        self.currentColorSpace = imageBuffer.colorSpace()
        self.imageBufferSlot = WebCore.RefPtrImageBuffer(imageBuffer)
        self.allocator = allocator
    }

    func absoluteImageRect(relativeTo origin: borrowing FilterImageImpl) -> WebCore.IntRect {
        absoluteImageRect - origin.absoluteImageRect.location()
    }

    func mappedAbsolutePoint(_ point: WebCore.FloatPoint) -> WebCore.FloatPoint {
        let location = absoluteImageRect.location()
        return WebCore.FloatPoint(point.x() - Float(location.x()), point.y() - Float(location.y()))
    }

    func memoryCost() -> UInt {
        var memoryCost: UInt = 0
        if let imageBuffer = imageBufferSlot.get() {
            memoryCost += UInt(bitPattern: imageBuffer.memoryCost())
        }
        if let pixelBuffer = unpremultipliedPixelBufferSlot.get() {
            memoryCost += UInt(bitPattern: WebCore.FilterGraphicsBridge.byteCount(pixelBuffer))
        }
        if let pixelBuffer = premultipliedPixelBufferSlot.get() {
            memoryCost += UInt(bitPattern: WebCore.FilterGraphicsBridge.byteCount(pixelBuffer))
        }
        #if USE_CORE_IMAGE
        if let currentCIImage {
            memoryCost += Self.memoryCost(of: currentCIImage)
        }
        #endif
        return memoryCost
    }

    // The image buffer, created on first use from a pixel buffer if there is one.
    mutating func imageBuffer() -> WebCore.RefPtrImageBuffer {
        #if USE_CORE_IMAGE
        if currentCIImage != nil {
            // No effect asks for the image buffer of a Core Image result: renderedFilterResultImageBuffer() renders the
            // last one.
            assertionFailure()
            return WebCore.RefPtrImageBuffer()
        }
        #endif
        if imageBufferSlot.get() != nil {
            return imageBufferSlot
        }
        imageBufferSlot = createImageBuffer(
            size: WebCore.FloatSize(absoluteImageRect.size()),
            colorSpace: currentColorSpace,
            renderingMode: renderingMode
        )
        guard let imageBuffer = imageBufferSlot.get() else {
            return imageBufferSlot
        }
        let imageBufferRect = WebCore.IntRect(WebCore.IntPoint(), absoluteImageRect.size())
        if let pixelBuffer = premultipliedPixelBufferSlot.get() {
            WebCore.FilterGraphicsBridge.putPixelBuffer(imageBuffer, pixelBuffer, imageBufferRect)
        } else if let pixelBuffer = unpremultipliedPixelBufferSlot.get() {
            WebCore.FilterGraphicsBridge.putPixelBuffer(imageBuffer, pixelBuffer, imageBufferRect)
        }
        return imageBufferSlot
    }

    // The image buffer if there is one, without creating it.
    func existingImageBuffer() -> WebCore.RefPtrImageBuffer {
        imageBufferSlot
    }

    mutating func setImageBuffer(_ imageBuffer: WebCore.ImageBuffer) {
        imageBufferSlot = WebCore.RefPtrImageBuffer(imageBuffer)
    }

    // The RGBA8 pixel buffer in `alphaFormat`, created on first use: read from the image buffer if there is one, otherwise
    // converted from the pixel buffer in the other alpha format if there is one, otherwise as the allocator made it.
    mutating func pixelBuffer(_ alphaFormat: WebCore.AlphaPremultiplication) -> WebCore.RefPtrPixelBuffer {
        let existing = pixelBufferSlot(alphaFormat)
        if existing.get() != nil {
            return existing
        }
        let format = WebCore.PixelBufferFormat(alphaFormat: alphaFormat, pixelFormat: .RGBA8, colorSpace: currentColorSpace)
        if let imageBuffer = imageBufferSlot.get() {
            let pixelBuffer = getPixelBuffer(
                from: imageBuffer,
                format: format,
                sourceRect: WebCore.IntRect(WebCore.IntPoint(), absoluteImageRect.size())
            )
            setPixelBufferSlot(alphaFormat, pixelBuffer)
            return pixelBuffer
        }
        assert(!WebCore.ImageBuffer.sizeNeedsClamping(WebCore.FloatSize(absoluteImageRect.size())))
        let pixelBuffer = createPixelBuffer(format: format, size: absoluteImageRect.size())
        setPixelBufferSlot(alphaFormat, pixelBuffer)
        guard let destination = pixelBuffer.get() else {
            return pixelBuffer
        }
        let other = pixelBufferSlot(alphaFormat == .Unpremultiplied ? .Premultiplied : .Unpremultiplied)
        if let source = other.get(), !Self.copyImageBytes(from: source, to: destination) {
            // The slot keeps the new pixel buffer, as in C++.
            return WebCore.RefPtrPixelBuffer()
        }
        return pixelBuffer
    }

    // A new RGBA8 pixel buffer of `sourceRect`'s size holding that rect of this image, in its color space or another.
    mutating func getPixelBuffer(_ alphaFormat: WebCore.AlphaPremultiplication, sourceRect: WebCore.IntRect) -> WebCore.RefPtrPixelBuffer {
        newPixelBuffer(
            WebCore.PixelBufferFormat(alphaFormat: alphaFormat, pixelFormat: .RGBA8, colorSpace: currentColorSpace),
            copying: sourceRect
        )
    }

    mutating func getPixelBuffer(
        _ alphaFormat: WebCore.AlphaPremultiplication,
        sourceRect: WebCore.IntRect,
        colorSpace: borrowing WebCore.ColorSpace
    ) -> WebCore.RefPtrPixelBuffer {
        newPixelBuffer(
            WebCore.PixelBufferFormat(alphaFormat: alphaFormat, pixelFormat: .RGBA8, colorSpace: copy colorSpace),
            copying: sourceRect
        )
    }

    // Copies `sourceRect` of this image into `destination`, in the destination's alpha format and color space. The
    // destination's pixels outside this image are zeroed. False if the rect misses the destination or a conversion fails.
    mutating func copyPixelBuffer(into destination: WebCore.PixelBuffer, sourceRect: WebCore.IntRect) -> Bool {
        let destinationFormat = WebCore.FilterGraphicsBridge.format(destination)
        let alphaFormat = destinationFormat.alphaFormat
        var sourcePixelBuffer = pixelBufferSlot(alphaFormat)
        if sourcePixelBuffer.get() == nil {
            if requiresPixelBufferColorSpaceConversion(destinationFormat.colorSpace), let imageBuffer = imageBufferSlot.get() {
                // A conversion from the image buffer is preferred.
                let rect = WebCore.IntRect(WebCore.IntPoint(), absoluteImageRect.size())
                guard let converted = convertedPixelBuffer(imageBuffer, alphaFormat, rect, destinationFormat.colorSpace).get() else {
                    return false
                }
                return Self.copyImageBytes(from: converted, to: destination, sourceRect)
            }
            sourcePixelBuffer = pixelBuffer(alphaFormat)
        }
        guard let source = sourcePixelBuffer.get() else {
            return false
        }
        if requiresPixelBufferColorSpaceConversion(destinationFormat.colorSpace) {
            guard let converted = convertedPixelBuffer(source, alphaFormat, destinationFormat.colorSpace).get() else {
                return false
            }
            return Self.copyImageBytes(from: converted, to: destination, sourceRect)
        }
        return Self.copyImageBytes(from: source, to: destination, sourceRect)
    }

    // Clamps each color component of the premultiplied pixel buffer to its alpha, for effects that can produce invalid
    // premultiplied pixels.
    func correctPremultipliedPixelBuffer() {
        guard !isValidPremultiplied, let pixelBuffer = premultipliedPixelBufferSlot.get() else {
            return
        }
        var access = WebCore.PixelBufferAccess(pixelBuffer)
        var bytes: MutableSpan<UInt8> = access.mutableSpan()
        var pixels = bytes.mutableBytes
        clampColorComponentsToAlpha(&pixels)
    }

    // Whether transformToColorSpace() changes images: CG and Skia convert color spaces when drawing.
    static var transformsColorSpace: Bool {
        #if USE_CG || USE_SKIA
        false
        #else
        true
        #endif
    }

    mutating func transformToColorSpace(_ colorSpace: borrowing WebCore.ColorSpace) {
        #if USE_CG || USE_SKIA
        // CG and Skia convert color spaces when drawing.
        #else
        if colorSpace == currentColorSpace {
            return
        }
        // FIXME: Avoid this image buffer conversion by transforming the pixel buffers' color space.
        if let imageBuffer = imageBuffer().get() {
            imageBuffer.transformToColorSpace(colorSpace)
        }
        currentColorSpace = copy colorSpace
        unpremultipliedPixelBufferSlot = WebCore.RefPtrPixelBuffer()
        premultipliedPixelBufferSlot = WebCore.RefPtrPixelBuffer()
        #endif
    }

    #if USE_CORE_IMAGE
    mutating func setCIImage(_ image: CIImage?) {
        currentCIImage = image
    }
    #endif

    // Buffers from the image's allocator. Null if the allocator fails.
    func createPixelBuffer(format: borrowing WebCore.PixelBufferFormat, size: WebCore.IntSize) -> WebCore.RefPtrPixelBuffer {
        WebCore.FilterGraphicsBridge.createPixelBuffer(allocator, format, size)
    }

    func createImageBuffer(
        size: WebCore.FloatSize,
        colorSpace: borrowing WebCore.ColorSpace,
        renderingMode: WebCore.RenderingMode
    ) -> WebCore.RefPtrImageBuffer {
        WebCore.FilterGraphicsBridge.createImageBuffer(allocator, size, colorSpace, renderingMode)
    }

    func getPixelBuffer(
        from imageBuffer: WebCore.ImageBuffer,
        format: borrowing WebCore.PixelBufferFormat,
        sourceRect: WebCore.IntRect
    ) -> WebCore.RefPtrPixelBuffer {
        WebCore.FilterGraphicsBridge.getPixelBuffer(imageBuffer, format, sourceRect, allocator)
    }

    private func pixelBufferSlot(_ alphaFormat: WebCore.AlphaPremultiplication) -> WebCore.RefPtrPixelBuffer {
        alphaFormat == .Unpremultiplied ? unpremultipliedPixelBufferSlot : premultipliedPixelBufferSlot
    }

    private mutating func setPixelBufferSlot(
        _ alphaFormat: WebCore.AlphaPremultiplication,
        _ pixelBuffer: borrowing WebCore.RefPtrPixelBuffer
    ) {
        if alphaFormat == .Unpremultiplied {
            unpremultipliedPixelBufferSlot = copy pixelBuffer
        } else {
            premultipliedPixelBufferSlot = copy pixelBuffer
        }
    }

    private mutating func newPixelBuffer(
        _ format: borrowing WebCore.PixelBufferFormat,
        copying sourceRect: WebCore.IntRect
    ) -> WebCore.RefPtrPixelBuffer {
        assert(!WebCore.ImageBuffer.sizeNeedsClamping(WebCore.FloatSize(sourceRect.size())))
        let pixelBuffer = createPixelBuffer(format: format, size: sourceRect.size())
        guard let destination = pixelBuffer.get() else {
            return pixelBuffer
        }
        if !copyPixelBuffer(into: destination, sourceRect: sourceRect) {
            return WebCore.RefPtrPixelBuffer()
        }
        return pixelBuffer
    }

    // Only pixel copies need a color space conversion: CG and Skia convert when drawing.
    private func requiresPixelBufferColorSpaceConversion(_ colorSpace: borrowing WebCore.ColorSpace) -> Bool {
        #if USE_CG || USE_SKIA
        return !(colorSpace == currentColorSpace)
        #else
        return false
        #endif
    }

    // `rect` of an image buffer, drawn into a new image buffer in `colorSpace` and read back.
    private func convertedPixelBuffer(
        _ imageBuffer: WebCore.ImageBuffer,
        _ alphaFormat: WebCore.AlphaPremultiplication,
        _ rect: WebCore.IntRect,
        _ colorSpace: borrowing WebCore.ColorSpace
    ) -> WebCore.RefPtrPixelBuffer {
        let size = WebCore.ImageBuffer.clampedSize(WebCore.FloatSize(rect.size()))
        guard let convertedImageBuffer = createImageBuffer(size: size, colorSpace: colorSpace, renderingMode: .Unaccelerated).get() else {
            return WebCore.RefPtrPixelBuffer()
        }
        filterDrawImageBuffer(convertedImageBuffer, imageBuffer, rect)
        let format = WebCore.PixelBufferFormat(alphaFormat: alphaFormat, pixelFormat: .RGBA8, colorSpace: copy colorSpace)
        return getPixelBuffer(from: convertedImageBuffer, format: format, sourceRect: rect)
    }

    // A pixel buffer, put into a new image buffer in its own color space, and converted from there.
    private func convertedPixelBuffer(
        _ pixelBuffer: WebCore.PixelBuffer,
        _ alphaFormat: WebCore.AlphaPremultiplication,
        _ colorSpace: borrowing WebCore.ColorSpace
    ) -> WebCore.RefPtrPixelBuffer {
        let rect = WebCore.IntRect(WebCore.IntPoint(), WebCore.FilterGraphicsBridge.size(pixelBuffer))
        let size = WebCore.ImageBuffer.clampedSize(WebCore.FloatSize(rect.size()))
        let sourceColorSpace = WebCore.FilterGraphicsBridge.format(pixelBuffer).colorSpace
        guard let imageBuffer = createImageBuffer(size: size, colorSpace: sourceColorSpace, renderingMode: .Unaccelerated).get() else {
            return WebCore.RefPtrPixelBuffer()
        }
        WebCore.FilterGraphicsBridge.putPixelBuffer(imageBuffer, pixelBuffer, rect)
        return convertedPixelBuffer(imageBuffer, alphaFormat, rect, colorSpace)
    }

    // Converts all of `source` into `destination`, which has the same size. Assumes 4 bytes per pixel, as all filter
    // pixel buffers are RGBA8.
    private static func copyImageBytes(from source: WebCore.PixelBuffer, to destination: WebCore.PixelBuffer) -> Bool {
        assert(WebCore.FilterGraphicsBridge.format(destination).pixelFormat == .RGBA8)
        let size = WebCore.FilterGraphicsBridge.size(destination)
        let width = size.width()
        guard let bytesPerRow = filterRowBytes(width) else {
            return false
        }
        let sourceAccess = WebCore.PixelBufferAccess(source)
        var destinationAccess = WebCore.PixelBufferAccess(destination)
        let sourceBytes: Span<UInt8> = sourceAccess.span()
        var destinationBytes: MutableSpan<UInt8> = destinationAccess.mutableSpan()
        PixelConversion.convert(
            source: sourceBytes,
            sourceFormat: WebCore.FilterGraphicsBridge.format(source),
            sourceBytesPerRow: bytesPerRow,
            destination: &destinationBytes,
            destinationFormat: WebCore.FilterGraphicsBridge.format(destination),
            destinationBytesPerRow: bytesPerRow,
            width: Int(width),
            height: Int(size.height())
        )
        return true
    }

    // Copies the part of `source` inside `sourceRect` to the same place relative to `sourceRect`'s origin in
    // `destination`, and zeroes the rest of the destination. False, with nothing copied, if that part is empty.
    private static func copyImageBytes(
        from source: WebCore.PixelBuffer,
        to destination: WebCore.PixelBuffer,
        _ sourceRect: WebCore.IntRect
    ) -> Bool {
        assert(WebCore.FilterGraphicsBridge.format(destination).pixelFormat == .RGBA8)
        let sourcePixelBufferRect = WebCore.IntRect(WebCore.IntPoint(), WebCore.FilterGraphicsBridge.size(source))
        let destinationPixelBufferRect = WebCore.IntRect(WebCore.IntPoint(), WebCore.FilterGraphicsBridge.size(destination))

        var sourceRectClipped = WebCore.intersection(sourcePixelBufferRect, sourceRect)
        var destinationRect = WebCore.IntRect(WebCore.IntPoint(), sourceRectClipped.size())

        // Negating INT_MIN wraps.
        if sourceRect.x() < 0 {
            destinationRect.setX(0 &- sourceRect.x())
        }
        if sourceRect.y() < 0 {
            destinationRect.setY(0 &- sourceRect.y())
        }

        destinationRect.intersect(destinationPixelBufferRect)
        sourceRectClipped.setSize(destinationRect.size())

        if destinationRect.isEmpty() {
            return false
        }

        guard let rowBytes = filterRowBytes(sourceRectClipped.width()),
            let destinationBytesPerRow = filterRowBytes(destinationPixelBufferRect.width()),
            let sourceBytesPerRow = filterRowBytes(sourcePixelBufferRect.width()),
            let destinationOffset = filterByteOffset(x: destinationRect.x(), y: destinationRect.y(), bytesPerRow: destinationBytesPerRow),
            let sourceOffset = filterByteOffset(x: sourceRectClipped.x(), y: sourceRectClipped.y(), bytesPerRow: sourceBytesPerRow)
        else {
            return false
        }

        let destinationSize = destinationRect.size()
        let destinationPixelBufferSize = destinationPixelBufferRect.size()
        if destinationSize.width() != destinationPixelBufferSize.width() || destinationSize.height() != destinationPixelBufferSize.height()
        {
            destination.zeroFill()
        }

        let rows = Int(sourceRectClipped.height())
        var destinationAccess = WebCore.PixelBufferAccess(destination)
        var destinationBytes: MutableSpan<UInt8> = destinationAccess.mutableSpan()
        let copied: Bool
        if WebCore.FilterGraphicsBridge.isSamePixelBuffer(source, destination) {
            // Never two views of one buffer: read the source from a copy. (No caller copies an image into itself.)
            precondition(sourceOffset <= destinationBytes.count)
            let sourceCopyCount = destinationBytes.count - sourceOffset
            var sourceCopy = ContiguousArray<UInt8>(repeating: 0, count: sourceCopyCount)
            do {
                var sourceCopyBytes = sourceCopy.mutableSpan
                copyBytes(from: destinationBytes.span, at: sourceOffset, to: &sourceCopyBytes, at: 0, count: sourceCopyCount)
            }
            copied = withMutableSubspan(of: &destinationBytes, destinationOffset..<destinationBytes.count) { destinationRows in
                PixelConversion.copyRows(
                    source: sourceCopy.span,
                    sourceBytesPerRow: sourceBytesPerRow,
                    destination: &destinationRows,
                    destinationBytesPerRow: destinationBytesPerRow,
                    rows: rows,
                    rowBytes: rowBytes
                )
            }
        } else {
            let sourceAccess = WebCore.PixelBufferAccess(source)
            let sourceBytes: Span<UInt8> = sourceAccess.span()
            copied = withMutableSubspan(of: &destinationBytes, destinationOffset..<destinationBytes.count) { destinationRows in
                PixelConversion.copyRows(
                    source: sourceBytes.extracting(sourceOffset..<sourceBytes.count),
                    sourceBytesPerRow: sourceBytesPerRow,
                    destination: &destinationRows,
                    destinationBytesPerRow: destinationBytesPerRow,
                    rows: rows,
                    rowBytes: rowBytes
                )
            }
        }
        // The rows are inside both rects, so they fit both buffers; the C++ asserted that too.
        precondition(copied)
        return true
    }
}

// The C++ computed filter pixel offsets in CheckedUint32: a negative input or a result above UInt32.max fails.
private func filterRowBytes(_ width: Int32) -> Int? {
    guard width >= 0 else {
        return nil
    }
    let (rowBytes, overflow) = UInt32(width).multipliedReportingOverflow(by: 4)
    return overflow ? nil : Int(rowBytes)
}

private func filterByteOffset(x: Int32, y: Int32, bytesPerRow: Int) -> Int? {
    guard x >= 0, y >= 0 else {
        return nil
    }
    let (rowOffset, rowOverflow) = UInt32(y).multipliedReportingOverflow(by: UInt32(bytesPerRow))
    let (columnOffset, columnOverflow) = UInt32(x).multipliedReportingOverflow(by: 4)
    let (offset, overflow) = rowOffset.addingReportingOverflow(columnOffset)
    return rowOverflow || columnOverflow || overflow ? nil : Int(offset)
}

// Clamps the color components of each complete 4-byte pixel (alpha last) to its alpha.
private func clampColorComponentsToAlpha(_ pixels: inout MutableRawSpan) {
    let byteCount = pixels.byteCount & ~3
    var offset = 0
    #if arch(arm64)
    let alphaIndices = SIMD16<UInt8>(3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15)
    while offset &+ 16 <= byteCount {
        let fourPixels = pixels.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
        pixels.storeBytes(of: vminq_u8(fourPixels, vqtbl1q_u8(fourPixels, alphaIndices)), toByteOffset: offset, as: SIMD16<UInt8>.self)
        offset &+= 16
    }
    #endif
    while offset &+ 4 <= byteCount {
        let pixel = pixels.load(fromByteOffset: offset, as: SIMD4<UInt8>.self)
        pixels.storeBytes(of: pointwiseMin(pixel, SIMD4(repeating: pixel[3])), toByteOffset: offset, as: SIMD4<UInt8>.self)
        offset &+= 4
    }
}

// Draws all of `source` into `destinationRect` of `destination`. The color space conversion happens here, when drawing
// from one image buffer to another.
func filterDrawImageBuffer(
    _ destination: WebCore.ImageBuffer,
    _ source: WebCore.ImageBuffer,
    _ destinationRect: WebCore.IntRect
) {
    let drawing = WebCore.ImageBufferDrawing(destination)
    drawing.context().drawImageBuffer(source, WebCore.FloatRect(destinationRect), .SourceOver)
}

#endif // ENABLE_WEBCORE_SWIFT
