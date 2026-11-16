// Copyright (C) 2014-2018 Apple Inc. All rights reserved.
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
//
// Copyright (C) 2013, 2014 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && HAVE_IOSURFACE

public import CoreGraphics
internal import CoreMedia
import CoreVideo
import Foundation
#if hasAttribute(diagnose)
@diagnose(UnusedImportAccess, as: ignored, reason: "IOSurfaceRef comes from WTF's IOSurfaceSPI.h on the iOS public SDK")
#endif
public import IOSurface
import QuartzCore
import Synchronization
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.ImageBufferBackend
import WebCore_Private.Core.IOSurface
import WebCore_Private.Core.IOSurfacePool
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelFormat
import WebCore_Private.Core.RenderingMode
import os
import pal.spi.cf.CoreVideoSPI
#if USE_WEB_THREAD
internal import wtf.Core.MainThread
#endif

private let ioSurfaceLog = Logger(subsystem: "com.apple.WebKit", category: "IOSurface")
private let layersLog = Logger(subsystem: "com.apple.WebKit", category: "Layers")

@_spi(WebKitGPU) public typealias IOSurfaceName = WebCore.IOSurface.Name
@_spi(WebKitGPU) public typealias IOSurfaceFormat = WebCore.IOSurface.Format

extension WebCore.IOSurface.Name {
    fileprivate var string: CFString {
        switch self {
        case .Default:
            "WebKit" as CFString
        case .DOM:
            "WebKit DOM" as CFString
        case .Canvas:
            "WebKit Canvas" as CFString
        case .GraphicsContextGL:
            "WebKit GraphicsContextGL" as CFString
        case .ImageBuffer:
            "WebKit ImageBuffer" as CFString
        case .ImageBufferShareableMapped:
            "WebKit ImageBufferShareableMapped" as CFString
        case .LayerBacking:
            "WebKit LayerBacking" as CFString
        case .MediaPainting:
            "WebKit MediaPainting" as CFString
        case .Snapshot:
            "WKWebView Snapshot" as CFString
        case .ShareableSnapshot:
            "WKWebView Snapshot (shareable)" as CFString
        case .ShareableLocalSnapshot:
            "WKWebView Snapshot (shareable local)" as CFString
        case .WebGPU:
            "WebKit WebGPU" as CFString
        @unknown default:
            "WebKit" as CFString
        }
    }
}

private func coreVideoFormat(_ format: IOSurfaceFormat, useLosslessCompression: Bool) -> OSType {
    switch format {
    case .BGRX, .BGRA:
        return useLosslessCompression ? OSType(kCVPixelFormatType_Lossless_32BGRA) : OSType(kCVPixelFormatType_32BGRA)
    case .YUV422:
        return OSType(kCVPixelFormatType_422YpCbCr8BiPlanarFullRange)
    case .RGBA, .RGBX:
        // CoreVideo does not support allocation of RGBA surfaces: rdar://156609776.
        assertionFailure()
        return OSType(kCVPixelFormatType_32RGBA)
    #if ENABLE_PIXEL_FORMAT_RGB10
    case .RGB10:
        return useLosslessCompression ? OSType(kCVPixelFormatType_AGX_30RGBLEPackedWideGamut) : OSType(kCVPixelFormatType_30RGBLEPackedWideGamut)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGB10A8
    case .RGB10A8:
        return useLosslessCompression ? OSType(kCVPixelFormatType_AGX_30RGBLE_8A_BiPlanar) : OSType(kCVPixelFormatType_30RGBLE_8A_BiPlanar)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .RGBA16F:
        return useLosslessCompression ? OSType(kCVPixelFormatType_Lossless_64RGBAHalf) : OSType(kCVPixelFormatType_64RGBAHalf)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case .RGBA16:
        // CoreVideo has no lossless counterpart to kCVPixelFormatType_64RGBALE.
        return OSType(kCVPixelFormatType_64RGBALE)
    #endif
    @unknown default:
        assertionFailure()
        return 0
    }
}

private func createSurfaceViaCoreVideo(width: Int32, height: Int32, name: IOSurfaceName, format: IOSurfaceFormat) -> IOSurfaceRef? {
    // FIXME: WebKit shouldn't have to know about size limits: rdar://156866095.
    if width < 32 || height < 32 {
        return nil
    }

    let pixelFormat = coreVideoFormat(format, useLosslessCompression: true)
    if !CVIsCompressedPixelFormatAvailable(pixelFormat) {
        return nil
    }

    var surfaceProperties: [CFString: Any] = [kIOSurfaceName: name.string]
    #if WTF_PLATFORM_IOS_FAMILY
    // FIXME: Determine what hardware/platforms this should be used on.
    surfaceProperties[kIOSurfaceCacheMode] = Int(kIOSurfaceMapWriteCombineCache)
    #endif
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: surfaceProperties as CFDictionary,
        // FIXME: Use kCVPixelBufferIOSurfacePurgeableKey: rdar://156450702.
        "IOSurfacePurgeable" as CFString: true,
    ]

    var pixelBuffer: CVPixelBuffer?
    let status = unsafe CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height), pixelFormat, attributes as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else {
        layersLog.error("IOSurface creation via CVPixelBufferCreate failed for size: (\(width) \(height)) and format: (\(format.rawValue)) - error \(status)")
        return nil
    }
    return unsafe CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
}

private func optionsForBiplanarSurface(width: Int32, height: Int32, pixelFormat: OSType, firstPlaneBytesPerPixel: Int, secondPlaneBytesPerPixel: Int, name: IOSurfaceName) -> [CFString: Any] {
    let firstPlaneBytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, Int(width) * firstPlaneBytesPerPixel)
    let firstPlaneTotalBytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, Int(height) * firstPlaneBytesPerRow)

    let secondPlaneBytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, Int(width) * secondPlaneBytesPerPixel)
    let secondPlaneTotalBytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, Int(height) * secondPlaneBytesPerRow)

    let totalBytes = firstPlaneTotalBytes + secondPlaneTotalBytes
    assert(totalBytes > 0)

    let planeInfo: [[CFString: Any]] = [
        [
            kIOSurfacePlaneWidth: Int(width),
            kIOSurfacePlaneHeight: Int(height),
            kIOSurfacePlaneBytesPerRow: firstPlaneBytesPerRow,
            kIOSurfacePlaneOffset: 0,
            kIOSurfacePlaneSize: firstPlaneTotalBytes,
        ],
        [
            kIOSurfacePlaneWidth: Int(width),
            kIOSurfacePlaneHeight: Int(height),
            kIOSurfacePlaneBytesPerRow: secondPlaneBytesPerRow,
            kIOSurfacePlaneOffset: firstPlaneTotalBytes,
            kIOSurfacePlaneSize: secondPlaneTotalBytes,
        ],
    ]

    var options: [CFString: Any] = [
        kIOSurfaceWidth: Int(width),
        kIOSurfaceHeight: Int(height),
        kIOSurfacePixelFormat: pixelFormat,
        kIOSurfaceAllocSize: totalBytes,
        kIOSurfacePlaneInfo: planeInfo,
        kIOSurfaceName: name.string,
    ]
    #if WTF_PLATFORM_IOS_FAMILY
    options[kIOSurfaceCacheMode] = Int(kIOSurfaceMapWriteCombineCache)
    #endif
    return options
}

private func optionsForSurface(width: Int32, height: Int32, bitsPerPixel: Int, pixelFormat: OSType, name: IOSurfaceName) -> [CFString: Any] {
    let bytesPerElement = 4 * (bitsPerPixel / 32)
    let bytesPerPixel = bytesPerElement

    let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, Int(width) * bytesPerPixel)
    assert(bytesPerRow > 0)

    let totalBytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, Int(height) * bytesPerRow)
    assert(totalBytes > 0)

    var options: [CFString: Any] = [
        kIOSurfaceWidth: Int(width),
        kIOSurfaceHeight: Int(height),
        kIOSurfacePixelFormat: pixelFormat,
        kIOSurfaceBytesPerElement: bytesPerElement,
        kIOSurfaceBytesPerRow: bytesPerRow,
        kIOSurfaceAllocSize: totalBytes,
        kIOSurfaceElementHeight: 1,
        kIOSurfaceName: name.string,
    ]
    #if WTF_PLATFORM_IOS_FAMILY
    options[kIOSurfaceCacheMode] = Int(kIOSurfaceMapWriteCombineCache)
    #endif
    return options
}

private func createSurface(width: Int32, height: Int32, name: IOSurfaceName, format: IOSurfaceFormat) -> IOSurfaceRef? {
    let options: [CFString: Any]
    switch format {
    case .BGRX, .BGRA:
        options = optionsForSurface(width: width, height: height, bitsPerPixel: 32, pixelFormat: OSType(kCVPixelFormatType_32BGRA), name: name)
    case .YUV422:
        options = optionsForBiplanarSurface(width: width, height: height, pixelFormat: OSType(kCVPixelFormatType_422YpCbCr8BiPlanarFullRange), firstPlaneBytesPerPixel: 1, secondPlaneBytesPerPixel: 1, name: name)
    case .RGBX, .RGBA:
        options = optionsForSurface(width: width, height: height, bitsPerPixel: 32, pixelFormat: OSType(kCVPixelFormatType_32RGBA), name: name)
    #if ENABLE_PIXEL_FORMAT_RGB10
    case .RGB10:
        options = optionsForSurface(width: width, height: height, bitsPerPixel: 32, pixelFormat: OSType(kCVPixelFormatType_30RGBLEPackedWideGamut), name: name)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGB10A8
    case .RGB10A8:
        options = optionsForBiplanarSurface(width: width, height: height, pixelFormat: OSType(kCVPixelFormatType_30RGBLE_8A_BiPlanar), firstPlaneBytesPerPixel: 4, secondPlaneBytesPerPixel: 1, name: name)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .RGBA16F:
        options = optionsForSurface(width: width, height: height, bitsPerPixel: 64, pixelFormat: OSType(kCVPixelFormatType_64RGBAHalf), name: name)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case .RGBA16:
        options = optionsForSurface(width: width, height: height, bitsPerPixel: 64, pixelFormat: OSType(kCVPixelFormatType_64RGBALE), name: name)
    #endif
    @unknown default:
        return nil
    }
    return IOSurfaceCreate(options as CFDictionary)
}

// The format and compression of a surface's pixels, as IOSurface::UsedFormat.
@_spi(WebKitGPU) public struct IOSurfaceUsedFormat: Equatable, Sendable {
    public var format: IOSurfaceFormat
    public var useLosslessCompression: Bool

    public init(format: IOSurfaceFormat, useLosslessCompression: Bool) {
        self.format = format
        self.useLosslessCompression = useLosslessCompression
    }
}

private func surfaceUsedFormat(_ surface: IOSurfaceRef) -> IOSurfaceUsedFormat? {
    switch IOSurfaceGetPixelFormat(surface) {
    case OSType(kCVPixelFormatType_32BGRA):
        return IOSurfaceUsedFormat(format: .BGRA, useLosslessCompression: false)
    case OSType(kCVPixelFormatType_Lossless_32BGRA):
        return IOSurfaceUsedFormat(format: .BGRA, useLosslessCompression: true)
    case OSType(kCVPixelFormatType_422YpCbCr8BiPlanarFullRange):
        return IOSurfaceUsedFormat(format: .YUV422, useLosslessCompression: false)
    case OSType(kCVPixelFormatType_32RGBA):
        return IOSurfaceUsedFormat(format: .RGBA, useLosslessCompression: false)
    #if ENABLE_PIXEL_FORMAT_RGB10
    case OSType(kCVPixelFormatType_30RGBLEPackedWideGamut):
        return IOSurfaceUsedFormat(format: .RGB10, useLosslessCompression: false)
    case OSType(kCVPixelFormatType_AGX_30RGBLEPackedWideGamut):
        return IOSurfaceUsedFormat(format: .RGB10, useLosslessCompression: true)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGB10A8
    case OSType(kCVPixelFormatType_30RGBLE_8A_BiPlanar):
        return IOSurfaceUsedFormat(format: .RGB10A8, useLosslessCompression: false)
    case OSType(kCVPixelFormatType_AGX_30RGBLE_8A_BiPlanar):
        return IOSurfaceUsedFormat(format: .RGB10A8, useLosslessCompression: true)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case OSType(kCVPixelFormatType_64RGBAHalf):
        return IOSurfaceUsedFormat(format: .RGBA16F, useLosslessCompression: false)
    case OSType(kCVPixelFormatType_Lossless_64RGBAHalf):
        return IOSurfaceUsedFormat(format: .RGBA16F, useLosslessCompression: true)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case OSType(kCVPixelFormatType_64RGBALE):
        return IOSurfaceUsedFormat(format: .RGBA16, useLosslessCompression: false)
    #endif
    default:
        return nil
    }
}

// Whether an untrusted surface of `bytesPerElement`-byte pixels is non-empty, no larger than the maximum surface size,
// and has rows of at least width * bytesPerElement bytes and an allocation of at least bytesPerRow * height bytes.
private func isValidUntrustedSurface(_ surface: IOSurfaceRef, bytesPerElement: Int) -> Bool {
    let width = IOSurfaceGetWidth(surface)
    let height = IOSurfaceGetHeight(surface)
    let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
    if width == 0 || height == 0 || bytesPerRow == 0 {
        return false
    }
    let maximumSize = IOSurfaceCore.maximumSize
    if UInt(bitPattern: width) > UInt(maximumSize.width) || UInt(bitPattern: height) > UInt(maximumSize.height) {
        return false
    }
    let (rowBytes, rowBytesOverflow) = UInt(bitPattern: width).multipliedReportingOverflow(by: UInt(bytesPerElement))
    if rowBytesOverflow || rowBytes > UInt(bitPattern: bytesPerRow) {
        return false
    }
    let (totalBytes, totalBytesOverflow) = UInt(bitPattern: bytesPerRow).multipliedReportingOverflow(by: UInt(bitPattern: height))
    if totalBytesOverflow || totalBytes > UInt(bitPattern: IOSurfaceGetAllocSize(surface)) {
        return false
    }
    return true
}

// The limits Core Animation imposes. FIXME: should have API for this <rdar://problem/25454148>
private var fallbackMaximumSurfaceDimension: Int32 {
    #if os(watchOS)
    4 * 1024
    #elseif os(macOS)
    32 * 1024
    #else
    8 * 1024
    #endif
}

private func computeMaximumSurfaceSize() -> (width: Int32, height: Int32) {
    func clampedToInt32(_ value: Int) -> Int32 {
        Int32(clamping: value)
    }
    // On iOS, there's an additional 8K clamp in CA (rdar://101936907).
    // On some macOS VMs, IOSurfaceGetPropertyMaximum() returns INT_MAX (rdar://113661708).
    let width = min(clampedToInt32(IOSurfaceGetPropertyMaximum(kIOSurfaceWidth)), fallbackMaximumSurfaceDimension)
    let height = min(clampedToInt32(IOSurfaceGetPropertyMaximum(kIOSurfaceHeight)), fallbackMaximumSurfaceDimension)
    if width == 0 && height == 0 {
        return (fallbackMaximumSurfaceDimension, fallbackMaximumSurfaceDimension)
    }
    return (width, height)
}

// The maximum surface size, width in the high 32 bits and height in the low ones, or 0 until it's computed or set.
private let surfaceMaximumSize = Atomic<UInt64>(0)
private let surfaceBytesPerRowAlignment = Atomic<Int>(0)

// IOSurfacePurgeabilityState's kIOSurfacePurgeableNonVolatile, which Swift imports as the empty option set.
private let purgeableNonVolatile: UInt32 = 0

// A send right to a task identity token: what a surface keeps for the contexts it creates, and what the video renderer
// charges its decoded frames to.
final class TaskIdentityToken: Sendable {
    let port: mach_port_t

    init?(copying port: mach_port_t) {
        guard port != mach_port_t(MACH_PORT_NULL), unsafe mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, 1) == KERN_SUCCESS else {
            return nil
        }
        self.port = port
    }

    deinit {
        unsafe mach_port_deallocate(mach_task_self_, port)
    }
}

// A context that draws into an IOSurfaceCore, which IOSurfaceCore.createPlatformContext() makes, for the images of the
// surface that only such a context can make.
@_spi(WebKitGPU) public struct IOSurfacePlatformContext {
    public let context: CGContext
    fileprivate let surface: IOSurfaceCore
}

// An IOSurface: the surface, the format and colour space WebKit uses it with, and its volatility, headroom and owner.
// WebCore::IOSurface is a facade over it for C++.
// Its mutable state is behind a lock, and the surface itself is thread-safe.
@_spi(WebKitGPU) public final class IOSurfaceCore: @unchecked Sendable {
    public let surface: IOSurfaceRef
    public let width: Int32
    public let height: Int32
    public let totalBytes: Int
    public let usedFormat: IOSurfaceUsedFormat?

    private struct MutableState {
        var name: IOSurfaceName
        var colorSpace: CGColorSpace?
        var knownIsVolatile: Bool?
        var contentEDRHeadroom: Float?
        var contentsAlphaPremultiplication: WebCore.AlphaPremultiplication?
        var resourceOwner: TaskIdentityToken?
    }
    private let mutableState: Mutex<MutableState>

    private init(surface: IOSurfaceRef, width: Int32, height: Int32, usedFormat: IOSurfaceUsedFormat?, colorSpace: CGColorSpace?, name: IOSurfaceName, knownIsVolatile: Bool?) {
        self.surface = surface
        self.width = width
        self.height = height
        self.totalBytes = IOSurfaceGetAllocSize(surface)
        self.usedFormat = usedFormat
        self.mutableState = Mutex(MutableState(name: name, colorSpace: colorSpace, knownIsVolatile: knownIsVolatile))
    }

    public var name: IOSurfaceName {
        mutableState.withLock { $0.name }
    }

    private convenience init?(width: Int32, height: Int32, colorSpace: CGColorSpace, name: IOSurfaceName, format: IOSurfaceFormat, useLosslessCompression requestedLosslessCompression: Bool, alphaPremultiplication: WebCore.AlphaPremultiplication?) {
        assert(width > 0 && height > 0)

        var usedFormat = IOSurfaceUsedFormat(format: format, useLosslessCompression: requestedLosslessCompression)
        var useLosslessCompression = requestedLosslessCompression
        #if !HAVE_COREVIDEO_COMPRESSED_PIXEL_FORMAT_TYPES
        useLosslessCompression = false
        #endif
        #if ENABLE_PIXEL_FORMAT_RGBA16F
        // FIXME: Remove when rdar://156761787 is resolved.
        if format == .RGBA16F {
            useLosslessCompression = false
        }
        #endif
        #if ENABLE_PIXEL_FORMAT_RGBA16
        // CoreVideo has no lossless counterpart to kCVPixelFormatType_64RGBALE.
        if format == .RGBA16 {
            useLosslessCompression = false
        }
        #endif

        var surface: IOSurfaceRef?
        if useLosslessCompression {
            // We could allocate more formats via CoreVideo in future.
            surface = createSurfaceViaCoreVideo(width: width, height: height, name: name, format: format)
            if surface == nil {
                usedFormat = IOSurfaceUsedFormat(format: format, useLosslessCompression: false)
            }
        }
        if surface == nil {
            surface = createSurface(width: width, height: height, name: name, format: format)
        }
        guard let surface else {
            layersLog.error("IOSurface creation failed for size: (\(width) \(height)) and format: (\(format.rawValue))")
            return nil
        }

        self.init(surface: surface, width: width, height: height, usedFormat: usedFormat, colorSpace: colorSpace, name: name, knownIsVolatile: false)
        setColorSpaceProperty()
        #if HAVE_IOSURFACE_ALPHA_CHANNEL_MODE
        setContentsAlphaPremultiplication(alphaPremultiplication)
        #endif
    }

    // If colorSpace isn't nil, it replaces any colour space the surface has.
    public convenience init(surface: IOSurfaceRef, colorSpace: CGColorSpace?) {
        self.init(
            surface: surface,
            width: Int32(truncatingIfNeeded: IOSurfaceGetWidth(surface)),
            height: Int32(truncatingIfNeeded: IOSurfaceGetHeight(surface)),
            usedFormat: surfaceUsedFormat(surface),
            colorSpace: colorSpace,
            name: .Default,
            knownIsVolatile: nil
        )
        if colorSpace != nil {
            setColorSpaceProperty()
        }
    }

    public static func create(
        pool: IOSurfacePoolCore?,
        width: Int32,
        height: Int32,
        colorSpace: CGColorSpace,
        name: IOSurfaceName = .Default,
        format: IOSurfaceFormat = .BGRA,
        useLosslessCompression: Bool = false,
        alphaPremultiplication: WebCore.AlphaPremultiplication? = nil
    ) -> IOSurfaceCore? {
        if let pool, let cachedSurface = pool.takeSurface(width: width, height: height, colorSpace: colorSpace, format: format, useLosslessCompression: useLosslessCompression) {
            ioSurfaceLog.debug("IOSurface::create took from pool: \(cachedSurface.debugDescription)")
            cachedSurface.mutableState.withLock { state in
                if state.name != name {
                    IOSurfaceSetValue(cachedSurface.surface, kIOSurfaceName, name.string)
                    state.name = name
                }
            }
            #if HAVE_IOSURFACE_ALPHA_CHANNEL_MODE
            cachedSurface.setContentsAlphaPremultiplication(alphaPremultiplication)
            #endif
            return cachedSurface
        }

        guard let surface = IOSurfaceCore(width: width, height: height, colorSpace: colorSpace, name: name, format: format, useLosslessCompression: useLosslessCompression, alphaPremultiplication: alphaPremultiplication) else {
            ioSurfaceLog.debug("IOSurface::create failed to create \(width)x\(height) surface")
            return nil
        }
        ioSurfaceLog.debug("IOSurface::create created \(surface.debugDescription)")
        return surface
    }

    public static func create(pool: IOSurfacePoolCore?, image: CGImage) -> IOSurfaceCore? {
        let width = Int32(truncatingIfNeeded: image.width)
        let height = Int32(truncatingIfNeeded: image.height)
        guard let colorSpace = image.colorSpace, let surface = create(pool: pool, width: width, height: height, colorSpace: colorSpace, name: .ImageBuffer) else {
            return nil
        }
        surface.createPlatformContext()?.context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return surface
    }

    // The surface that a mach port from another process names, or nil unless it is an uncompressed surface of a format
    // WebKit draws in, whose size and rows fit its allocation.
    public static func create(untrustedUncompressedMachPort machPort: mach_port_t) -> IOSurfaceCore? {
        create(machPort: machPort, untrustedUncompressed: true)
    }

    // The surface the mach port names, or nil. With `untrustedUncompressed`, only an uncompressed surface of a format
    // WebKit draws in, whose size and rows fit its allocation.
    fileprivate static func create(machPort: mach_port_t, untrustedUncompressed: Bool) -> IOSurfaceCore? {
        guard let surface = IOSurfaceLookupFromMachPort(machPort) else {
            return nil
        }
        if untrustedUncompressed {
            let bytesPerElement: Int
            switch IOSurfaceGetPixelFormat(surface) {
            case OSType(kCVPixelFormatType_32BGRA), OSType(kCVPixelFormatType_32RGBA):
                bytesPerElement = 4
            #if ENABLE_PIXEL_FORMAT_RGB10
            case OSType(kCVPixelFormatType_30RGBLEPackedWideGamut):
                bytesPerElement = 4
            #endif
            #if ENABLE_PIXEL_FORMAT_RGBA16F
            case OSType(kCVPixelFormatType_64RGBAHalf):
                bytesPerElement = 8
            #endif
            #if ENABLE_PIXEL_FORMAT_RGBA16
            case OSType(kCVPixelFormatType_64RGBALE):
                bytesPerElement = 8
            #endif
            default:
                return nil
            }
            guard isValidUntrustedSurface(surface, bytesPerElement: bytesPerElement) else {
                return nil
            }
        }
        return IOSurfaceCore(surface: surface, colorSpace: nil)
    }

    public static var maximumSize: (width: Int32, height: Int32) {
        let size = surfaceMaximumSize.load(ordering: .relaxed)
        if size != 0 {
            return (Int32(truncatingIfNeeded: size >> 32), Int32(truncatingIfNeeded: size))
        }
        let computedSize = computeMaximumSurfaceSize()
        setMaximumSize(width: computedSize.width, height: computedSize.height)
        return computedSize
    }

    public static func setMaximumSize(width: Int32, height: Int32) {
        surfaceMaximumSize.store(UInt64(UInt32(bitPattern: width)) << 32 | UInt64(UInt32(bitPattern: height)), ordering: .relaxed)
    }

    public static var bytesPerRowAlignment: Int {
        var alignment = surfaceBytesPerRowAlignment.load(ordering: .relaxed)
        if alignment == 0 {
            alignment = IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow)

            // A return value for IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow) of 1 is invalid.
            // See https://developer.apple.com/documentation/iosurface/1419453-iosurfacegetpropertyalignment?language=objc
            // This likely means that the sandbox is blocking access to the IOSurface IOKit class,
            // and that IOSurface::bytesPerRowAlignment() has been called before IOSurface::setBytesPerRowAlignment.
            if alignment <= 1 {
                layersLog.error("Sandbox does not allow IOSurface IOKit access.")
                // 64 bytes is currently the alignment on all platforms.
                alignment = 64
            }

            surfaceBytesPerRowAlignment.store(alignment, ordering: .relaxed)
        }
        return alignment
    }

    public static func setBytesPerRowAlignment(_ alignment: Int) {
        surfaceBytesPerRowAlignment.store(alignment, ordering: .relaxed)
    }

    public static func name(for purpose: WebCore.RenderingPurpose) -> IOSurfaceName {
        switch purpose {
        case .Unspecified:
            .ImageBufferShareableMapped
        case .Canvas:
            .Canvas
        case .DOM:
            .DOM
        case .LayerBacking:
            .LayerBacking
        case .Snapshot:
            .Snapshot
        case .ShareableSnapshot:
            .ShareableSnapshot
        case .ShareableLocalSnapshot:
            .ShareableLocalSnapshot
        case .MediaPainting:
            .MediaPainting
        @unknown default:
            .Default
        }
    }

    public var debugDescription: Swift.String {
        let format = usedFormat?.format ?? .BGRX
        let compressed = usedFormat?.useLosslessCompression ?? false
        return "IOSurface \(IOSurfaceGetID(surface)) name \(name.string) size width=\(width) height=\(height) format \(format.rawValue) compressed \(compressed ? 1 : 0)"
    }

    public func hasFormat(_ format: IOSurfaceUsedFormat) -> Bool {
        usedFormat == format
    }

    public var isInUse: Bool {
        IOSurfaceIsInUse(surface)
    }

    public var bytesPerRow: Int {
        IOSurfaceGetBytesPerRow(surface)
    }

    // Images made from a surface must be released before the context it was drawn through, or an expensive GPU readback
    // can result.
    public func createImage(_ context: IOSurfacePlatformContext) -> CGImage? {
        precondition(context.surface === self)
        // The context is one of this surface's.
        return unsafe WebCore.ioSurfaceContextCreateImage(context.context)
    }

    public static func sinkIntoImage(_ surface: IOSurfaceCore, context: IOSurfacePlatformContext? = nil) -> CGImage? {
        guard let context = context ?? surface.createPlatformContext() else {
            return nil
        }
        precondition(context.surface === surface)
        // The context is one of this surface's.
        return unsafe WebCore.ioSurfaceContextCreateImageReference(context.context, false)
    }

    private struct BitmapConfiguration {
        var bitmapInfo: UInt32
        var bitsPerComponent: Int
    }

    private var bitmapConfiguration: BitmapConfiguration {
        let premultipliedFirst = CGImageAlphaInfo.premultipliedFirst.rawValue | CGImageByteOrderInfo.order32Host.rawValue
        let noneSkipFirst = CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Host.rawValue
        assert(usedFormat != nil)

        switch usedFormat?.format ?? .BGRA {
        case .BGRX, .RGBX:
            return BitmapConfiguration(bitmapInfo: noneSkipFirst, bitsPerComponent: 8)
        case .BGRA, .RGBA:
            return BitmapConfiguration(bitmapInfo: premultipliedFirst, bitsPerComponent: 8)
        case .YUV422:
            assertionFailure()
            return BitmapConfiguration(bitmapInfo: premultipliedFirst, bitsPerComponent: 8)
        #if ENABLE_PIXEL_FORMAT_RGB10
        case .RGB10:
            // A half-float format will be used if CG needs to read back the IOSurface contents,
            // but for an IOSurface-to-IOSurface copy, there should be no conversion.
            return BitmapConfiguration(bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Host.rawValue | CGImageComponentInfo.float.rawValue, bitsPerComponent: 16)
        #endif
        #if ENABLE_PIXEL_FORMAT_RGB10A8
        case .RGB10A8:
            // A half-float format will be used if CG needs to read back the IOSurface contents,
            // but for an IOSurface-to-IOSurface copy, there should be no conversion.
            return BitmapConfiguration(bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Host.rawValue | CGImageComponentInfo.float.rawValue, bitsPerComponent: 16)
        #endif
        #if ENABLE_PIXEL_FORMAT_RGBA16
        case .RGBA16:
            return BitmapConfiguration(bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue, bitsPerComponent: 16)
        #endif
        #if ENABLE_PIXEL_FORMAT_RGBA16F
        case .RGBA16F:
            return BitmapConfiguration(bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Host.rawValue | CGImageComponentInfo.float.rawValue, bitsPerComponent: 16)
        #endif
        @unknown default:
            return BitmapConfiguration(bitmapInfo: premultipliedFirst, bitsPerComponent: 8)
        }
    }

    // A context that draws into the surface. displayID picks the display on macOS, and overrideAlphaInfo replaces the
    // alpha of the format's bitmap info.
    public func createPlatformContext(displayID: UInt32 = 0, overrideAlphaInfo: CGImageAlphaInfo? = nil, useWebKitBehavior: Bool = false) -> IOSurfacePlatformContext? {
        var configuration = bitmapConfiguration
        if let overrideAlphaInfo {
            configuration.bitmapInfo = (configuration.bitmapInfo & ~CGBitmapInfo.alphaInfoMask.rawValue) | overrideAlphaInfo.rawValue
        }
        let bitsPerPixel = configuration.bitsPerComponent * 4
        let resourceOwner = mutableState.withLock { $0.resourceOwner }
        // The surface's own size, with the bits of the format it was made or looked up with.
        let context = withExtendedLifetime(resourceOwner) {
            unsafe WebCore.ioSurfaceContextCreate(
                surface,
                Int(width),
                Int(height),
                configuration.bitsPerComponent,
                bitsPerPixel,
                colorSpace,
                CGBitmapInfo(rawValue: configuration.bitmapInfo),
                useWebKitBehavior,
                displayID,
                resourceOwner?.port ?? mach_port_t(MACH_PORT_NULL)
            )
        }
        guard let context else {
            return nil
        }
        return IOSurfacePlatformContext(context: context, surface: self)
    }

    // A 64-bit surface is RGBA16F or RGBA16 whether or not its contents are opaque, so bitmapConfiguration assumes
    // premultiplied alpha. Callers presenting opaque contents must force the alpha channel to be ignored; otherwise (a
    // premultiplied WebGPU canvas) the alpha must be preserved so the contents composite transparently.
    public func createPlatformContextForNativeImage(forceOpaque: Bool) -> IOSurfacePlatformContext? {
        var overrideAlphaInfo: CGImageAlphaInfo?
        #if ENABLE_PIXEL_FORMAT_RGBA16F
        if forceOpaque && usedFormat?.format == .RGBA16F {
            overrideAlphaInfo = .noneSkipLast
        }
        #endif
        #if ENABLE_PIXEL_FORMAT_RGBA16
        if forceOpaque && usedFormat?.format == .RGBA16 {
            overrideAlphaInfo = .noneSkipLast
        }
        #endif
        return createPlatformContext(overrideAlphaInfo: overrideAlphaInfo)
    }

    // A bitmap context over the surface's memory, which the caller has locked for read and write and keeps locked while
    // it uses the context.
    fileprivate func createBitmapContextWhileLocked() -> CGContext? {
        let configuration = bitmapConfiguration
        let bytesPerRow = self.bytesPerRow
        let context = unsafe CGContext(
            data: IOSurfaceGetBaseAddress(surface),
            width: Int(width),
            height: Int(height),
            bitsPerComponent: configuration.bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: configuration.bitmapInfo
        )
        if context == nil {
            ioSurfaceLog.error("IOSurface::createBitmapPlatformContext: Failed to create bitmap context for IOSurface \(IOSurfaceGetID(self.surface), format: .hex) (size \(self.width) x \(self.height)), bitsPerComponent \(configuration.bitsPerComponent), bytesPerRow \(bytesPerRow)")
        }
        return context
    }

    // Querying volatility can be expensive, so a caller about to use the surface should use the result of setVolatile to
    // find whether the data was purged, instead of first calling state or isVolatile.
    public var state: WebCore.SetNonVolatileResult {
        mutableState.withLock { state in
            if state.knownIsVolatile == false {
                return .Valid
            }
            var currentState: UInt32 = 0
            let result = unsafe IOSurfaceSetPurgeable(surface, IOSurfacePurgeabilityState.purgeableKeepCurrent.rawValue, &currentState)
            guard result == KERN_SUCCESS else {
                assertionFailure()
                state.knownIsVolatile = nil
                return .Valid
            }
            state.knownIsVolatile = currentState != purgeableNonVolatile
            return currentState == IOSurfacePurgeabilityState.purgeableEmpty.rawValue ? .Empty : .Valid
        }
    }

    public var isVolatile: Bool {
        if mutableState.withLock({ $0.knownIsVolatile }) == nil {
            _ = state
        }
        return mutableState.withLock { $0.knownIsVolatile } ?? false
    }

    @discardableResult
    public func setVolatile(_ isVolatile: Bool) -> WebCore.SetNonVolatileResult {
        mutableState.withLock { state in
            if !isVolatile && state.knownIsVolatile == false {
                return .Valid
            }
            var previousState: UInt32 = 0
            let newState = isVolatile ? IOSurfacePurgeabilityState.purgeableVolatile.rawValue : purgeableNonVolatile
            let result = unsafe IOSurfaceSetPurgeable(surface, newState, &previousState)
            guard result == KERN_SUCCESS else {
                assertionFailure()
                state.knownIsVolatile = nil
                return .Valid
            }
            state.knownIsVolatile = isVolatile
            return previousState == IOSurfacePurgeabilityState.purgeableEmpty.rawValue ? .Empty : .Valid
        }
    }

    // The colour space the surface was made with, or the one it holds, or sRGB.
    public var colorSpace: CGColorSpace {
        mutableState.withLock { state in
            if let colorSpace = state.colorSpace {
                return colorSpace
            }
            let colorSpace = surfaceColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            state.colorSpace = colorSpace
            return colorSpace
        }
    }

    private var surfaceColorSpace: CGColorSpace? {
        guard let propertyList = IOSurfaceCopyValue(surface, kIOSurfaceColorSpace) else {
            return nil
        }
        return CGColorSpace(propertyListPlist: propertyList)
    }

    private func setColorSpaceProperty() {
        guard let propertyList = mutableState.withLock({ $0.colorSpace })?.copyPropertyList() else {
            return
        }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, propertyList)
    }

    #if HAVE_SUPPORT_HDR_DISPLAY
    public var contentEDRHeadroom: Float? {
        mutableState.withLock { $0.contentEDRHeadroom }
    }

    public func setContentEDRHeadroom(_ headroom: Float) {
        mutableState.withLock { state in
            if let current = state.contentEDRHeadroom, current == headroom {
                return
            }
            state.contentEDRHeadroom = headroom
            IOSurfaceSetValue(surface, kIOSurfaceContentHeadroom, NSNumber(value: headroom))
        }
    }

    public func loadContentEDRHeadroom() {
        var headroom: Float = 1
        if let value = IOSurfaceCopyValue(surface, kIOSurfaceContentHeadroom), CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber {
            headroom = number.floatValue
        }
        mutableState.withLock { $0.contentEDRHeadroom = headroom }
    }
    #endif

    #if HAVE_IOSURFACE_ALPHA_CHANNEL_MODE
    public func setContentsAlphaPremultiplication(_ alphaPremultiplication: WebCore.AlphaPremultiplication?) {
        mutableState.withLock { state in
            if state.contentsAlphaPremultiplication == alphaPremultiplication {
                return
            }
            state.contentsAlphaPremultiplication = alphaPremultiplication
            guard let alphaPremultiplication else {
                IOSurfaceRemoveValue(surface, kIOSurfaceAlphaChannelMode)
                return
            }
            let mode: CFString? = alphaPremultiplication == .Premultiplied ? kIOSurfaceAlphaChannelMode_PremultipliedAlpha : kIOSurfaceAlphaChannelMode_StraightAlpha
            guard let mode else {
                return
            }
            IOSurfaceSetValue(surface, kIOSurfaceAlphaChannelMode, mode)
        }
    }
    #endif

    // Charges the surface's memory to the task whose identity token this is, and draws its contexts on its behalf.
    public func setOwnershipIdentity(_ taskIdToken: mach_port_t) {
        let resourceOwner = TaskIdentityToken(copying: taskIdToken)
        mutableState.withLock { $0.resourceOwner = resourceOwner }
        Self.setOwnershipIdentity(surface, taskIdToken)
    }

    public static func setOwnershipIdentity(_ surface: IOSurfaceRef, _ taskIdToken: mach_port_t) {
        #if HAVE_IOSURFACE_SET_OWNERSHIP_IDENTITY && HAVE_TASK_IDENTITY_TOKEN
        if taskIdToken == mach_port_t(MACH_PORT_NULL) {
            return
        }
        let result = IOSurfaceSetOwnershipIdentity(surface, taskIdToken, IOSurfaceMemoryLedgerTags.graphics.rawValue, 0)
        if result != KERN_SUCCESS {
            ioSurfaceLog.error("IOSurface::setOwnershipIdentity: Failed to claim ownership of IOSurface \(IOSurfaceGetID(surface), format: .hex), task id token: \(taskIdToken), error: \(result)")
        }
        #endif
    }

    static func setOwnershipIdentity(ofImagesIn sampleBuffer: CMSampleBuffer, _ resourceOwner: TaskIdentityToken) {
        func setOwnershipIdentity<Buffer: AnyObject>(of imageBuffer: Buffer?) {
            guard let imageBuffer, CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID() else {
                return
            }
            let pixelBuffer = imageBuffer as! CVPixelBuffer
            // Safety: CVPixelBufferGetIOSurface follows the Get rule, and the sample buffer keeps the pixel buffer and its surface.
            guard let surface = unsafe CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
                return
            }
            withExtendedLifetime(resourceOwner) {
                Self.setOwnershipIdentity(surface, resourceOwner.port)
            }
        }

        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_TaggedBufferGroup
        {
            guard let group = CMSampleBufferGetTaggedBufferGroup(sampleBuffer) else {
                return
            }
            for index in 0..<CMTaggedBufferGroupGetCount(group) {
                setOwnershipIdentity(of: CMTaggedBufferGroupGetCVPixelBufferAtIndex(group, index))
            }
            return
        }
        setOwnershipIdentity(of: CMSampleBufferGetImageBuffer(sampleBuffer))
    }
}

// MARK: IOSurfacePoolCore

private let inUseCollectionInterval: DispatchTimeInterval = .milliseconds(100)
private let maintenanceQueue = DispatchQueue(label: "IOSurfacePool maintenance queue", qos: .utility)
// Tokens are unique across pools, so a cancelled collection can never match a later one.
private let lastCollectionToken = Atomic<UInt64>(0)

// Asks Core Animation to release the memory of layer contents that no longer use a surface, through a commit, which the
// web process doesn't otherwise make.
private func releaseLayerContents() {
    #if USE_WEB_THREAD
    if WTF.isWebThread() {
        return
    }
    #else
    if Thread.isMainThread {
        return
    }
    #endif
    if !Thread.isMainThread {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            releaseLayerContents()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return
    }
    CATransaction.begin()
    CATransaction.commit()
}

// A pool of surfaces that are no longer used, for reuse by size, format and colour space. WebCore::IOSurfacePool is a
// facade over it for C++.
@_spi(WebKitGPU) public final class IOSurfacePoolCore: Sendable {
    private struct SizeKey: Hashable {
        var width: Int32
        var height: Int32
    }

    // Pooled surfaces are marked volatile on insertion, so pool bytes are not charged to the owning
    // process's ledger. That makes a large pool cheap and a high hit rate valuable: every miss mints
    // a fresh non-volatile (charged) surface, while a hit just borrows uncharged bytes back. Measured
    // on apple.com/iphone-duo: 64 MB -> 84% hit rate, owned-unmapped p90/p95 518/587 MB; 256 MB ->
    // 93% and 455/483 MB, despite holding ~166 MB more surfaces.
    private static let defaultMaximumBytesCached = 256 * 1024 * 1024
    // in-use surfaces can't be immediately recycled but may be available soon. We should
    // limit caching in use surfaces so that we don't end up with a pool of surfaces we
    // can't readily recycle.
    #if os(macOS)
    private static let maximumInUseBytes = defaultMaximumBytesCached / 2
    #else
    // 32 MB is chosen for iOS as it is approximately the size of a set of front and back buffer
    // for 4 page tiles of dimensions 1024x1024. This should provide a good trade off of soon to be
    // available surfaces without contributing too much non-volatile footprint during memory pressure situations.
    private static let maximumInUseBytes = 32 * 1024 * 1024
    #endif

    private struct State {
        // Identifies the pending collection, or 0 if there is none. A collection whose token no longer matches was
        // cancelled.
        var collectionToken: UInt64 = 0
        // Each queue holds the most recently added surface first.
        var cachedSurfaces: [SizeKey: [IOSurfaceCore]] = [:]
        var inUseSurfaces: [IOSurfaceCore] = []
        var sizesInPruneOrder: [SizeKey] = []
        var bytesCached = 0
        var inUseBytesCached = 0
        var maximumBytesCached = IOSurfacePoolCore.defaultMaximumBytesCached

        func shouldCacheSurface(_ surface: IOSurfaceCore) -> Bool {
            if surface.totalBytes > maximumBytesCached {
                return false
            }
            // There's no reason to pool empty surfaces; we should never allocate them in the first place.
            // This also covers zero sizes, which would cause trouble as keys of cachedSurfaces.
            if surface.width <= 0 || surface.height <= 0 {
                return false
            }
            return true
        }

        mutating func willAddSurface(_ surface: IOSurfaceCore, inUse: Bool) -> Bool {
            let discardedAll = evict(surface.totalBytes)
            bytesCached += surface.totalBytes
            if inUse {
                inUseBytesCached += surface.totalBytes
            } else {
                surface.setVolatile(true)
            }
            return discardedAll
        }

        mutating func didRemoveSurface(_ surface: IOSurfaceCore, inUse: Bool) {
            bytesCached -= surface.totalBytes
            if inUse {
                inUseBytesCached -= surface.totalBytes
            }
        }

        mutating func removeLastPruneEntry(_ size: SizeKey) {
            if let index = sizesInPruneOrder.lastIndex(of: size) {
                sizesInPruneOrder.remove(at: index)
            }
        }

        mutating func didUseSurfaceOfSize(_ size: SizeKey) {
            removeLastPruneEntry(size)
            sizesInPruneOrder.append(size)
        }

        mutating func insertSurfaceIntoPool(_ surface: IOSurfaceCore) {
            let size = SizeKey(width: surface.width, height: surface.height)
            if cachedSurfaces[size] != nil {
                cachedSurfaces[size]!.insert(surface, at: 0)
                removeLastPruneEntry(size)
            } else {
                cachedSurfaces[size] = [surface]
            }
            sizesInPruneOrder.append(size)
        }

        mutating func tryEvictInUseSurface() {
            guard let surface = inUseSurfaces.popLast() else {
                return
            }
            didRemoveSurface(surface, inUse: true)
        }

        mutating func tryEvictOldestCachedSurface() {
            if cachedSurfaces.isEmpty {
                return
            }
            guard let size = sizesInPruneOrder.first else {
                return
            }
            guard var queue = cachedSurfaces[size], let surface = queue.popLast() else {
                // Crashes indicate that sizesInPruneOrder can contain a value not in cachedSurfaces. (rdar://177969354).
                assertionFailure()
                sizesInPruneOrder.removeFirst()
                return
            }
            didRemoveSurface(surface, inUse: false)
            if queue.isEmpty {
                cachedSurfaces[size] = nil
                sizesInPruneOrder.removeFirst()
            } else {
                cachedSurfaces[size] = queue
            }
        }

        // Whether it discarded every surface, after which the caller releases the layer contents.
        mutating func evict(_ additionalSize: Int) -> Bool {
            if additionalSize >= maximumBytesCached {
                discardAllSurfaces()
                return true
            }

            // FIXME: Perhaps purgeable surfaces should count less against the cap?
            // We don't want to end up with a ton of empty (purged) surfaces, though, as that would defeat the purpose of the pool.
            let targetSize = maximumBytesCached - additionalSize

            // Interleave eviction of old cached surfaces and more recent in-use surfaces.
            // In-use surfaces are more recently used, but less useful in the pool, as they aren't
            // immediately available when requested.
            while bytesCached > targetSize {
                tryEvictOldestCachedSurface()

                if inUseBytesCached > IOSurfacePoolCore.maximumInUseBytes || bytesCached > targetSize {
                    tryEvictInUseSurface()
                }
            }

            while inUseBytesCached > IOSurfacePoolCore.maximumInUseBytes || bytesCached > targetSize {
                tryEvictInUseSurface()
            }
            return false
        }

        mutating func collectInUseSurfaces() {
            var newInUseSurfaces: [IOSurfaceCore] = []
            for surface in inUseSurfaces {
                if surface.isInUse {
                    newInUseSurfaces.append(surface)
                    continue
                }
                inUseBytesCached -= surface.totalBytes
                surface.setVolatile(true)
                insertSurfaceIntoPool(surface)
            }
            inUseSurfaces = newInUseSurfaces
        }

        mutating func discardAllSurfaces() {
            bytesCached = 0
            inUseBytesCached = 0
            cachedSurfaces.removeAll()
            inUseSurfaces.removeAll()
            sizesInPruneOrder.removeAll()
            collectionToken = 0
        }
    }

    private let state = Mutex(State())

    public init() {
    }

    deinit {
        let hadSurfaces = state.withLock { state in
            if state.cachedSurfaces.isEmpty && state.inUseSurfaces.isEmpty {
                return false
            }
            // FIXME: Consider destroying the surfaces on the maintenance queue.
            state.cachedSurfaces.removeAll()
            state.inUseSurfaces.removeAll()
            return true
        }
        if hadSurfaces {
            releaseLayerContents()
        }
    }

    private static func surface(_ surface: IOSurfaceCore, matches format: IOSurfaceUsedFormat, colorSpace: CGColorSpace, width: Int32, height: Int32) -> Bool {
        // FIXME: It might be OK to take a surface that doesn't use compression when requesting one that does, but not the other way around.
        if !surface.hasFormat(format) {
            return false
        }
        if !CGColorSpaceEqualToColorSpace(colorSpace, surface.colorSpace) {
            return false
        }
        return surface.width == width && surface.height == height
    }

    public func takeSurface(width: Int32, height: Int32, colorSpace: CGColorSpace, format: IOSurfaceFormat, useLosslessCompression: Bool) -> IOSurfaceCore? {
        let usedFormat = IOSurfaceUsedFormat(format: format, useLosslessCompression: useLosslessCompression)
        return state.withLock { state -> IOSurfaceCore? in
            let size = SizeKey(width: width, height: height)
            if var queue = state.cachedSurfaces[size], let index = queue.firstIndex(where: { Self.surface($0, matches: usedFormat, colorSpace: colorSpace, width: width, height: height) }) {
                let surface = queue.remove(at: index)

                state.didUseSurfaceOfSize(size)

                if queue.isEmpty {
                    state.cachedSurfaces[size] = nil
                    state.sizesInPruneOrder.removeLast()
                } else {
                    state.cachedSurfaces[size] = queue
                }

                state.didRemoveSurface(surface, inUse: false)

                surface.setVolatile(false)
                return surface
            }

            // Some of the in-use surfaces may no longer actually be in-use, but we haven't moved them over yet.
            if let index = state.inUseSurfaces.firstIndex(where: { Self.surface($0, matches: usedFormat, colorSpace: colorSpace, width: width, height: height) && !$0.isInUse }) {
                let surface = state.inUseSurfaces.remove(at: index)
                state.didRemoveSurface(surface, inUse: true)

                surface.setVolatile(false)
                return surface
            }

            return nil
        }
    }

    public func addSurface(_ surface: IOSurfaceCore) {
        let discardedAll = state.withLock { state -> Bool in
            if !state.shouldCacheSurface(surface) {
                return false
            }

            let surfaceIsInUse = surface.isInUse

            let discardedAll = state.willAddSurface(surface, inUse: surfaceIsInUse)

            if surfaceIsInUse {
                state.inUseSurfaces.insert(surface, at: 0)
                scheduleCollection(&state)
                return discardedAll
            }

            state.insertSurfaceIntoPool(surface)
            return discardedAll
        }
        if discardedAll {
            releaseLayerContents()
        }
    }

    public func setPoolSize(_ poolSizeInBytes: Int) {
        let discardedAll = state.withLock { state in
            state.maximumBytesCached = poolSizeInBytes
            return state.evict(0)
        }
        if discardedAll {
            releaseLayerContents()
        }
    }

    public func discardAllSurfaces() {
        state.withLock { state in
            state.discardAllSurfaces()
        }
        releaseLayerContents()
    }

    private func scheduleCollection(_ state: inout State) {
        if state.collectionToken != 0 {
            return
        }
        let token = lastCollectionToken.add(1, ordering: .relaxed).newValue
        state.collectionToken = token
        maintenanceQueue.asyncAfter(deadline: .now() + inUseCollectionInterval) { [weak self] in
            self?.performCollection(token)
        }
    }

    private func performCollection(_ token: UInt64) {
        let collected = state.withLock { state -> Bool in
            if token != state.collectionToken {
                return false
            }
            state.collectionToken = 0
            state.collectInUseSurfaces()

            if !state.inUseSurfaces.isEmpty {
                scheduleCollection(&state)
            }
            return true
        }
        if collected {
            releaseLayerContents()
        }
    }
}

// MARK: The facades' Swift members

extension IOSurfaceCore {
    static func retained(_ surface: IOSurfaceCore?) -> UInt {
        guard let surface else {
            return 0
        }
        return UInt(bitPattern: unsafe Unmanaged.passRetained(surface).toOpaque())
    }

    // The surface a facade's swiftState refers to, which the facade keeps alive.
    static func borrowed(_ swiftState: UInt) -> IOSurfaceCore {
        unsafe Unmanaged<IOSurfaceCore>.fromOpaque(UnsafeRawPointer(bitPattern: swiftState)!).takeUnretainedValue()
    }

    fileprivate static func adopted(_ swiftState: UInt) -> IOSurfaceCore {
        unsafe Unmanaged<IOSurfaceCore>.fromOpaque(UnsafeRawPointer(bitPattern: swiftState)!).takeRetainedValue()
    }
}

extension IOSurfacePoolCore {
    static func borrowed(_ poolState: UInt) -> IOSurfacePoolCore? {
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: poolState) else {
            return nil
        }
        return unsafe Unmanaged<IOSurfacePoolCore>.fromOpaque(pointer).takeUnretainedValue()
    }
}

extension WebCore.IOSurfacePool {
    @_spi(WebKitGPU) public var core: IOSurfacePoolCore {
        IOSurfacePoolCore.borrowed(m_swiftState)!
    }
}

extension WebCore.IOSurface {
    @cxx
    @implementation
    static func createSwiftState(
        _ poolState: UInt,
        _ size: WebCore.IntSize,
        _ colorSpace: CGColorSpace?,
        _ name: WebCore.IOSurface.Name,
        _ format: WebCore.IOSurface.Format,
        _ useLosslessCompression: WebCore.UseLosslessCompression,
        _ hasAlphaPremultiplication: Bool,
        _ alphaPremultiplication: WebCore.AlphaPremultiplication
    ) -> UInt {
        guard let colorSpace else {
            return 0
        }
        return IOSurfaceCore.retained(IOSurfaceCore.create(
            pool: IOSurfacePoolCore.borrowed(poolState),
            width: size.width(),
            height: size.height(),
            colorSpace: colorSpace,
            name: name,
            format: format,
            useLosslessCompression: useLosslessCompression == .Yes,
            alphaPremultiplication: hasAlphaPremultiplication ? alphaPremultiplication : nil
        ))
    }

    @cxx
    @implementation
    static func createSwiftStateFromImage(_ poolState: UInt, _ image: CGImage?) -> UInt {
        guard let image else {
            return 0
        }
        return IOSurfaceCore.retained(IOSurfaceCore.create(pool: IOSurfacePoolCore.borrowed(poolState), image: image))
    }

    @cxx
    @implementation
    static func createSwiftStateFromSendRight(_ machPort: mach_port_t, _ untrustedUncompressed: Bool) -> UInt {
        IOSurfaceCore.retained(IOSurfaceCore.create(machPort: machPort, untrustedUncompressed: untrustedUncompressed))
    }

    @cxx
    @implementation
    static func createSwiftStateFromSurface(_ surface: IOSurfaceRef?, _ colorSpace: CGColorSpace?) -> UInt {
        guard let surface else {
            return 0
        }
        return IOSurfaceCore.retained(IOSurfaceCore(surface: surface, colorSpace: colorSpace))
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = IOSurfaceCore.adopted(swiftState)
    }

    @cxx
    @implementation
    static func describeSwiftState(_ swiftState: UInt) -> WebCore.IOSurfaceSwiftDescription {
        let surface = IOSurfaceCore.borrowed(swiftState)
        var description = WebCore.IOSurfaceSwiftDescription()
        description.width = surface.width
        description.height = surface.height
        description.totalBytes = surface.totalBytes
        description.hasFormat = surface.usedFormat != nil
        description.format = surface.usedFormat?.format ?? .BGRA
        description.useLosslessCompression = surface.usedFormat?.useLosslessCompression == true ? WebCore.UseLosslessCompression.Yes : WebCore.UseLosslessCompression.No
        return description
    }

    @cxx
    @implementation
    static func swiftStateSurface(_ swiftState: UInt) -> Unmanaged<IOSurfaceRef>? {
        unsafe Unmanaged.passUnretained(IOSurfaceCore.borrowed(swiftState).surface)
    }

    @cxx
    @implementation
    static func swiftMaximumSize() -> WebCore.IntSize {
        let size = IOSurfaceCore.maximumSize
        return WebCore.IntSize(size.width, size.height)
    }

    @cxx
    @implementation
    static func swiftSetMaximumSize(_ size: WebCore.IntSize) {
        IOSurfaceCore.setMaximumSize(width: size.width(), height: size.height())
    }

    @cxx
    @implementation
    static func swiftBytesPerRowAlignment() -> Int {
        IOSurfaceCore.bytesPerRowAlignment
    }

    @cxx
    @implementation
    static func swiftSetBytesPerRowAlignment(_ alignment: Int) {
        IOSurfaceCore.setBytesPerRowAlignment(alignment)
    }

    @cxx
    @implementation
    static func swiftNameForRenderingPurpose(_ purpose: WebCore.RenderingPurpose) -> WebCore.IOSurface.Name {
        IOSurfaceCore.name(for: purpose)
    }

    @cxx
    @implementation
    static func swiftName(_ swiftState: UInt) -> WebCore.IOSurface.Name {
        IOSurfaceCore.borrowed(swiftState).name
    }

    @cxx
    @implementation
    static func swiftNameString(_ swiftState: UInt) -> Unmanaged<CFString>? {
        unsafe Unmanaged.passRetained(IOSurfaceCore.borrowed(swiftState).name.string)
    }

    @cxx
    @implementation
    static func swiftCreatePlatformContext(_ swiftState: UInt, _ displayID: UInt32, _ hasAlphaInfo: Bool, _ alphaInfo: CGImageAlphaInfo, _ useWebKitBehavior: Bool) -> Unmanaged<CGContext>? {
        unsafe IOSurfaceCore.borrowed(swiftState).createPlatformContext(displayID: displayID, overrideAlphaInfo: hasAlphaInfo ? alphaInfo : nil, useWebKitBehavior: useWebKitBehavior).map { unsafe Unmanaged.passRetained($0.context) }
    }

    @cxx
    @implementation
    static func swiftCreatePlatformContextForNativeImage(_ swiftState: UInt, _ shouldForceOpaque: WebCore.IOSurface.ShouldForceOpaque) -> Unmanaged<CGContext>? {
        unsafe IOSurfaceCore.borrowed(swiftState).createPlatformContextForNativeImage(forceOpaque: shouldForceOpaque == .Yes).map { unsafe Unmanaged.passRetained($0.context) }
    }

    @cxx
    @implementation
    static func swiftCreateBitmapContextWhileLocked(_ swiftState: UInt) -> Unmanaged<CGContext>? {
        unsafe IOSurfaceCore.borrowed(swiftState).createBitmapContextWhileLocked().map { unsafe Unmanaged.passRetained($0) }
    }

    @cxx
    @implementation
    static func swiftState(_ swiftState: UInt) -> WebCore.SetNonVolatileResult {
        IOSurfaceCore.borrowed(swiftState).state
    }

    @cxx
    @implementation
    static func swiftIsVolatile(_ swiftState: UInt) -> Bool {
        IOSurfaceCore.borrowed(swiftState).isVolatile
    }

    @cxx
    @implementation
    static func swiftSetVolatile(_ swiftState: UInt, _ isVolatile: Bool) -> WebCore.SetNonVolatileResult {
        IOSurfaceCore.borrowed(swiftState).setVolatile(isVolatile)
    }

    @cxx
    @implementation
    static func swiftColorSpace(_ swiftState: UInt) -> Unmanaged<CGColorSpace>? {
        unsafe Unmanaged.passRetained(IOSurfaceCore.borrowed(swiftState).colorSpace)
    }

    #if HAVE_SUPPORT_HDR_DISPLAY
    @cxx
    @implementation
    static func swiftSetContentEDRHeadroom(_ swiftState: UInt, _ headroom: Float) {
        IOSurfaceCore.borrowed(swiftState).setContentEDRHeadroom(headroom)
    }

    @cxx
    @implementation
    static func swiftHasContentEDRHeadroom(_ swiftState: UInt) -> Bool {
        IOSurfaceCore.borrowed(swiftState).contentEDRHeadroom != nil
    }

    @cxx
    @implementation
    static func swiftContentEDRHeadroom(_ swiftState: UInt) -> Float {
        IOSurfaceCore.borrowed(swiftState).contentEDRHeadroom ?? 1
    }

    @cxx
    @implementation
    static func swiftLoadContentEDRHeadroom(_ swiftState: UInt) {
        IOSurfaceCore.borrowed(swiftState).loadContentEDRHeadroom()
    }
    #endif

    #if HAVE_IOSURFACE_ALPHA_CHANNEL_MODE
    @cxx
    @implementation
    static func swiftSetContentsAlphaPremultiplication(_ swiftState: UInt, _ hasAlphaPremultiplication: Bool, _ alphaPremultiplication: WebCore.AlphaPremultiplication) {
        IOSurfaceCore.borrowed(swiftState).setContentsAlphaPremultiplication(hasAlphaPremultiplication ? alphaPremultiplication : nil)
    }
    #endif

    @cxx
    @implementation
    static func swiftSetOwnershipIdentity(_ swiftState: UInt, _ taskIdToken: mach_port_t) {
        IOSurfaceCore.borrowed(swiftState).setOwnershipIdentity(taskIdToken)
    }

    @cxx
    @implementation
    static func swiftSetSurfaceOwnershipIdentity(_ surface: IOSurfaceRef?, _ taskIdToken: mach_port_t) {
        guard let surface else {
            return
        }
        IOSurfaceCore.setOwnershipIdentity(surface, taskIdToken)
    }

    @cxx
    @implementation
    static func createPoolSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(IOSurfacePoolCore()).toOpaque())
    }

    @cxx
    @implementation
    static func destroyPoolSwiftState(_ poolState: UInt) {
        unsafe Unmanaged<IOSurfacePoolCore>.fromOpaque(UnsafeRawPointer(bitPattern: poolState)!).release()
    }

    @cxx
    @implementation
    static func takePoolSurface(_ poolState: UInt, _ size: WebCore.IntSize, _ colorSpace: CGColorSpace?, _ format: WebCore.IOSurface.Format, _ useLosslessCompression: WebCore.UseLosslessCompression) -> UInt {
        guard let pool = IOSurfacePoolCore.borrowed(poolState), let colorSpace else {
            return 0
        }
        return IOSurfaceCore.retained(pool.takeSurface(width: size.width(), height: size.height(), colorSpace: colorSpace, format: format, useLosslessCompression: useLosslessCompression == .Yes))
    }

    @cxx
    @implementation
    static func addPoolSurface(_ poolState: UInt, _ swiftState: UInt) {
        let surface = IOSurfaceCore.adopted(swiftState)
        IOSurfacePoolCore.borrowed(poolState)?.addSurface(surface)
    }

    @cxx
    @implementation
    static func discardAllPoolSurfaces(_ poolState: UInt) {
        IOSurfacePoolCore.borrowed(poolState)?.discardAllSurfaces()
    }

    @cxx
    @implementation
    static func setPoolSize(_ poolState: UInt, _ poolSizeInBytes: Int) {
        IOSurfacePoolCore.borrowed(poolState)?.setPoolSize(poolSizeInBytes)
    }
}

#endif // ENABLE_WEBCORE_SWIFT && HAVE_IOSURFACE
