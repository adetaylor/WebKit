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

import CoreVideo
import Foundation
import IOSurface
import Metal
import WebGPU_Internal.BindGroup
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device
import WebGPU_Internal.Queue
import WebGPU_Private.WebGPUCpp

/// An imported frame: its planes, and the constants the shader converts them with.
///
/// All zero, with no textures, when the import fails.
struct ImportedExternalTexture {
    var texture0: (any MTLTexture)?
    var texture1: (any MTLTexture)?
    /// Every field but the visible size, which is the external texture's.
    var constants: WebGPU.Metal.ExternalTextureConstants
}

private let premultiplyAlphaShaderSource = """

    using namespace metal;
    [[kernel]] void premultiplyAlpha(texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height())
            return;

        float4 texel = source.read(gid);
        destination.write(float4(texel.rgb * texel.a, texel.a), gid);
    }
    """

private let identityUVRemapping: (Float, Float, Float, Float, Float, Float) = (1, 0, 0, 1, 0, 0)
private let identityColorSpaceConversion: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float) = (
    1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0
)

/// Imports pixel buffers as Metal textures, through a device's CoreVideo texture cache.
///
/// Owned by DeviceImpl; used only on its Instance's API thread.
final class ExternalTextureImporter {
    #if HAVE_WEBGPU_IMPLEMENTATION && (WTF_PLATFORM_MAC || WTF_PLATFORM_IOS || WTF_PLATFORM_VISION)
    /// nil for an invalid device.
    private let textureCache: CVMetalTextureCache?
    #endif
    private var premultiplyAlphaPipeline: (any MTLComputePipelineState)?

    init(metalDevice: (any MTLDevice)?) {
        #if HAVE_WEBGPU_IMPLEMENTATION && (WTF_PLATFORM_MAC || WTF_PLATFORM_IOS || WTF_PLATFORM_VISION)
        textureCache = metalDevice.flatMap { makeTextureCache($0) }
        #endif
    }

    /// Imports the planes of a frame, with the constants that convert them to `colorSpace`.
    ///
    /// A single-plane frame's color is premultiplied into a copy when it is imported for sampling, because
    /// textureSampleBaseClampToEdge() has to filter premultiplied color rather than premultiply what the sampler
    /// filtered. copyExternalImageToTexture() carries the frame's color through unchanged instead, and asks for the
    /// planes as they arrived. A nil pixel buffer (a destroyed external texture) fails.
    func importPixelBuffer(
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ pixelBuffer: CVPixelBuffer?,
        _ colorSpace: WebGPU.PredefinedColorSpace,
        premultiplyAlpha: Bool
    ) -> ImportedExternalTexture {
        let failure = ImportedExternalTexture(texture0: nil, texture1: nil, constants: WebGPU.Metal.ExternalTextureConstants())
        // HAVE(COREVIDEO_METAL_SUPPORT), whose CoreVideo macro Swift cannot see: Queue.mm checks that the two agree.
        #if HAVE_WEBGPU_IMPLEMENTATION && (WTF_PLATFORM_MAC || WTF_PLATFORM_IOS || WTF_PLATFORM_VISION)
        var constants = WebGPU.Metal.ExternalTextureConstants()
        // The conversion is row-major, and Metal indexes a float3x3 by column. All zero, which no real conversion can be,
        // when the frame's primaries already are the destination's.
        if let matrix = pixelBufferPrimariesConversionMatrix(pixelBuffer, colorSpace) {
            constants.primariesConversion = (
                matrix[0], matrix[3], matrix[6], matrix[1], matrix[4], matrix[7], matrix[2], matrix[5], matrix[8]
            )
        }

        var premultiplyParameters = PremultiplyParameters()
        if premultiplyAlpha, let pixelBuffer {
            premultiplyParameters = premultiplyAlphaParameters(pixelBuffer)
        }

        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        let supportsExtendedFormats = device.device()?.supportsFamily(.apple4) ?? false
        guard let pixelBuffer else {
            return failure
        }
        if pixelBufferIOSurface(pixelBuffer) == nil || device.isIntel() {
            return importByCopying(device, pixelBuffer, constants, premultiplyParameters, supportsExtendedFormats) ?? failure
        }
        return importThroughTextureCache(device, deviceImpl, pixelBuffer, constants, premultiplyParameters, supportsExtendedFormats)
            ?? failure
        #else
        return failure
        #endif
    }

    // A frame without an IOSurface (or any frame on Intel) has its planes copied into new textures.
    private func importByCopying(
        _ device: WebGPU.Metal.Device,
        _ pixelBuffer: CVPixelBuffer,
        _ constants: WebGPU.Metal.ExternalTextureConstants,
        _ premultiplyParameters: PremultiplyParameters,
        _ supportsExtendedFormats: Bool
    ) -> ImportedExternalTexture? {
        let planeCount = max(CVPixelBufferGetPlaneCount(pixelBuffer), 1)
        if planeCount > 2 {
            assertionFailure("non-IOSurface CVPixelBuffer instances with more than two planes are not supported")
            return nil
        }

        if CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) != kCVReturnSuccess {
            return nil
        }

        var firstPlaneSwizzle: MTLTextureSwizzleChannels?
        var textures: [(any MTLTexture)?] = [nil, nil]
        for plane in 0..<planeCount {
            let width = Int32(truncatingIfNeeded: CVPixelBufferGetWidthOfPlane(pixelBuffer, plane))
            let height = Int32(truncatingIfNeeded: CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))

            let descriptor = MTLTextureDescriptor()
            descriptor.usage = .shaderRead
            descriptor.textureType = .type2D
            descriptor.width = Int(width)
            descriptor.height = Int(height)
            // One swizzle for every plane: only single-plane formats have one.
            descriptor.pixelFormat = planeFormat(pixelBuffer, plane, supportsExtendedFormats, &firstPlaneSwizzle)
            if let firstPlaneSwizzle {
                descriptor.swizzle = firstPlaneSwizzle
            }
            descriptor.mipmapLevelCount = 1
            descriptor.sampleCount = 1
            descriptor.storageMode = externalTexturePlaneStorageMode(device.hasUnifiedMemory())

            // FIXME: This failure leaves the base address locked.
            guard let texture = device.device()?.makeTexture(descriptor: descriptor) else {
                return nil
            }
            WebGPU.Metal.copyPixelBufferPlane(texture, pixelBuffer, plane, copiedBytesPerPixel(descriptor.pixelFormat))
            textures[plane] = texture
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        var result = ImportedExternalTexture(texture0: textures[0], texture1: textures[1], constants: constants)
        result.constants.uvRemapping = identityUVRemapping
        if planeCount > 1 {
            result.constants.colorSpaceConversion = yCbCrToRGBMatrix(pixelBuffer)
        } else {
            result.constants.colorSpaceConversion = identityColorSpaceConversion
            let premultiplied = premultipliedAlphaTexture(device, textures[0], premultiplyParameters)
            if let premultiplied {
                result.texture0 = premultiplied
            }
            // The premultiplied copy is in natural RGBA order, whatever order the frame arrived in.
            result.texture1 = gbTexture(
                fromRGB: result.texture0,
                alphaFirst: premultiplied == nil && firstPlaneSwizzle != nil,
                premultiplied: premultiplied != nil
            )
        }
        return result
    }

    #if HAVE_WEBGPU_IMPLEMENTATION && (WTF_PLATFORM_MAC || WTF_PLATFORM_IOS || WTF_PLATFORM_VISION)
    // An IOSurface-backed frame's planes are wrapped by the CoreVideo texture cache, without a copy.
    private func importThroughTextureCache(
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ pixelBuffer: CVPixelBuffer,
        _ constants: WebGPU.Metal.ExternalTextureConstants,
        _ premultiplyParameters: PremultiplyParameters,
        _ supportsExtendedFormats: Bool
    ) -> ImportedExternalTexture? {
        if let surface = pixelBufferIOSurface(pixelBuffer) {
            setIOSurfaceOwnershipIdentity(surface, deviceImpl)
        }

        var firstPlaneSwizzle: MTLTextureSwizzleChannels?
        var secondPlaneSwizzle: MTLTextureSwizzleChannels?
        var plane0: CVMetalTexture?
        var plane1: CVMetalTexture?
        if CVPixelBufferGetPlaneCount(pixelBuffer) < 2 {
            let format = planeFormat(pixelBuffer, 0, supportsExtendedFormats, &firstPlaneSwizzle)
            plane0 = makeTextureCachePlane(textureCache, pixelBuffer, format, 0)
        } else {
            let format0 = planeFormat(pixelBuffer, 0, supportsExtendedFormats, &firstPlaneSwizzle)
            if format0 != .invalid {
                plane0 = makeTextureCachePlane(textureCache, pixelBuffer, format0, 0)
            }
            let format1 = planeFormat(pixelBuffer, 1, supportsExtendedFormats, &secondPlaneSwizzle)
            if format1 != .invalid {
                plane1 = makeTextureCachePlane(textureCache, pixelBuffer, format1, 1)
            }
        }

        guard let plane0 else {
            return nil
        }
        var baseTexture = CVMetalTextureGetTexture(plane0)
        var texture0 = baseTexture
        device.setOwnerWithIdentity(texture0)
        let texCoords = WebGPU.Metal.cleanTexCoords(plane0)
        if let firstPlaneSwizzle {
            texture0 = textureView(texture0, swizzle: firstPlaneSwizzle)
        }

        var texture1: (any MTLTexture)?
        if let plane1 {
            texture1 = CVMetalTextureGetTexture(plane1)
            device.setOwnerWithIdentity(texture1)
            if let secondPlaneSwizzle {
                texture1 = textureView(texture1, swizzle: secondPlaneSwizzle)
            }
        }

        // The cache's textures stay valid only while their CVMetalTextures live: until the queue's submitted work is done.
        deviceImpl.defaultQueueImpl.retainUntilSubmittedWorkDone(
            deviceImpl.defaultQueue(),
            deviceImpl.isValid() && !deviceImpl.isLost(),
            plane0,
            plane1
        )

        let ax = 1 / (texCoords.upperRightX - texCoords.lowerLeftX)
        let bx = -ax * texCoords.lowerLeftX
        let ay = 1 / (texCoords.lowerRightY - texCoords.upperLeftY)
        let by = -ay * texCoords.upperLeftY
        var result = ImportedExternalTexture(texture0: texture0, texture1: texture1, constants: constants)
        result.constants.uvRemapping = (ax, 0, 0, ay, bx, by)
        if texture1 != nil {
            result.constants.colorSpaceConversion = yCbCrToRGBMatrix(pixelBuffer)
        } else {
            result.constants.colorSpaceConversion = identityColorSpaceConversion
            let premultiplied = premultipliedAlphaTexture(device, baseTexture, premultiplyParameters)
            if let premultiplied {
                result.texture0 = premultiplied
                baseTexture = premultiplied
            }
            // The premultiplied copy is in natural RGBA order, whatever order the frame arrived in.
            result.texture1 = gbTexture(
                fromRGB: baseTexture,
                alphaFirst: premultiplied == nil && firstPlaneSwizzle != nil,
                premultiplied: premultiplied != nil
            )
        }
        return result
    }
    #endif

    // Sets `swizzle` only for the formats that need one, and never clears it.
    private func planeFormat(
        _ pixelBuffer: CVPixelBuffer,
        _ plane: Int,
        _ supportsExtendedFormats: Bool,
        _ swizzle: inout MTLTextureSwizzleChannels?
    ) -> MTLPixelFormat {
        let format = externalTexturePlaneFormat(pixelBuffer, plane, supportsExtendedFormats)
        if let planeSwizzle = format.swizzle {
            swizzle = planeSwizzle
        }
        return format.pixelFormat
    }

    // nil when the parameters leave the frame alone, or when anything fails.
    private func premultipliedAlphaTexture(
        _ device: WebGPU.Metal.Device,
        _ source: (any MTLTexture)?,
        _ parameters: PremultiplyParameters
    ) -> (any MTLTexture)? {
        if parameters.destinationFormat == .invalid {
            return nil
        }
        guard let pipeline = premultiplyPipeline(device), let source else {
            return nil
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.textureType = .type2D
        descriptor.width = source.width
        descriptor.height = source.height
        descriptor.pixelFormat = parameters.destinationFormat
        descriptor.mipmapLevelCount = 1
        descriptor.sampleCount = 1
        descriptor.storageMode = .private

        guard let destination = device.device()?.makeTexture(descriptor: descriptor) else {
            return nil
        }
        device.setOwnerWithIdentity(destination)

        let input: (any MTLTexture)?
        if let sourceSwizzle = parameters.sourceSwizzle {
            input = textureView(source, swizzle: sourceSwizzle)
        } else {
            input = source
        }

        // The pass goes on the default queue, so the commands the page submits afterwards see the result
        // without any further synchronization.
        let queue = device.getQueue().ptr()
        guard let commandBuffer = queue.commandBufferWithDescriptor(MTLCommandBufferDescriptor()) else {
            return nil
        }

        let passDescriptor = MTLComputePassDescriptor()
        passDescriptor.dispatchType = .serial
        let computeEncoder = commandBuffer.makeComputeCommandEncoder(descriptor: passDescriptor)
        queue.setEncoderForBuffer(commandBuffer, computeEncoder)
        computeEncoder?.setComputePipelineState(pipeline)
        computeEncoder?.setTexture(input, index: 0)
        computeEncoder?.setTexture(destination, index: 1)
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let inputWidth = input?.width ?? 0
        let inputHeight = input?.height ?? 0
        let threadgroupCount = MTLSize(
            width: (inputWidth &+ threadgroupSize.width &- 1) / threadgroupSize.width,
            height: (inputHeight &+ threadgroupSize.height &- 1) / threadgroupSize.height,
            depth: 1
        )
        computeEncoder?.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        queue.endEncoding(computeEncoder, commandBuffer)
        queue.commitMTLCommandBuffer(commandBuffer)

        return destination
    }

    // Built on first use; a failure is retried next time.
    private func premultiplyPipeline(_ device: WebGPU.Metal.Device) -> (any MTLComputePipelineState)? {
        if let premultiplyAlphaPipeline {
            return premultiplyAlphaPipeline
        }
        guard let metalDevice = device.device() else {
            return nil
        }

        let library: any MTLLibrary
        do {
            library = try metalDevice.makeLibrary(source: premultiplyAlphaShaderSource, options: nil)
        } catch {
            WebGPU.Metal.logAlways("\(error as NSError)")
            return nil
        }
        guard let function = library.makeFunction(name: "premultiplyAlpha") else {
            return nil
        }
        do {
            premultiplyAlphaPipeline = try metalDevice.makeComputePipelineState(function: function)
        } catch {
            WebGPU.Metal.logAlways("\(error as NSError)")
        }
        return premultiplyAlphaPipeline
    }
}

// MARK: CoreVideo and IOSurface helpers

// The frame's IOSurface, which the frame keeps alive.
func pixelBufferIOSurface(_ pixelBuffer: CVPixelBuffer) -> IOSurfaceRef? {
    WebGPU.Metal.pixelBufferIOSurface(pixelBuffer)
}

// Attributes the surface's memory to the web process, when the Instance has its identity. The right is kept alive
// for as long as its port name is used.
func setIOSurfaceOwnershipIdentity(_ surface: IOSurfaceRef, _ deviceImpl: DeviceImpl) {
    let webProcessID = deviceImpl.adapter().webProcessIdentity()
    withExtendedLifetime(webProcessID) {
        let port = webProcessID.sendRight()
        if port != MACH_PORT_NULL {
            _ = IOSurfaceSetOwnershipIdentity(surface, port, IOSurfaceMemoryLedgerTags.graphics.rawValue, 0)
        }
    }
}

#if HAVE_WEBGPU_IMPLEMENTATION && (WTF_PLATFORM_MAC || WTF_PLATFORM_IOS || WTF_PLATFORM_VISION)
private func makeTextureCache(_ device: any MTLDevice) -> CVMetalTextureCache? {
    WebGPU.Metal.createCoreVideoTextureCache(device)
}

// nil unless CoreVideo succeeded, which it cannot without a cache.
private func makeTextureCachePlane(
    _ cache: CVMetalTextureCache?,
    _ pixelBuffer: CVPixelBuffer,
    _ pixelFormat: MTLPixelFormat,
    _ plane: Int
) -> CVMetalTexture? {
    guard let cache else {
        return nil
    }
    return WebGPU.Metal.createCoreVideoPlaneTexture(cache, pixelBuffer, pixelFormat, plane)
}
#endif

private func externalTexturePlaneStorageMode(_ hasUnifiedMemory: Bool) -> MTLStorageMode {
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    hasUnifiedMemory ? .shared : deprecatedManagedStorageMode
    #else
    hasUnifiedMemory ? .shared : .private
    #endif
}

private func textureView(_ texture: (any MTLTexture)?, swizzle: MTLTextureSwizzleChannels) -> (any MTLTexture)? {
    guard let texture else {
        return nil
    }
    return texture.makeTextureView(
        pixelFormat: texture.pixelFormat,
        textureType: texture.textureType,
        levels: 0..<texture.mipmapLevelCount,
        slices: 0..<texture.arrayLength,
        swizzle: swizzle
    )
}

// A single-plane frame has no chroma plane, so it gets a view of its own texture holding the two
// channels the shader expects to find in a second plane, plus the frame's alpha in the channel a real chroma plane
// leaves at 1. That gives the shader one way to reach a frame's alpha whether the frame was decoded or came from a
// canvas. The blue channel, which a real chroma plane samples as 0, tells the shader whether plane 0 already holds
// premultiplied color.
private func gbTexture(fromRGB texture: (any MTLTexture)?, alphaFirst: Bool, premultiplied: Bool) -> (any MTLTexture)? {
    let premultipliedChannel: MTLTextureSwizzle = premultiplied ? .one : .zero
    let swizzle =
        alphaFirst
        ? MTLTextureSwizzleChannels(red: .blue, green: .alpha, blue: premultipliedChannel, alpha: .red)
        : MTLTextureSwizzleChannels(red: .green, green: .blue, blue: premultipliedChannel, alpha: .alpha)
    return textureView(texture, swizzle: swizzle)
}

// MARK: CoreVideo frame formats

// Private CoreVideo formats (CVPixelBufferPrivate.h).
private let pixelFormat420YpCbCr10PackedBiPlanarVideoRange: OSType = 0x7034_3230 // 'p420'
private let pixelFormat422YpCbCr10PackedBiPlanarVideoRange: OSType = 0x7034_3232 // 'p422'
private let pixelFormat444YpCbCr10PackedBiPlanarVideoRange: OSType = 0x7034_3434 // 'p444'

// The swizzle of the alpha-first formats.
private var greenToRedSwizzle: MTLTextureSwizzleChannels {
    MTLTextureSwizzleChannels(red: .green, green: .zero, blue: .zero, alpha: .zero)
}

// The SPI YCbCr Metal pixel formats (MTLPixelFormat_Private.h; MetalSPI.h declares the same values on the public SDK)
// the import picks for the first plane of some 8- and 10-bit frames when the device supports them.
private enum ExtendedPixelFormat: UInt {
    case ycbcr8Bit422OnePlane = 501
    case ycbcr10Bit444OnePlane = 504
    case ycbcr10Bit420TwoPlane = 505
    case ycbcr10Bit422TwoPlane = 506
    case ycbcr10Bit444TwoPlane = 507
    case ycbcr10Bit420TwoPlanePacked = 508
    case ycbcr10Bit422TwoPlanePacked = 509
    case ycbcr10Bit444TwoPlanePacked = 510
    case ycbcr10Bit420TwoPlanePackedPQ = 567

    var pixelFormat: MTLPixelFormat {
        MTLPixelFormat(rawValue: rawValue) ?? .invalid
    }
}

// The Metal format of one plane of a frame (.invalid for the formats nothing here reads), and the
// swizzle that plane needs. Reached only where the import is supported.
private func externalTexturePlaneFormat(
    _ pixelBuffer: CVPixelBuffer,
    _ plane: Int,
    _ supportsExtendedFormats: Bool
) -> (pixelFormat: MTLPixelFormat, swizzle: MTLTextureSwizzleChannels?) {
    let biplanarFormat: MTLPixelFormat = plane != 0 ? .rg8Unorm : .r8Unorm
    // An SPI YCbCr format for the first plane, on devices that support them.
    func firstPlaneFormat(_ format: ExtendedPixelFormat) -> MTLPixelFormat {
        plane == 0 && supportsExtendedFormats ? format.pixelFormat : biplanarFormat
    }

    switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
    case kCVPixelFormatType_1Monochrome,
        kCVPixelFormatType_2Indexed,
        kCVPixelFormatType_4Indexed,
        kCVPixelFormatType_8Indexed,
        kCVPixelFormatType_1IndexedGray_WhiteIsZero,
        kCVPixelFormatType_2IndexedGray_WhiteIsZero,
        kCVPixelFormatType_4IndexedGray_WhiteIsZero,
        kCVPixelFormatType_8IndexedGray_WhiteIsZero:
        return (.a8Unorm, nil)
    case kCVPixelFormatType_16BE555,
        kCVPixelFormatType_16LE555,
        kCVPixelFormatType_16LE5551:
        return (.bgr5A1Unorm, nil)
    case kCVPixelFormatType_16BE565,
        kCVPixelFormatType_16LE565:
        return (.b5g6r5Unorm, nil)
    case kCVPixelFormatType_24RGB:
        return (.rgba8Unorm, nil)
    case kCVPixelFormatType_32ABGR:
        return (.bgra8Unorm, greenToRedSwizzle)
    case kCVPixelFormatType_32ARGB:
        return (.rgba8Unorm, greenToRedSwizzle)
    case kCVPixelFormatType_24BGR,
        kCVPixelFormatType_32BGRA:
        return (.bgra8Unorm, nil)
    case kCVPixelFormatType_32RGBA:
        return (.rgba8Unorm, nil)
    case kCVPixelFormatType_64ARGB:
        return (.rgba16Unorm, greenToRedSwizzle)
    case kCVPixelFormatType_64RGBALE:
        return (.rgba16Unorm, nil)
    case kCVPixelFormatType_48RGB:
        assertionFailure("unexpected pixel format")
        return (.bgra8Unorm, nil)
    case kCVPixelFormatType_32AlphaGray:
        return (.r32Float, nil)
    case kCVPixelFormatType_16Gray:
        return (.r16Float, nil)
    case kCVPixelFormatType_30RGB:
        return (.bgr10a2Unorm, nil)
    case kCVPixelFormatType_422YpCbCr8:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_4444YpCbCrA8,
        kCVPixelFormatType_4444YpCbCrA8R,
        kCVPixelFormatType_4444AYpCbCr8,
        kCVPixelFormatType_4444AYpCbCr16:
        assertionFailure("unexpected pixel format")
        return (.bgra8Unorm, nil)
    case kCVPixelFormatType_444YpCbCr8:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_422YpCbCr16:
        assertionFailure("unexpected pixel format")
        return (biplanarFormat, nil)
    case kCVPixelFormatType_422YpCbCr10:
        return (firstPlaneFormat(.ycbcr8Bit422OnePlane), nil)
    case kCVPixelFormatType_444YpCbCr10:
        return (firstPlaneFormat(.ycbcr10Bit444OnePlane), nil)
    case kCVPixelFormatType_420YpCbCr8Planar:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_422YpCbCr_4A_8BiPlanar:
        // The second plane is 8-bit alpha, not two-channel chroma.
        return (.r8Unorm, nil)
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_422YpCbCr8_yuvs,
        kCVPixelFormatType_422YpCbCr8FullRange:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_OneComponent8:
        return (.r8Unorm, nil)
    case kCVPixelFormatType_TwoComponent8:
        return (.rg8Unorm, nil)
    case kCVPixelFormatType_30RGBLEPackedWideGamut:
        return (.rgb10a2Unorm, nil)
    case kCVPixelFormatType_ARGB2101010LEPacked:
        return (.rgb10a2Unorm, greenToRedSwizzle)
    case kCVPixelFormatType_40ARGBLEWideGamut,
        kCVPixelFormatType_40ARGBLEWideGamutPremultiplied:
        return (.invalid, nil)
    case kCVPixelFormatType_OneComponent10:
        return (.invalid, nil)
    case kCVPixelFormatType_OneComponent12:
        return (.invalid, nil)
    case kCVPixelFormatType_OneComponent16:
        return (.r16Unorm, nil)
    case kCVPixelFormatType_TwoComponent16:
        return (.rg16Unorm, nil)
    case kCVPixelFormatType_OneComponent16Half:
        return (.r16Float, nil)
    case kCVPixelFormatType_OneComponent32Float:
        return (.r32Float, nil)
    case kCVPixelFormatType_TwoComponent16Half:
        return (.rg16Float, nil)
    case kCVPixelFormatType_TwoComponent32Float:
        return (.rg32Float, nil)
    case kCVPixelFormatType_64RGBAHalf:
        return (.rgba16Float, nil)
    case kCVPixelFormatType_128RGBAFloat:
        return (.rgba32Float, nil)
    case kCVPixelFormatType_14Bayer_GRBG,
        kCVPixelFormatType_14Bayer_RGGB,
        kCVPixelFormatType_14Bayer_BGGR,
        kCVPixelFormatType_14Bayer_GBRG:
        assertionFailure("unexpected pixel format")
        return (.r16Unorm, nil)
    case kCVPixelFormatType_DisparityFloat16:
        assertionFailure("unexpected pixel format")
        return (.r16Float, nil)
    case kCVPixelFormatType_DisparityFloat32:
        assertionFailure("unexpected pixel format")
        return (.bgra8Unorm, nil)
    case kCVPixelFormatType_DepthFloat16:
        return (.depth16Unorm, nil)
    case kCVPixelFormatType_DepthFloat32:
        return (.depth32Float, nil)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit420TwoPlane), nil)
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit422TwoPlane), nil)
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit444TwoPlane), nil)
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        return (firstPlaneFormat(.ycbcr10Bit422TwoPlane), nil)
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        return (firstPlaneFormat(.ycbcr10Bit422TwoPlane), nil)
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        return (firstPlaneFormat(.ycbcr10Bit444TwoPlane), nil)
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_16VersatileBayer:
        assertionFailure("unexpected pixel format")
        return (.r16Unorm, nil)
    case kCVPixelFormatType_64RGBA_DownscaledProResRAW:
        assertionFailure("unexpected pixel format")
        return (.bgra8Unorm, nil)
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
        assertionFailure("unexpected pixel format")
        return (.invalid, nil)
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
        assertionFailure("unexpected pixel format")
        return (.invalid, nil)
    case kCVPixelFormatType_Lossless_32BGRA:
        return (.bgra8Unorm, nil)
    case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit420TwoPlanePacked), nil)
    case kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit422TwoPlanePacked), nil)
    case kCVPixelFormatType_Lossy_32BGRA:
        return (.bgra8Unorm, nil)
    case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
        return (biplanarFormat, nil)
    case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit420TwoPlanePackedPQ), nil)
    case kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit422TwoPlanePacked), nil)
    case pixelFormat420YpCbCr10PackedBiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit420TwoPlanePacked), nil)
    case pixelFormat422YpCbCr10PackedBiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit422TwoPlanePacked), nil)
    case pixelFormat444YpCbCr10PackedBiPlanarVideoRange:
        return (firstPlaneFormat(.ycbcr10Bit444TwoPlanePacked), nil)
    default:
        return (.invalid, nil)
    }
}

// The bytes of a plane that replaceRegion() reads for each pixel of a texture of `format`, for every format
// externalTexturePlaneFormat() returns; 0 for the two-plane YCbCr formats, whose plane layout this cannot bound.
private func copiedBytesPerPixel(_ format: MTLPixelFormat) -> Int {
    switch format {
    case .a8Unorm, .r8Unorm:
        return 1
    case .bgr5A1Unorm, .b5g6r5Unorm, .rg8Unorm, .r16Unorm, .r16Float, .depth16Unorm:
        return 2
    case .rgba8Unorm, .bgra8Unorm, .bgr10a2Unorm, .rgb10a2Unorm, .r32Float, .rg16Unorm, .rg16Float, .depth32Float:
        return 4
    case .rgba16Unorm, .rgba16Float, .rg32Float:
        return 8
    case .rgba32Float:
        return 16
    default:
        switch ExtendedPixelFormat(rawValue: format.rawValue) {
        case .ycbcr8Bit422OnePlane:
            return 2
        case .ycbcr10Bit444OnePlane:
            return 4
        default:
            return 0
        }
    }
}

private enum PixelRange {
    case video
    case full
}

private func pixelRange(_ pixelFormat: OSType) -> PixelRange {
    switch pixelFormat {
    case kCVPixelFormatType_4444AYpCbCr8,
        kCVPixelFormatType_4444AYpCbCr16,
        kCVPixelFormatType_422YpCbCr_4A_8BiPlanar,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        return .video
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8FullRange,
        kCVPixelFormatType_ARGB2101010LEPacked,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        return .full
    // kCVPixelFormatType_AGX_420YpCbCr8BiPlanarFullRange has the same code ('&8f0'), and is full range only where the
    // SDK has the compressed formats. Its video-range sibling ('&8v0') is video range either way, like the default.
    #if HAVE_COREVIDEO_COMPRESSED_PIXEL_FORMAT_TYPES
    case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange:
        return .full
    #endif
    default:
        return .video
    }
}

private enum YCbCrMatrix {
    case itur709
    case itur601
    case smpte240M
    case itur2020
}

// The frame's YCbCr matrix attachment, ITU-R BT.709 when it has none.
private func yCbCrMatrix(_ pixelBuffer: CVPixelBuffer) -> YCbCrMatrix {
    guard let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) else {
        return .itur709
    }
    if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
        return .itur709
    }
    if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
        return .itur601
    }
    if CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
        return .smpte240M
    }
    if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
        return .itur2020
    }
    assertionFailure("Unexpected transfer function format")
    return .itur709
}

// Flattened column-major, as ExternalTextureConstants.colorSpaceConversion. Columns are the Y, Cb, Cr and constant
// terms of the YCbCr-to-RGB conversion, over inputs normalized by 255 rather than 256, which is what sampling an 8-bit
// Metal texture gives. Each is derived from the standard's luma coefficients: R = Y' + 2(1-Kr)Cr', B = Y' + 2(1-Kb)Cb',
// and G from the remainder, where a video-range Y' is (255Y - 16)/219 and a video-range chroma is (255C - 128)/224.
private func yCbCrToRGBMatrix(
    _ pixelBuffer: CVPixelBuffer
) -> (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float) {
    let range = pixelRange(CVPixelBufferGetPixelFormatType(pixelBuffer))
    switch (yCbCrMatrix(pixelBuffer), range) {
    case (.itur709, .full):
        return (
            1.00000000, 1.00000000, 1.00000000,
            0.00000000, -0.18732430, 1.85560000,
            1.57480000, -0.46813550, 0.00000000,
            -0.79048784, 0.32901511, -0.93143764
        )
    case (.itur709, .video):
        return (
            1.16438356, 1.16438356, 1.16438356,
            0.00000000, -0.21324866, 2.11240177,
            1.79274106, -0.53292211, 0.00000000,
            -0.97294507, 0.30148910, -1.13340221
        )
    case (.itur601, .full):
        return (
            1.00000000, 1.00000000, 1.00000000,
            0.00000000, -0.34413628, 1.77200000,
            1.40200000, -0.71413629, 0.00000000,
            -0.70374902, 0.53121133, -0.88947451
        )
    case (.itur601, .video):
        return (
            1.16438356, 1.16438356, 1.16438356,
            0.00000000, -0.39176200, 2.01723214,
            1.59602678, -0.81296769, 0.00000000,
            -0.87420221, 0.53166750, -1.08563078
        )
    case (.smpte240M, .full):
        return (
            1.00000000, 1.00000000, 1.00000000,
            0.00000000, -0.22662197, 1.82600000,
            1.57600000, -0.47662197, 0.00000000,
            -0.79109020, 0.35300088, -0.91658039
        )
    case (.smpte240M, .video):
        return (
            1.16438356, 1.16438356, 1.16438356,
            0.00000000, -0.25798483, 2.07870536,
            1.79410714, -0.54258304, 0.00000000,
            -0.97363079, 0.32879432, -1.11648793
        )
    case (.itur2020, .full):
        return (
            1.00000000, 1.00000000, 1.00000000,
            0.00000000, -0.16455310, 1.88140000,
            1.47460000, -0.57135310, 0.00000000,
            -0.74019137, 0.36939605, -0.94438902
        )
    case (.itur2020, .video):
        return (
            1.16438356, 1.16438356, 1.16438356,
            0.00000000, -0.18732607, 2.14177231,
            1.67867410, -0.65042428, 0.00000000,
            -0.91568793, 0.34745847, -1.14814507
        )
    }
}

// An .invalid destination format leaves the frame alone.
private struct PremultiplyParameters {
    var destinationFormat: MTLPixelFormat = .invalid
    var sourceSwizzle: MTLTextureSwizzleChannels?
}

// A single-plane frame carries straight alpha, but textureSampleBaseClampToEdge() has to return premultiplied color, and
// premultiplying after the sampler has filtered the plane is not the same as filtering color that was already
// premultiplied. So the color is premultiplied into a copy before the sampler ever sees it. Because the copy is in
// natural RGBA order, the alpha-first formats need their permutation undone on the way in: those reach Metal as a format
// naming a different channel order, which is also why they carry a swizzle out of externalTexturePlaneFormat(). An
// .invalid destination means "leave this frame alone", either because nothing here can premultiply the format or
// because the frame's alpha is not straight to begin with.
private func premultiplyAlphaParameters(_ pixelBuffer: CVPixelBuffer) -> PremultiplyParameters {
    if !alphaIsStraight(pixelBuffer) {
        return PremultiplyParameters()
    }

    // Alpha comes first in memory, so every channel is one place further along than the Metal format says: red is in
    // green, green in blue, blue in alpha, and alpha in red.
    let alphaFirstSwizzle = MTLTextureSwizzleChannels(red: .green, green: .blue, blue: .alpha, alpha: .red)

    switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA:
        return PremultiplyParameters(destinationFormat: .rgba8Unorm)
    case kCVPixelFormatType_32ARGB:
        return PremultiplyParameters(destinationFormat: .rgba8Unorm, sourceSwizzle: alphaFirstSwizzle)
    case kCVPixelFormatType_64RGBALE:
        return PremultiplyParameters(destinationFormat: .rgba16Unorm)
    case kCVPixelFormatType_64ARGB:
        return PremultiplyParameters(destinationFormat: .rgba16Unorm, sourceSwizzle: alphaFirstSwizzle)
    default:
        return PremultiplyParameters()
    }
}

// Neither marked opaque nor premultiplied.
private func alphaIsStraight(_ pixelBuffer: CVPixelBuffer) -> Bool {
    #if HAVE_WEBGPU_IMPLEMENTATION && (WTF_PLATFORM_MAC || WTF_PLATFORM_IOS || WTF_PLATFORM_VISION)
    if let opaque = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferAlphaChannelIsOpaque, nil), opaque === kCFBooleanTrue {
        return false
    }
    if let alphaMode = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferAlphaChannelModeKey, nil),
        CFEqual(alphaMode, kCVImageBufferAlphaChannelMode_PremultipliedAlpha)
    {
        return false
    }
    return true
    #else
    return false
    #endif
}
