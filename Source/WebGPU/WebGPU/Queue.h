/*
 * Copyright (c) 2021-2022 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#import "Instance.h"
#import <CoreVideo/CVMetalTextureCache.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakPtr.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebGPU::Metal {

// Host mirror of the MSL `WebKitCopyExternalImageArgs` in Queue.swift. It is a hand-maintained ABI: Queue.mm pins the
// size and every offset with static_asserts. Every field is a scalar or an array of scalars: MSL lays those out exactly
// as C does, while its vector and matrix types carry alignment rules of their own.
struct CopyExternalImageArguments {
    uint32_t sourceOriginX;
    uint32_t sourceOriginY;
    uint32_t destinationOriginX;
    uint32_t destinationOriginY;
    uint32_t copyWidth;
    uint32_t copyHeight;
    uint32_t sourceMaxX;
    uint32_t sourceMaxY;
    uint32_t flags;
    float colorMatrix[9]; // Row-major.
    // A video frame's simd::float3x2 crop and simd::float4x3 YCbCr matrices, flattened column-major.
    // Flattened because a simd float3 column is padded to 16 bytes, so neither matrix has a size the
    // arithmetic would guess right.
    float uvRemapMatrix[6];
    float ycbcrMatrix[12];
};

// The scalars of a WebGPU::ImageCopyExternalImage, handed to Swift in one value. Its IOSurface and pixel buffer
// are passed alongside.
struct CopyExternalImageSource {
    std::optional<WebGPU::TextureFormat> sourceFormat;
    WebGPU::Extent2D sourceSize;
    WebGPU::VideoFrameRotation pixelBufferRotation { WebGPU::VideoFrameRotation::None };
    bool pixelBufferIsMirrored { false };
    WebGPU::Origin2D origin;
    bool flipY { false };
    bool hasAlpha { true };
    bool premultipliedAlpha { true };
    WebGPU::PredefinedColorSpace colorSpace { WebGPU::PredefinedColorSpace::SRGB };
};

// The handlers QueueImpl gives each command buffer just before committing it. Both blocks run on Metal threads:
// didSchedule once the command buffer is scheduled, didComplete once it completed, with whether to lose the device.
// A fatal command buffer error, or no completion within 3 s, crashes the GPU process.
void addCommitHandlers(id<MTLCommandBuffer>, void (^ NS_SWIFT_SENDABLE didSchedule)(void), void (^ NS_SWIFT_SENDABLE didComplete)(bool loseTheDevice));
void setStagedCopyArguments(id<MTLComputeCommandEncoder>, uint64_t sourceWordOffset, uint64_t destinationWordOffset, uint64_t wordCount);
void setCopyExternalImageArguments(id<MTLRenderCommandEncoder>, const CopyExternalImageArguments&);

// Byte-moving primitives for Queue.swift. Free functions with NOESCAPE spans, so that Swift gets overloads taking
// Span<UInt8> (rdar://161274084).

// The texel block of the format a texture write copies, from which replaceRegion() computes the bytes Metal reads.
struct TexelBlockLayout {
    uint32_t width { 1 };
    uint32_t height { 1 };
    uint32_t size { 0 };
};

void writeBufferContents(id<MTLBuffer>, uint64_t bufferOffset, std::span<const uint8_t> data NOESCAPE, bool isManaged);
void copyBytesToBuffer(id<MTLBuffer> _Nullable, uint64_t offset, std::span<const uint8_t> data NOESCAPE);
void zeroBufferContents(id<MTLBuffer> _Nullable, uint64_t offset, uint64_t size);
// RELEASE_ASSERTs that every byte Metal reads, from sourceOffset on, is inside `data`.
void replaceRegion(id<MTLTexture> _Nullable, MTLRegion, uint32_t mipLevel, uint64_t slice, std::span<const uint8_t> data NOESCAPE, uint64_t sourceOffset, uint64_t bytesPerRow, uint64_t bytesPerImage, TexelBlockLayout);
// A buffer over `length` bytes of the ByteOwner from `offset`, which keeps the ByteOwner alive for as long as it exists.
// Null when the ByteOwner has fewer bytes.
id<MTLBuffer> _Nullable newBufferAliasingOwner(id<MTLDevice> _Nullable, const WebGPU::ByteOwner&, uint64_t offset, uint64_t length);

// For ExternalTextureImport.swift: a plane's bytes, through a raw pointer, into as much of the texture as both have, when
// the plane's rows hold `bytesPerPixel` bytes (those of the texture's format; 0 if unknown) for every pixel copied. The
// base address must be locked.
void copyPixelBufferPlane(id<MTLTexture>, CVPixelBufferRef, size_t plane, size_t bytesPerPixel);

// CoreVideo calls for ExternalTextureImport.swift, with their results returned: CVPixelBufferGetIOSurface is not
// audited for Swift, which would get an Unmanaged reference, and the others write through out-parameters, which Swift
// can only pass as unsafe pointers.
IOSurfaceRef _Nullable pixelBufferIOSurface(CVPixelBufferRef) CF_RETURNS_NOT_RETAINED;
#if HAVE(COREVIDEO_METAL_SUPPORT)
CVMetalTextureCacheRef _Nullable createCoreVideoTextureCache(id<MTLDevice>) CF_RETURNS_RETAINED;
// Null unless CoreVideo succeeded.
CVMetalTextureRef _Nullable createCoreVideoPlaneTexture(CVMetalTextureCacheRef, CVPixelBufferRef, MTLPixelFormat, size_t plane) CF_RETURNS_RETAINED;
// The coordinates of a plane's clean aperture that the import's UV remapping needs.
struct CleanTexCoords {
    float lowerLeftX { 0 };
    float lowerRightY { 0 };
    float upperRightX { 0 };
    float upperLeftY { 0 };
};
CleanTexCoords cleanTexCoords(CVMetalTextureRef);
#endif

} // namespace WebGPU::Metal

IGNORE_CLANG_WARNINGS_END
