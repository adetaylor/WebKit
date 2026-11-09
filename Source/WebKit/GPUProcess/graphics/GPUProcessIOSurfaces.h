/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA)

#include "SwiftCoding.h"
#include <IOSurface/IOSurfaceRef.h>
#include <wtf/Compiler.h>

namespace WebCore {
class ColorSpace;
}

namespace WebKit {

// The WebCore::IOSurface formats and names that the GPU process's Swift allocates.
enum class GPUProcessIOSurfaceFormat : uint8_t {
    BGRA,
    BGRX,
    RGBA,
    RGBX,
    RGBA16F,
};

enum class GPUProcessIOSurfaceName : uint8_t {
    WebGPU,
};

// Makes up to `count` IOSurfaces with WebCore::IOSurface::create(), with the color space the argument holds, and gives
// each to `addSurface`, for Swift, which keeps only the IOSurfaceRefs. A surface that can't be made is left out.
void createGPUProcessIOSurfaces(IPC::CxxDecodedArgument<WebCore::ColorSpace>&, int32_t width, int32_t height, GPUProcessIOSurfaceFormat, GPUProcessIOSurfaceName, uint32_t count, NOESCAPE void (^addSurface)(IOSurfaceRef WTF_NONNULL));

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA)
