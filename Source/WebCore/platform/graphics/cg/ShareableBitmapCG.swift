// Copyright (C) 2010-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && USE_CG

public import CoreGraphics
import WebCore_Private.Core.ShareableBitmap
import WebCore_Private.Core.SharedMemory

// A shareable bitmap's pixels, in the shared memory it keeps, and how Core Graphics reads them: the drawing and images
// over the memory. WebCore::ShareableBitmap, which allocates, maps and shares the memory, holds one. Every property is
// immutable, and the SharedMemory is thread-safe reference counted, with a mapping that lasts as long as it does.
@_spi(WebKitGPU) public final class ShareableBitmapCore: @unchecked Sendable {
    public let width: Int32
    public let height: Int32
    public let colorSpace: CGColorSpace
    public let bitsPerComponent: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let bitmapInfo: UInt32
    public let headroom: Float
    public let sizeInBytes: Int
    private let memory: WebCore.SharedMemory

    fileprivate init(memory: WebCore.SharedMemory, width: Int32, height: Int32, colorSpace: CGColorSpace, bitsPerComponent: Int, bytesPerPixel: Int, bytesPerRow: Int, bitmapInfo: UInt32, headroom: Float, sizeInBytes: Int) {
        self.memory = memory
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.bitsPerComponent = bitsPerComponent
        self.bytesPerPixel = bytesPerPixel
        self.bytesPerRow = bytesPerRow
        self.bitmapInfo = bitmapInfo
        self.headroom = headroom
        self.sizeInBytes = sizeInBytes
        precondition(sizeInBytes <= memory.size())
    }

    // The start of the memory, which this object keeps.
    private var baseAddress: UnsafeMutableRawPointer? {
        unsafe UnsafeMutableRawPointer(memory.mutableSpan().__dataUnsafe())
    }

    public func withBytes<Result>(_ body: (Span<UInt8>) throws -> Result) rethrows -> Result {
        let span = unsafe memory.span()
        let buffer = unsafe UnsafeBufferPointer(start: span.__dataUnsafe(), count: span.size())
        return try body(unsafe buffer.span)
    }

    // What a data provider over the pixels keeps: the bitmap, until the provider releases it.
    private final class ProviderData {
        let bitmap: ShareableBitmapCore
        var released = false

        init(_ bitmap: ShareableBitmapCore) {
            self.bitmap = bitmap
        }
    }

    private final class ContextData {
        let bitmap: ShareableBitmapCore
        var released = false

        init(_ bitmap: ShareableBitmapCore) {
            self.bitmap = bitmap
        }
    }

    // A context that draws into the bitmap, with the origin at the top left. The context keeps the bitmap.
    public func createCGContext() -> CGContext? {
        let data = ContextData(self)
        let info = unsafe Unmanaged.passRetained(data)
        let context = unsafe CGContext(
            data: baseAddress,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            releaseCallback: { info, _ in
                guard let info = unsafe info else {
                    return
                }
                let data = unsafe Unmanaged<ContextData>.fromOpaque(info)
                unsafe data.takeUnretainedValue().released = true
                unsafe data.release()
            },
            releaseInfo: info.toOpaque()
        )
        guard let context else {
            // When CGBitmapContextCreateWithData fails and returns null, it will only call the release callback in some
            // circumstances <rdar://82228446>.
            if !data.released {
                unsafe info.release()
            }
            return nil
        }
        assert(!data.released)

        // We want the origin to be in the top left corner so we flip the backing store context.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    // An image of the bitmap: of a copy of its pixels, or of the pixels themselves, which is only safe when they won't
    // change. An image of the pixels keeps the bitmap.
    public func createBasePlatformImage(copyBackingStore: Bool, shouldInterpolate: Bool) -> CGImage? {
        withBytes { bytes in
            precondition(!bytes.isEmpty)
            _ = bytes[bytes.count - 1]
        }

        let provider: CGDataProvider
        if copyBackingStore {
            let copy = withBytes { bytes in
                bytes.withUnsafeBufferPointer { buffer in
                    unsafe CFDataCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count)
                }
            }
            guard let copy, let copyProvider = CGDataProvider(data: copy) else {
                return nil
            }
            provider = copyProvider
        } else {
            guard sizeInBytes > 0, let baseAddress = unsafe baseAddress else {
                return nil
            }
            let box = ProviderData(self)
            let data = unsafe Unmanaged.passRetained(box)
            guard let dataProvider = unsafe CGDataProvider(
                dataInfo: data.toOpaque(),
                data: baseAddress,
                size: sizeInBytes,
                releaseData: { info, _, _ in
                    guard let info = unsafe info else {
                        return
                    }
                    let data = unsafe Unmanaged<ProviderData>.fromOpaque(info)
                    unsafe data.takeUnretainedValue().released = true
                    unsafe data.release()
                }
            ) else {
                if !box.released {
                    unsafe data.release()
                }
                return nil
            }
            provider = dataProvider
        }

        let bitsPerPixel = bytesPerPixel * 8
        #if HAVE_SUPPORT_HDR_DISPLAY_APIS
        if headroom > 1 {
            return unsafe CGImage(
                headroom: headroom,
                width: Int(width),
                height: Int(height),
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: shouldInterpolate,
                intent: .defaultIntent
            )
        }
        #endif
        return unsafe CGImage(
            width: Int(width),
            height: Int(height),
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: shouldInterpolate,
            intent: .defaultIntent
        )
    }

    // Draws the part `source` of an image of the bitmap at `destination` in a context whose origin is at the top left.
    public static func paint(_ image: CGImage, in context: CGContext, scaleFactor: Float, destination: CGPoint, source: CGRect) {
        context.saveGState()

        context.clip(to: CGRect(x: destination.x, y: destination.y, width: source.width, height: source.height))
        context.scaleBy(x: 1, y: -1)

        let imageHeight = CGFloat(image.height) / CGFloat(scaleFactor)
        let imageWidth = CGFloat(image.width) / CGFloat(scaleFactor)

        let destinationX = destination.x - source.minX
        let destinationY = -imageHeight - destination.y + source.minY

        context.draw(image, in: CGRect(x: destinationX, y: destinationY, width: imageWidth, height: imageHeight))

        context.restoreGState()
    }
}

extension WebCore.ShareableBitmap {
    @_spi(WebKitGPU) public var core: ShareableBitmapCore {
        unsafe Unmanaged<ShareableBitmapCore>.fromOpaque(UnsafeRawPointer(bitPattern: m_swiftState)!).takeUnretainedValue()
    }

    static func borrowed(_ swiftState: UInt) -> ShareableBitmapCore {
        unsafe Unmanaged<ShareableBitmapCore>.fromOpaque(UnsafeRawPointer(bitPattern: swiftState)!).takeUnretainedValue()
    }

    @cxx
    @implementation
    static func createSwiftState(
        _ memory: WebCore.SharedMemory,
        _ width: Int32,
        _ height: Int32,
        _ colorSpace: CGColorSpace?,
        _ bitsPerComponent: UInt32,
        _ bytesPerPixel: UInt32,
        _ bytesPerRow: UInt32,
        _ bitmapInfo: UInt32,
        _ headroom: Float,
        _ sizeInBytes: UInt32
    ) -> UInt {
        let core = ShareableBitmapCore(
            memory: memory,
            width: width,
            height: height,
            colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitsPerComponent: Int(bitsPerComponent),
            bytesPerPixel: Int(bytesPerPixel),
            bytesPerRow: Int(bytesPerRow),
            bitmapInfo: bitmapInfo,
            headroom: headroom,
            sizeInBytes: Int(sizeInBytes)
        )
        return UInt(bitPattern: unsafe Unmanaged.passRetained(core).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        unsafe Unmanaged<ShareableBitmapCore>.fromOpaque(UnsafeRawPointer(bitPattern: swiftState)!).release()
    }

    @cxx
    @implementation
    static func swiftCreateCGContext(_ swiftState: UInt) -> Unmanaged<CGContext>? {
        unsafe borrowed(swiftState).createCGContext().map { unsafe Unmanaged.passRetained($0) }
    }

    @cxx
    @implementation
    static func swiftCreateBasePlatformImage(_ swiftState: UInt, _ copyBackingStore: Bool, _ shouldInterpolate: Bool) -> Unmanaged<CGImage>? {
        unsafe borrowed(swiftState).createBasePlatformImage(copyBackingStore: copyBackingStore, shouldInterpolate: shouldInterpolate).map { unsafe Unmanaged.passRetained($0) }
    }

    @cxx
    @implementation
    static func swiftPaint(_ image: CGImage?, _ context: CGContext?, _ scaleFactor: Float, _ destination: CGPoint, _ source: CGRect) {
        guard let image, let context else {
            return
        }
        ShareableBitmapCore.paint(image, in: context, scaleFactor: scaleFactor, destination: destination, source: source)
    }
}

#endif // ENABLE_WEBCORE_SWIFT && USE_CG
