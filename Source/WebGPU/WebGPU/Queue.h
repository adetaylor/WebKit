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

// Host mirror of the MSL `WebKitStagedCopyArgs` declared in the kernel source in Queue.swift. It is a hand-maintained
// ABI, and getting the field widths wrong produces silently wrong offsets rather than a compile error. MSL `ulong` is
// 64-bit, so the static_asserts below pin size and every offset.
struct StagedCopyArguments {
    uint64_t sourceWordOffset;
    uint64_t destinationWordOffset;
    uint64_t wordCount;
};
static_assert(sizeof(StagedCopyArguments) == 24, "StagedCopyArguments must match MSL WebKitStagedCopyArgs (3 x ulong)");
static_assert(!offsetof(StagedCopyArguments, sourceWordOffset), "sourceWordOffset must be at offset 0");
static_assert(offsetof(StagedCopyArguments, destinationWordOffset) == 8, "destinationWordOffset must be at offset 8");
static_assert(offsetof(StagedCopyArguments, wordCount) == 16, "wordCount must be at offset 16");

// Host mirror of the MSL `WebKitCopyExternalImageArgs` in Queue.swift. It is a hand-maintained ABI: the static_asserts
// below pin the size and every offset. Every field is a scalar or an array of scalars: MSL lays those out exactly
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
static_assert(sizeof(CopyExternalImageArguments) == 144, "CopyExternalImageArguments must match MSL WebKitCopyExternalImageArgs (9 x uint + 27 x float)");
static_assert(!offsetof(CopyExternalImageArguments, sourceOriginX), "sourceOriginX must be at offset 0");
static_assert(offsetof(CopyExternalImageArguments, sourceOriginY) == 4, "sourceOriginY must be at offset 4");
static_assert(offsetof(CopyExternalImageArguments, destinationOriginX) == 8, "destinationOriginX must be at offset 8");
static_assert(offsetof(CopyExternalImageArguments, destinationOriginY) == 12, "destinationOriginY must be at offset 12");
static_assert(offsetof(CopyExternalImageArguments, copyWidth) == 16, "copyWidth must be at offset 16");
static_assert(offsetof(CopyExternalImageArguments, copyHeight) == 20, "copyHeight must be at offset 20");
static_assert(offsetof(CopyExternalImageArguments, sourceMaxX) == 24, "sourceMaxX must be at offset 24");
static_assert(offsetof(CopyExternalImageArguments, sourceMaxY) == 28, "sourceMaxY must be at offset 28");
static_assert(offsetof(CopyExternalImageArguments, flags) == 32, "flags must be at offset 32");
static_assert(offsetof(CopyExternalImageArguments, colorMatrix) == 36, "colorMatrix must be at offset 36");
static_assert(offsetof(CopyExternalImageArguments, uvRemapMatrix) == 72, "uvRemapMatrix must be at offset 72");
static_assert(offsetof(CopyExternalImageArguments, ycbcrMatrix) == 96, "ycbcrMatrix must be at offset 96");

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
