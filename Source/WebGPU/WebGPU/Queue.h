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


// CoreVideoInterop.swift and ExternalTextureImport.swift spell HAVE(COREVIDEO_METAL_SUPPORT) out, because Swift cannot
// evaluate the CoreVideo macro it expands to.
#if HAVE(COREVIDEO_METAL_SUPPORT) != (HAVE(WEBGPU_IMPLEMENTATION) && (PLATFORM(MAC) || PLATFORM(IOS) || PLATFORM(VISION)))
#error "Update the HAVE(COREVIDEO_METAL_SUPPORT) conditions in CoreVideoInterop.swift and ExternalTextureImport.swift"
#endif

} // namespace WebGPU::Metal

IGNORE_CLANG_WARNINGS_END
