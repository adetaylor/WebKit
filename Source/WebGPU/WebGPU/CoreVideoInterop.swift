// Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

// The CoreVideo calls that take or give raw pointers: a plane's base address, the IOSurface of a pixel buffer, which
// CoreVideo doesn't annotate for Swift, and the texture cache's out-parameters. Every `unsafe` the framework needs for
// CoreVideo is in this file.

import CoreVideo
import IOSurface
import Metal

// The frame's IOSurface, which the frame keeps alive.
func pixelBufferIOSurface(_ pixelBuffer: CVPixelBuffer) -> IOSurfaceRef? {
    // Safety: the get rule: the pixel buffer holds its surface, and takeUnretainedValue() retains it for the caller.
    unsafe CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
}

// A plane's bytes into as much of the texture as both have, when the plane's rows hold the bytes of the texture's format
// (copiedBytesPerPixel()) for every pixel copied. Copies nothing for a format with no known bytes per pixel, or when
// the plane's base address can't be locked.
func copyPixelBufferPlane(_ texture: any MTLTexture, _ pixelBuffer: CVPixelBuffer, _ plane: Int) {
    // Metal reads `height` rows of `width * bytesPerPixel` bytes, bytesPerRow apart: never more rows, or wider ones, than
    // the plane has. A plane whose rows are narrower than that is not copied, which is what Metal itself does on Apple GPUs.
    if texture.storageMode == .private || texture.storageMode == .memoryless {
        return
    }
    let bytesPerPixel = copiedBytesPerPixel(texture.pixelFormat)
    let width = min(CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), texture.width)
    let height = min(CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), texture.height)
    if width <= 0 || height <= 0 || bytesPerPixel <= 0 {
        return
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
    let (bytesReadPerRow, overflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
    if overflow || bytesReadPerRow > bytesPerRow {
        return
    }
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
        return
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    // Safety: the lock above keeps the plane's bytes at this address until the deferred unlock.
    guard let imageBytes = unsafe CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
        return
    }
    // Safety: Metal reads `height` rows of `bytesReadPerRow` bytes, `bytesPerRow` apart, which the checks above keep
    // within the plane's rows, while the base address is locked.
    unsafe texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: imageBytes,
        bytesPerRow: bytesPerRow
    )
}

// ExternalTextureImport.swift spells HAVE(COREVIDEO_METAL_SUPPORT) out, as this does, because Swift cannot evaluate the
// CoreVideo macro it expands to: Queue.h checks that the two agree.
#if HAVE_WEBGPU_IMPLEMENTATION && (WTF_PLATFORM_MAC || WTF_PLATFORM_IOS || WTF_PLATFORM_VISION)
func makeTextureCache(_ device: any MTLDevice) -> CVMetalTextureCache? {
    var cache: CVMetalTextureCache?
    // Safety: `cache` outlives the call, which stores a retained cache into it, which the Optional then owns.
    let result = unsafe CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    assert(result == kCVReturnSuccess)
    return cache
}

// nil unless CoreVideo succeeded, which it cannot without a cache.
func makeTextureCachePlane(
    _ cache: CVMetalTextureCache?,
    _ pixelBuffer: CVPixelBuffer,
    _ pixelFormat: MTLPixelFormat,
    _ plane: Int
) -> CVMetalTexture? {
    guard let cache else {
        return nil
    }
    var texture: CVMetalTexture?
    // Safety: as in makeTextureCache().
    let status = unsafe CVMetalTextureCacheCreateTextureFromImage(
        nil,
        cache,
        pixelBuffer,
        nil,
        pixelFormat,
        CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
        CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
        plane,
        &texture
    )
    guard status == kCVReturnSuccess else {
        return nil
    }
    return texture
}

// The coordinates of a plane's clean aperture that the import's UV remapping needs.
struct CleanTexCoords {
    var lowerLeftX: Float = 0
    var lowerRightY: Float = 0
    var upperRightX: Float = 0
    var upperLeftY: Float = 0
}

func cleanTexCoords(_ texture: CVMetalTexture) -> CleanTexCoords {
    var lowerLeft: [Float] = [0, 0]
    var lowerRight: [Float] = [0, 0]
    var upperRight: [Float] = [0, 0]
    var upperLeft: [Float] = [0, 0]
    // Safety: CoreVideo writes two floats through each pointer, into arrays of two that outlive the call.
    unsafe CVMetalTextureGetCleanTexCoords(texture, &lowerLeft, &lowerRight, &upperRight, &upperLeft)
    return CleanTexCoords(lowerLeftX: lowerLeft[0], lowerRightY: lowerRight[1], upperRightX: upperRight[0], upperLeftY: upperLeft[1])
}
#endif
